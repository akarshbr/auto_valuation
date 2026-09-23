import 'dart:math' as math;
import 'dart:typed_data';

import 'config.dart';
import 'exceptions.dart';

/// The window of a clip worth sending to the model, plus the gain to apply.
///
/// Analysing and applying are separate steps so the final samples can be
/// written straight into whatever buffer the model reads from - the native
/// buffer, in production - instead of through an intermediate copy.
class PreparedAudio {
  const PreparedAudio({
    required this.start,
    required this.end,
    required this.gain,
    required this.sampleRate,
  });

  /// First sample (inclusive) of the window in the source clip.
  final int start;

  /// Last sample (exclusive) of the window in the source clip.
  final int end;

  /// Multiplier applied to every sample. `1.0` means untouched.
  final double gain;

  final int sampleRate;

  int get length => end - start;
  double get seconds => length / sampleRate;

  /// Copies the window from [source] into [destination] with [gain] applied.
  /// [destination] must have at least [length] elements.
  void writeInto(Float32List source, Float32List destination) {
    if (destination.length < length) {
      throw ArgumentError('destination holds ${destination.length} samples, '
          'window needs $length');
    }
    if (gain == 1.0) {
      destination.setRange(0, length, source, start);
      return;
    }
    final g = gain;
    var d = 0;
    for (var s = start; s < end; s++) {
      destination[d++] = source[s] * g;
    }
  }

  /// Convenience for callers that want a standalone list.
  Float32List apply(Float32List source) {
    final out = Float32List(length);
    writeInto(source, out);
    return out;
  }
}

/// Validates a mono clip at [TranscriptionConfig.sampleRate] and works out
/// what to feed the model: silence trimmed off both ends and the level
/// normalised. Two passes over the samples, no allocation.
///
/// Throws:
/// * [AudioFormatException] for an empty clip,
/// * [AudioTooLongException] before doing any work on an oversized clip,
/// * [SilentAudioException] when nothing audible is present,
/// * [AudioTooShortException] when what remains after trimming is too short.
PreparedAudio prepareAudio(
  Float32List audio, {
  TranscriptionConfig config = TranscriptionConfig.defaults,
}) {
  if (audio.isEmpty) {
    throw const AudioFormatException(
      'The recording contains no audio data - it may have been stopped '
      'before any sound was captured',
    );
  }
  if (audio.length > config.maxSamples) {
    throw AudioTooLongException(
      audio.length / config.sampleRate,
      config.maxAudioSeconds,
    );
  }

  // Pass 1: peak.
  var peak = 0.0;
  for (var i = 0; i < audio.length; i++) {
    final magnitude = audio[i].abs();
    if (magnitude > peak) peak = magnitude;
  }
  if (peak < config.silencePeakFloor) {
    throw const SilentAudioException();
  }

  // Trim to the first/last sample above a gate relative to this clip's peak.
  var start = 0;
  var end = audio.length;
  if (config.trimSilence) {
    final gate = peak * config.trimRelativeThreshold;
    var first = 0;
    while (first < audio.length && audio[first].abs() < gate) {
      first++;
    }
    var last = audio.length - 1;
    while (last > first && audio[last].abs() < gate) {
      last--;
    }
    final pad = config.trimPaddingSamples;
    start = math.max(0, first - pad);
    end = math.min(audio.length, last + 1 + pad);
  }

  final length = end - start;
  if (length < config.minSamples) {
    throw AudioTooShortException(
      length / config.sampleRate,
      config.minAudioSeconds,
    );
  }

  // Pass 2: RMS over the kept window, accumulated in double precision.
  var gain = 1.0;
  if (config.normaliseLevel) {
    var sumSquares = 0.0;
    for (var i = start; i < end; i++) {
      final s = audio[i];
      sumSquares += s * s;
    }
    final rms = math.sqrt(sumSquares / length);
    if (rms > 0) {
      gain = math.min(config.targetRms / rms, config.maxPeak / peak);
    }
  }

  return PreparedAudio(
    start: start,
    end: end,
    gain: gain,
    sampleRate: config.sampleRate,
  );
}
