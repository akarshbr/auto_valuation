import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'config.dart';

/// Captures microphone audio as mono 16-bit PCM at the model's sample rate.
///
/// Recording straight into the target format means there is no decoding
/// step at all. The captured bytes are kept as-is (2 bytes per sample) and
/// handed to [Transcriber.transcribePcm16], which converts them to float on
/// the worker isolate - the UI isolate never touches a sample.
class TranscriptionRecorder {
  TranscriptionRecorder({this.config = TranscriptionConfig.defaults});

  final TranscriptionConfig config;
  final AudioRecorder _recorder = AudioRecorder();
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  StreamSubscription<Uint8List>? _subscription;
  Completer<void>? _streamDone;

  bool get isRecording => _subscription != null;

  /// Bytes captured so far; useful for a recording-length indicator.
  int get bytesRecorded => _buffer.length;

  /// Seconds captured so far.
  double get secondsRecorded => _buffer.length / (2 * config.sampleRate);

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Starts capturing. Throws [StateError] if already recording.
  Future<void> start() async {
    if (isRecording) throw StateError('Already recording');
    _buffer.clear();

    final stream = await _recorder.startStream(
      RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: config.sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ),
    );

    final done = Completer<void>();
    _streamDone = done;
    _subscription = stream.listen(
      _buffer.add,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (!done.isCompleted) done.completeError(error, stack);
      },
      cancelOnError: true,
    );
  }

  /// Stops capturing and returns the raw PCM16 bytes. The internal buffer
  /// is released to the caller, not copied.
  Future<Uint8List> stop() async {
    final subscription = _subscription;
    final done = _streamDone;
    if (subscription == null || done == null) {
      throw StateError('Not recording');
    }
    _subscription = null;
    _streamDone = null;

    try {
      await _recorder.stop();
      // Let the last buffered chunks arrive before draining.
      await done.future.timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
    } finally {
      await subscription.cancel();
    }
    return _buffer.takeBytes();
  }

  /// Stops without keeping anything.
  Future<void> cancel() async {
    if (!isRecording) return;
    await stop();
    _buffer.clear();
  }

  Future<void> dispose() async {
    if (isRecording) await cancel();
    await _recorder.dispose();
  }
}
