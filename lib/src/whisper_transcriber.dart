import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'audio_prep.dart';
import 'config.dart';
import 'exceptions.dart';
import 'pcm.dart';
import 'transcriber.dart';
import 'whisper_bindings.dart';

/// On-device speech-to-text with whisper.cpp.
///
/// Memory and threading model:
///
/// * The model is loaded once, in a worker isolate, and lives in native
///   memory. Only its address is kept here.
/// * Every request runs on a short-lived worker ([Isolate.run]). The UI
///   isolate never decodes, resamples or trims audio; it wraps the input in a
///   [TransferableTypedData] (one memcpy, then a zero-copy move into the
///   worker - never the per-element copy a plain typed list would cost) or
///   hands over a file path.
/// * On the worker the audio goes through exactly one intermediate buffer -
///   the native float array whisper.cpp reads - which is freed before the
///   result is returned. Peak Dart-heap cost per request is one float32 copy
///   of the clip; the ceiling is set by [TranscriptionConfig.maxAudioSeconds].
/// * whisper.cpp contexts are not reentrant, so requests are serialised on an
///   internal queue. Concurrent callers wait their turn instead of corrupting
///   each other's state; they never run in parallel.
class WhisperTranscriber implements Transcriber {
  WhisperTranscriber._(this._contextAddress, this.config, this._threads);

  final int _contextAddress;
  final TranscriptionConfig config;
  final int _threads;

  Future<void> _queue = Future<void>.value();
  bool _disposed = false;

  /// Loads a ggml model (e.g. `ggml-tiny.en-q5_1.bin`) from a filesystem
  /// path. Loading happens on a worker isolate, so a 30-100 MB model does not
  /// freeze the first frame. See `WhisperModelInstaller` for copying a
  /// Flutter asset to disk.
  static Future<WhisperTranscriber> load(
    String modelPath, {
    TranscriptionConfig config = TranscriptionConfig.defaults,
    bool useGpu = false,
  }) async {
    if (!await File(modelPath).exists()) {
      throw ModelLoadException('Speech model not found at $modelPath');
    }

    final address = await _openModel(modelPath, useGpu);
    final threads = config.threads > 0
        ? config.threads
        : math.max(1, math.min(4, Platform.numberOfProcessors));

    return WhisperTranscriber._(address, config, threads);
  }

  static Future<int> _openModel(String modelPath, bool useGpu) async {
    try {
      final address = await Isolate.run(() => _loadContext(modelPath, useGpu));
      if (address == 0) {
        throw ModelLoadException(
            'whisper.cpp could not load the model at $modelPath');
      }
      return address;
    } on ArgumentError catch (error) {
      // DynamicLibrary.open failed: the native library is not in the build.
      throw ModelLoadException('Native whisper library unavailable: $error');
    } on RemoteError catch (error) {
      throw ModelLoadException('Could not load the speech model: $error');
    }
  }

  @override
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    String languageCode = 'en',
  }) {
    _checkNotDisposed();
    if (samples.length > config.maxSamples) {
      // Fail before paying for the transfer.
      throw AudioTooLongException(
          samples.length / config.sampleRate, config.maxAudioSeconds);
    }
    final job = _Job.float32(
      context: _contextAddress,
      config: config,
      threads: _threads,
      language: primaryLanguage(languageCode),
      bytes: TransferableTypedData.fromList([samples]),
    );
    return _run(job);
  }

  @override
  Future<TranscriptionResult> transcribePcm16(
    Uint8List pcm16, {
    String languageCode = 'en',
    int channels = 1,
    int sampleRate = 16000,
  }) {
    _checkNotDisposed();
    if (channels < 1 || sampleRate < 1) {
      throw ArgumentError('channels and sampleRate must be positive');
    }
    final frames = pcm16.lengthInBytes ~/ (2 * channels);
    if (frames / sampleRate > config.maxAudioSeconds) {
      throw AudioTooLongException(frames / sampleRate, config.maxAudioSeconds);
    }
    final job = _Job.pcm16(
      context: _contextAddress,
      config: config,
      threads: _threads,
      language: primaryLanguage(languageCode),
      bytes: TransferableTypedData.fromList([pcm16]),
      channels: channels,
      sampleRate: sampleRate,
    );
    return _run(job);
  }

  @override
  Future<TranscriptionResult> transcribeWavFile(
    String path, {
    String languageCode = 'en',
  }) {
    _checkNotDisposed();
    final job = _Job.wavFile(
      context: _contextAddress,
      config: config,
      threads: _threads,
      language: primaryLanguage(languageCode),
      path: path,
    );
    return _run(job);
  }

  @override
  Future<void> dispose() {
    if (_disposed) return Future<void>.value();
    _disposed = true;
    final address = _contextAddress;
    return _enqueue(() async {
      WhisperBindings.open().free(Pointer<Void>.fromAddress(address));
    });
  }

  void _checkNotDisposed() {
    if (_disposed) {
      throw StateError('WhisperTranscriber has been disposed');
    }
  }

  Future<TranscriptionResult> _run(_Job job) =>
      _enqueue(() => Isolate.run(() => _execute(job)));

  /// Runs [action] after everything queued before it, and returns its own
  /// outcome. A failure never breaks the chain for later callers.
  Future<T> _enqueue<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }
}

// ---------------------------------------------------------------------------
// Worker side. Everything below runs on a short-lived isolate and touches
// only what the job carries.
// ---------------------------------------------------------------------------

enum _Source { float32, pcm16, wavFile }

