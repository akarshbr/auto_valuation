import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_valuation/audio_valuation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds a minimal 16-bit PCM WAV in memory.
Uint8List buildWav(
  List<int> samples, {
  int sampleRate = 16000,
  int channels = 1,
  int format = 1,
  int bitsPerSample = 16,
  int? claimedDataLength,
}) {
  final dataLength = samples.length * 2;
  final bytes = ByteData(44 + dataLength);
  void tag(int offset, String s) {
    for (var i = 0; i < 4; i++) {
      bytes.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, 36 + dataLength, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, format, Endian.little);
  bytes.setUint16(22, channels, Endian.little);
  bytes.setUint32(24, sampleRate, Endian.little);
  bytes.setUint32(28, sampleRate * channels * 2, Endian.little);
  bytes.setUint16(32, channels * 2, Endian.little);
  bytes.setUint16(34, bitsPerSample, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, claimedDataLength ?? dataLength, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    bytes.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}

Float32List sine(double seconds, {double amplitude = 0.5, int rate = 16000}) {
  final n = (seconds * rate).round();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = amplitude * math.sin(2 * math.pi * 440 * i / rate);
  }
  return out;
}

void main() {
  group('pcm16ToFloat32', () {
    test('scales int16 to [-1, 1)', () {
      final bytes = ByteData(8)
        ..setInt16(0, 0, Endian.little)
        ..setInt16(2, 32767, Endian.little)
        ..setInt16(4, -32768, Endian.little)
        ..setInt16(6, 16384, Endian.little);
      final out = pcm16ToFloat32(bytes.buffer.asUint8List());
      expect(out, [0.0, closeTo(1.0, 1e-4), -1.0, 0.5]);
    });

    test('ignores an odd trailing byte', () {
      final out = pcm16ToFloat32(Uint8List.fromList([0, 0, 0, 64, 7]));
      expect(out.length, 2);
      expect(out[1], 0.5);
    });

    test('handles an unaligned view via the slow path', () {
      final backing = Uint8List.fromList([0xFF, 0, 0, 0, 64]);
      final view = Uint8List.sublistView(backing, 1); // odd offset
      final out = pcm16ToFloat32(view);
      expect(out, [0.0, 0.5]);
    });

    test('downmixes stereo by averaging', () {
      final bytes = ByteData(8)
        ..setInt16(0, 16384, Endian.little)
        ..setInt16(2, -16384, Endian.little)
        ..setInt16(4, 16384, Endian.little)
        ..setInt16(6, 16384, Endian.little);
      final out = pcm16ToFloat32(bytes.buffer.asUint8List(), channels: 2);
      expect(out, [0.0, 0.5]);
    });

    test('pcm16Into never writes past the destination', () {
      final bytes = Uint8List(20);
      final out = Float32List(4);
      expect(pcm16Into(bytes, out, 2), 2);
    });
  });

  group('parseWavHeader / decodeWav', () {
    test('reads format and locates the data chunk', () {
      final wav = buildWav([1000, -1000, 500], sampleRate: 44100, channels: 1);
      final info = parseWavHeader(wav);
      expect(info.sampleRate, 44100);
      expect(info.channels, 1);
      expect(info.dataOffset, 44);
      expect(info.frameCount, 3);
    });

    test('clamps a lying data length to the file size', () {
      final wav = buildWav([1, 2, 3], claimedDataLength: 0xFFFFFFFF);
      expect(parseWavHeader(wav).frameCount, 3);
    });

    test('rejects non-RIFF input', () {
      expect(
        () => parseWavHeader(Uint8List(64)),
        throwsA(isA<AudioFormatException>()),
      );
    });

    test('rejects tiny input', () {
      expect(
        () => parseWavHeader(Uint8List(5)),
        throwsA(isA<AudioFormatException>()),
      );
    });

    test('rejects float and 8-bit encodings with a clear message', () {
      expect(
        () => parseWavHeader(buildWav([0], format: 3)),
        throwsA(isA<AudioFormatException>()
            .having((e) => e.message, 'message', contains('16-bit PCM'))),
      );
      expect(
        () => parseWavHeader(buildWav([0], bitsPerSample: 8)),
        throwsA(isA<AudioFormatException>()),
      );
    });

    test('decodeWav honours maxFrames', () {
      final wav = buildWav(List<int>.filled(100, 1000));
      final decoded = decodeWav(wav, maxFrames: 10);
      expect(decoded.samples.length, 10);
      expect(decoded.info.frameCount, 100);
    });
  });

  group('resampleLinear', () {
    test('returns the input untouched when rates match', () {
      final input = Float32List.fromList([1, 2, 3]);
      expect(identical(resampleLinear(input, 16000, 16000), input), isTrue);
    });

    test('halves the length for 2:1 and interpolates', () {
      final input = Float32List.fromList([0, 1, 2, 3, 4, 5]);
      final out = resampleLinear(input, 32000, 16000);
      expect(out, [0, 2, 4]);
    });

    test('upsamples with interpolated values', () {
      final input = Float32List.fromList([0, 1]);
      final out = resampleLinear(input, 8000, 16000);
      expect(out, [0, 0.5, 1, 1]);
    });
  });

  group('prepareAudio', () {
    test('rejects empty audio', () {
      expect(
        () => prepareAudio(Float32List(0)),
        throwsA(isA<AudioFormatException>()),
      );
    });

    test('rejects silence', () {
      expect(
        () => prepareAudio(Float32List(16000)),
        throwsA(isA<SilentAudioException>()),
      );
    });

    test('rejects audio above the ceiling before scanning it', () {
      const config = TranscriptionConfig(maxAudioSeconds: 1);
      expect(
        () => prepareAudio(Float32List(16001), config: config),
        throwsA(isA<AudioTooLongException>()),
      );
    });

    test('rejects a clip that is too short once trimmed', () {
      final audio = Float32List(16000)..[8000] = 0.5;
      expect(
        () => prepareAudio(audio),
        throwsA(isA<AudioTooShortException>()),
      );
    });

    test('trims leading and trailing silence with padding', () {
      const config = TranscriptionConfig(normaliseLevel: false);
      final audio = Float32List(3 * 16000);
      audio.setRange(16000, 32000, sine(1.0));
      final prepared = prepareAudio(audio, config: config);

      expect(prepared.start, closeTo(16000 - config.trimPaddingSamples, 40));
      expect(prepared.end, closeTo(32000 + config.trimPaddingSamples, 40));
      expect(prepared.gain, 1.0);
      expect(prepared.apply(audio).length, prepared.length);
    });

    test('quiet audio is boosted but never past maxPeak', () {
      final quiet = sine(1.0, amplitude: 0.01);
      final prepared = prepareAudio(quiet);
      expect(prepared.gain, greaterThan(1.0));

      final out = prepared.apply(quiet);
      var peak = 0.0;
      for (final s in out) {
        peak = math.max(peak, s.abs());
      }
      expect(peak, lessThanOrEqualTo(TranscriptionConfig.defaults.maxPeak));
    });

    test('a quiet recording is never trimmed to nothing', () {
      final quiet = sine(1.0, amplitude: 0.001);
      expect(prepareAudio(quiet).seconds, closeTo(1.0, 0.01));
    });

    test('writeInto refuses a destination that is too small', () {
      final audio = sine(0.5);
      final prepared = prepareAudio(audio);
      expect(
        () => prepared.writeInto(audio, Float32List(10)),
        throwsArgumentError,
      );
    });
  });

  group('TranscriptionConfig', () {
    test('defaults to singleSegment true', () {
      const config = TranscriptionConfig.defaults;
      expect(config.singleSegment, isTrue);
    });
  });

  group('primaryLanguage', () {
    test('keeps only the primary subtag, lowercased', () {
      expect(primaryLanguage('en-IN'), 'en');
      expect(primaryLanguage('hi_IN'), 'hi');
      expect(primaryLanguage('EN'), 'en');
      expect(primaryLanguage('  '), 'auto');
    });
  });
}
