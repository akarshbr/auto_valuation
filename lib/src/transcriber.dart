import 'dart:typed_data';

/// What a transcription produced.
class TranscriptionResult {
  const TranscriptionResult({
    required this.text,
    required this.language,
    required this.audioSeconds,
    required this.processingTime,
  });

  /// Recognised text, trimmed. Empty when the model heard no speech.
  final String text;

  /// Language the model was asked to decode (primary subtag, e.g. `en`).
  final String language;

  /// Seconds of audio actually sent to the model, after trimming.
  final double audioSeconds;

  /// Wall-clock time spent decoding, preparing and running the model.
  final Duration processingTime;

  bool get isEmpty => text.isEmpty;

  /// How many times faster than real time the model ran.
  double get realTimeFactor => processingTime.inMicroseconds == 0
      ? double.infinity
      : audioSeconds * Duration.microsecondsPerSecond /
          processingTime.inMicroseconds;

  @override
  String toString() =>
      'TranscriptionResult("$text", $language, ${audioSeconds}s in '
      '${processingTime.inMilliseconds}ms)';
}

/// Speech-to-text contract.
///
/// Every method accepts a [languageCode] as BCP-47 (`en-IN`) or a bare
/// language (`en`); only the primary subtag reaches the model. Every method
/// throws a [TranscriptionException] subclass on failure and never blocks the
/// calling isolate with heavy work.
///
/// The three inputs exist so callers can hand over whatever they already
/// have without converting it on the UI isolate first: decoding happens on
/// the worker.
abstract class Transcriber {
  /// Transcribes mono float32 samples at the configured sample rate.
  Future<TranscriptionResult> transcribe(
    Float32List samples, {
    String languageCode = 'en',
  });

  /// Transcribes raw little-endian 16-bit PCM (what the microphone yields).
  /// Half the size of float32 to move across isolates, so prefer this for
  /// recordings.
  Future<TranscriptionResult> transcribePcm16(
    Uint8List pcm16, {
    String languageCode = 'en',
    int channels = 1,
    int sampleRate = 16000,
  });

  /// Transcribes a 16-bit PCM `.wav` file. The file is read on the worker in
  /// chunks, so nothing but the header touches the calling isolate.
  Future<TranscriptionResult> transcribeWavFile(
    String path, {
    String languageCode = 'en',
  });

  /// Releases the model. Any transcription still queued completes first.
  Future<void> dispose();
}

/// Reduces `en-IN`, `en_US`, `EN` ... to the primary language subtag the
/// model understands. Empty input means "auto".
String primaryLanguage(String languageCode) {
  final trimmed = languageCode.trim();
  if (trimmed.isEmpty) return 'auto';
  final end = trimmed.indexOf(RegExp('[-_]'));
  return (end < 0 ? trimmed : trimmed.substring(0, end)).toLowerCase();
}
