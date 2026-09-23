import 'dart:typed_data';

import 'exceptions.dart';

const double _int16Scale = 1.0 / 32768.0;

/// Converts little-endian signed 16-bit PCM bytes to float32 samples in
/// `[-1, 1)`, which is what the speech model consumes.
///
/// [channels] > 1 are averaged down to mono; the returned list is always
/// mono. An odd trailing byte is ignored.
Float32List pcm16ToFloat32(Uint8List bytes, {int channels = 1}) {
  final frames = bytes.lengthInBytes ~/ (2 * channels);
  final out = Float32List(frames);
  pcm16Into(bytes, out, 0, channels: channels);
  return out;
}

/// Decodes PCM16 [bytes] into [out] starting at [offset] and returns the
/// number of mono frames written (never more than fit in [out]).
///
/// The hot path is an [Int16List] view over the bytes - no per-sample
/// [ByteData] call - which is possible on every Flutter target because they
/// are all little-endian. The [ByteData] path only runs for a view that is not
/// 2-byte aligned, or on an exotic big-endian host.
int pcm16Into(Uint8List bytes, Float32List out, int offset,
    {int channels = 1}) {
  if (channels < 1) {
    throw ArgumentError.value(channels, 'channels', 'must be at least 1');
  }
  final available = bytes.lengthInBytes ~/ (2 * channels);
  final frames = available < out.length - offset ? available : out.length - offset;
  if (frames <= 0) return 0;

  final aligned =
      Endian.host == Endian.little && bytes.offsetInBytes.isEven;

  if (channels == 1) {
    if (aligned) {
      final view = Int16List.view(bytes.buffer, bytes.offsetInBytes, frames);
      for (var i = 0; i < frames; i++) {
        out[offset + i] = view[i] * _int16Scale;
      }
    } else {
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < frames; i++) {
        out[offset + i] = data.getInt16(i << 1, Endian.little) * _int16Scale;
      }
    }
    return frames;
  }

  // Multi-channel: average each frame's channels into one sample.
  final scale = _int16Scale / channels;
  if (aligned) {
    final view =
        Int16List.view(bytes.buffer, bytes.offsetInBytes, frames * channels);
    var src = 0;
    for (var i = 0; i < frames; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += view[src++];
      }
      out[offset + i] = sum * scale;
    }
  } else {
    final data = ByteData.sublistView(bytes);
    var src = 0;
    for (var i = 0; i < frames; i++) {
      var sum = 0;
      for (var c = 0; c < channels; c++) {
        sum += data.getInt16(src, Endian.little);
        src += 2;
      }
      out[offset + i] = sum * scale;
    }
  }
  return frames;
}

/// Layout of a RIFF/WAVE file, as read from its header.
class WavInfo {
  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;

  /// Byte offset of the first sample.
  final int dataOffset;

  /// Length of the sample data in bytes (already clamped to the file size).
  final int dataLength;

  int get bytesPerFrame => channels * (bitsPerSample ~/ 8);
  int get frameCount => dataLength ~/ bytesPerFrame;
  double get seconds => frameCount / sampleRate;
}

const int _riff = 0x52494646; // "RIFF"
const int _wave = 0x57415645; // "WAVE"
const int _fmt = 0x666d7420; // "fmt "
const int _data = 0x64617461; // "data"
const int _formatPcm = 1;
const int _formatExtensible = 0xFFFE;

