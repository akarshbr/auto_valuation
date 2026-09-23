/// Base class for every error this package raises.
///
/// Callers that only care about "it failed" can catch this; callers that want
/// to show a specific message (muted microphone, unsupported file, ...) can
/// switch on the concrete subclass. Programmer errors, such as using a
/// transcriber after disposing it, throw [StateError] instead.
sealed class TranscriptionException implements Exception {
  const TranscriptionException(this.message);

  /// Human-readable description, safe to show to an end user.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The speech model could not be loaded.
final class ModelLoadException extends TranscriptionException {
  const ModelLoadException(super.message);
}

/// The audio bytes could not be parsed (not a WAV, unsupported encoding,
/// truncated file, empty buffer, ...).
final class AudioFormatException extends TranscriptionException {
  const AudioFormatException(super.message);
}

/// The audio decoded fine but holds no audible sound.
final class SilentAudioException extends TranscriptionException {
  const SilentAudioException([
    super.message = 'No sound was detected in the recording - check that the '
        'correct microphone is selected and not muted',
  ]);
}

/// The audible part of the recording is shorter than
/// [TranscriptionConfig.minAudioSeconds].
final class AudioTooShortException extends TranscriptionException {
  const AudioTooShortException(this.seconds, this.minimumSeconds)
      : super('Recording is too short to transcribe');

  final double seconds;
  final double minimumSeconds;
}

/// The recording is longer than [TranscriptionConfig.maxAudioSeconds].
final class AudioTooLongException extends TranscriptionException {
  const AudioTooLongException(this.seconds, this.maximumSeconds)
      : super('Recording is too long to transcribe');

  final double seconds;
  final double maximumSeconds;
}

/// whisper.cpp returned an error while running the model.
final class TranscriptionFailedException extends TranscriptionException {
  const TranscriptionFailedException(this.code)
      : super('Transcription failed (whisper.cpp error $code)');

  /// Return code from the native library.
  final int code;
}