/// Everything a worker needs. Holds primitives, an immutable config and at
/// most one [TransferableTypedData], so sending it is a pointer move.
class _Job {
  const _Job._({
    required this.source,
    required this.context,
    required this.config,
    required this.threads,
    required this.language,
    this.bytes,
    this.path,
    this.channels = 1,
    this.sampleRate = 16000,
  });

  const _Job.float32({
    required int context,
    required TranscriptionConfig config,
    required int threads,
    required String language,
    required TransferableTypedData bytes,
  }) : this._(
          source: _Source.float32,
          context: context,
          config: config,
          threads: threads,
          language: language,
          bytes: bytes,
        );

  const _Job.pcm16({
    required int context,
    required TranscriptionConfig config,
    required int threads,
    required String language,
    required TransferableTypedData bytes,
    required int channels,
    required int sampleRate,
  }) : this._(
          source: _Source.pcm16,
          context: context,
          config: config,
          threads: threads,
          language: language,
          bytes: bytes,
          channels: channels,
          sampleRate: sampleRate,
        );

  const _Job.wavFile({
    required int context,
    required TranscriptionConfig config,
    required int threads,
    required String language,
    required String path,
  }) : this._(
          source: _Source.wavFile,
          context: context,
          config: config,
          threads: threads,
          language: language,
          path: path,
        );

  final _Source source;
  final int context;
  final TranscriptionConfig config;
  final int threads;
  final String language;
  final TransferableTypedData? bytes;
  final String? path;
  final int channels;
  final int sampleRate;
}

int _loadContext(String modelPath, bool useGpu) {
  final bindings = WhisperBindings.open();
  final pathPointer = modelPath.toNativeUtf8();
  try {
    return bindings.init(pathPointer, useGpu ? 1 : 0).address;
  } finally {
    malloc.free(pathPointer);
  }
}

TranscriptionResult _execute(_Job job) {
  final stopwatch = Stopwatch()..start();
  final config = job.config;

  final samples = switch (job.source) {
    _Source.float32 => Float32List.view(job.bytes!.materialize()),
    _Source.pcm16 => _decodePcm16(job),
    _Source.wavFile => _decodeWavFile(job.path!, config),
  };

  final prepared = prepareAudio(samples, config: config);
  final length = prepared.length;

  final bindings = WhisperBindings.open();
  final context = Pointer<Void>.fromAddress(job.context);
  final buffer = malloc<Float>(length);
  final language = job.language.toNativeUtf8();
  try {
    // Trim + gain go straight into native memory: no intermediate list.
    prepared.writeInto(samples, buffer.asTypedList(length));

    final rc = bindings.run(
      context,
      buffer,
      length,
      language,
      job.threads,
      config.singleSegment ? 1 : 0,
    );
    if (rc != 0) throw TranscriptionFailedException(rc);

    final text = bindings.text(context).toDartString().trim();
    stopwatch.stop();
    return TranscriptionResult(
      text: text,
      language: job.language,
      audioSeconds: prepared.seconds,
      processingTime: stopwatch.elapsed,
    );
  } finally {
    malloc.free(language);
    malloc.free(buffer);
  }
}

Float32List _decodePcm16(_Job job) {
  final bytes = Uint8List.view(job.bytes!.materialize());
  final mono = pcm16ToFloat32(bytes, channels: job.channels);
  return resampleLinear(mono, job.sampleRate, job.config.sampleRate);
}

/// Streams a WAV file's sample data through a 64 kB buffer, converting each
/// chunk as it arrives. Memory: one Float32List for the mono samples at the
/// file's rate, plus the chunk buffer.
Float32List _decodeWavFile(String path, TranscriptionConfig config) {
  final RandomAccessFile file;
  try {
    file = File(path).openSync();
  } on FileSystemException catch (error) {
    throw AudioFormatException('Could not open audio file: ${error.message}');
  }

  try {
    final fileLength = file.lengthSync();
    final header = file.readSync(math.min(fileLength, 4096));
    final info = parseWavHeader(header, fileLength: fileLength);

    if (info.seconds > config.maxAudioSeconds) {
      throw AudioTooLongException(info.seconds, config.maxAudioSeconds);
    }

    final frames = info.frameCount;
    final bytesPerFrame = info.bytesPerFrame;
    final out = Float32List(frames);

    // Whole frames only, so a chunk boundary never splits a sample.
    const targetChunk = 64 * 1024;
    final chunkBytes = targetChunk - targetChunk % bytesPerFrame;
    final chunk = Uint8List(chunkBytes);

    file.setPositionSync(info.dataOffset);
    var remaining = frames * bytesPerFrame;
    var written = 0;
    var carry = 0;

    while (remaining > 0 && written < frames) {
      final want = math.min(chunkBytes - carry, remaining);
      final got = file.readIntoSync(chunk, carry, carry + want);
      if (got <= 0) break; // file shorter than its header claimed
      remaining -= got;

      final filled = carry + got;
      final usable = filled - filled % bytesPerFrame;
      written += pcm16Into(
        Uint8List.sublistView(chunk, 0, usable),
        out,
        written,
        channels: info.channels,
      );
      carry = filled - usable;
      if (carry > 0) chunk.setRange(0, carry, chunk, usable);
    }

    final mono = written == frames ? out : Float32List.sublistView(out, 0, written);
    return resampleLinear(mono, info.sampleRate, config.sampleRate);
  } on FileSystemException catch (error) {
    throw AudioFormatException('Could not read audio file: ${error.message}');
  } finally {
    file.closeSync();
  }
}