/// Parses the RIFF header in [header] (the first bytes of a file - 4 kB is
/// plenty) and returns where the samples are, without touching them.
///
/// Only 16-bit integer PCM is accepted; anything else throws
/// [AudioFormatException] with a message that says what was found.
/// [fileLength] clamps the data chunk for files whose header lies (streamed
/// recorders often write a placeholder length).
WavInfo parseWavHeader(Uint8List header, {int? fileLength}) {
  final total = fileLength ?? header.lengthInBytes;
  if (header.lengthInBytes < 12) {
    throw const AudioFormatException('File is too small to be a WAV file');
  }
  final data = ByteData.sublistView(header);
  if (data.getUint32(0, Endian.big) != _riff ||
      data.getUint32(8, Endian.big) != _wave) {
    throw const AudioFormatException('Not a RIFF/WAVE file');
  }

  int? sampleRate;
  int? channels;
  int? bitsPerSample;
  int? format;

  var offset = 12;
  while (offset + 8 <= header.lengthInBytes) {
    final chunkId = data.getUint32(offset, Endian.big);
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (chunkId == _fmt) {
      if (body + 16 > header.lengthInBytes) {
        throw const AudioFormatException('WAV "fmt " chunk is truncated');
      }
      format = data.getUint16(body, Endian.little);
      channels = data.getUint16(body + 2, Endian.little);
      sampleRate = data.getUint32(body + 4, Endian.little);
      bitsPerSample = data.getUint16(body + 14, Endian.little);
      if (format == _formatExtensible && body + 26 <= header.lengthInBytes) {
        // Sub-format GUID starts with the real format tag.
        format = data.getUint16(body + 24, Endian.little);
      }
    } else if (chunkId == _data) {
      if (format == null || sampleRate == null || channels == null ||
          bitsPerSample == null) {
        throw const AudioFormatException(
            'WAV "data" chunk appears before "fmt "');
      }
      if (format != _formatPcm || bitsPerSample != 16) {
        throw AudioFormatException(
          'Unsupported WAV encoding (format $format, $bitsPerSample-bit); '
          'only 16-bit PCM is supported',
        );
      }
      if (channels < 1 || sampleRate < 1) {
        throw const AudioFormatException('WAV header has invalid format values');
      }
      final remaining = total - body;
      final length = chunkSize < remaining ? chunkSize : remaining;
      return WavInfo(
        sampleRate: sampleRate,
        channels: channels,
        bitsPerSample: bitsPerSample,
        dataOffset: body,
        dataLength: length < 0 ? 0 : length,
      );
    }

    offset = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
  }
  throw const AudioFormatException(
      'WAV file has no "data" chunk within the header bytes read');
}

/// Decodes an in-memory 16-bit PCM WAV into mono float32 samples at the
/// file's own sample rate. Use [resampleLinear] to bring it to the model rate.
///
/// [maxFrames] stops decoding after that many frames so an oversized file
/// never becomes an oversized allocation.
({Float32List samples, WavInfo info}) decodeWav(Uint8List wavBytes,
    {int? maxFrames}) {
  final info = parseWavHeader(wavBytes);
  final frames = maxFrames != null && maxFrames < info.frameCount
      ? maxFrames
      : info.frameCount;
  final samples = Float32List(frames);
  final body = Uint8List.sublistView(
      wavBytes, info.dataOffset, info.dataOffset + frames * info.bytesPerFrame);
  pcm16Into(body, samples, 0, channels: info.channels);
  return (samples: samples, info: info);
}

/// Linear-interpolation resampler.
///
/// Whisper only needs speech-band content, so a first-order interpolator is
/// accurate enough and costs one pass with no filter state. Returns [input]
/// itself when the rates already match.
Float32List resampleLinear(Float32List input, int fromRate, int toRate) {
  if (fromRate == toRate || input.isEmpty) return input;
  if (fromRate <= 0 || toRate <= 0) {
    throw ArgumentError('Sample rates must be positive');
  }

  final ratio = fromRate / toRate;
  final outLength = (input.length / ratio).floor();
  final out = Float32List(outLength);
  final last = input.length - 1;

  for (var i = 0; i < outLength; i++) {
    final position = i * ratio;
    final index = position.floor();
    final fraction = position - index;
    final a = input[index];
    final b = index < last ? input[index + 1] : a;
    out[i] = a + (b - a) * fraction;
  }
  return out;
}
