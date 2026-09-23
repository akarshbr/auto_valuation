/// Tuning for the transcription pipeline.
///
/// Immutable and made only of primitives, so an instance can be handed to the
/// worker isolate without copying anything of consequence.
class TranscriptionConfig {
  const TranscriptionConfig({
    this.sampleRate = 16000,
    this.threads = 0,
    this.minAudioSeconds = 0.3,
    this.maxAudioSeconds = 300,
    this.trimSilence = true,
    this.silencePeakFloor = 1e-4,
    this.trimRelativeThreshold = 0.05,
    this.trimPaddingSeconds = 0.1,
    this.normaliseLevel = true,
    this.targetRms = 0.1,
    this.maxPeak = 0.99,
    this.singleSegment = true,
  })  : assert(sampleRate > 0),
        assert(minAudioSeconds >= 0),
        assert(maxAudioSeconds > minAudioSeconds),
        assert(trimRelativeThreshold >= 0 && trimRelativeThreshold < 1),
        assert(maxPeak > 0 && maxPeak <= 1);

  /// Sample rate the speech model expects. Whisper models are trained on
  /// 16 kHz mono; WAV input at any other rate is resampled to this.
  final int sampleRate;

  /// Threads whisper.cpp may use. `0` picks a sensible count for the device
  /// (up to four, never more than the CPU has).
  final int threads;

  /// Recordings shorter than this after trimming are rejected with
  /// [AudioTooShortException] rather than sent to the model.
  final double minAudioSeconds;

  /// Hard ceiling on input length. Anything longer is rejected with
  /// [AudioTooLongException] *before* it is decoded or copied, which bounds
  /// the memory a single request can take (float32 audio is 64 kB/second).
  final double maxAudioSeconds;

  /// Strip leading and trailing silence. Fewer samples means less work for
  /// the model, so leaving this on makes transcription faster, not slower.
  final bool trimSilence;

  /// Peak amplitude below this (~-80 dBFS) means the clip holds no sound at
  /// all and [SilentAudioException] is thrown.
  final double silencePeakFloor;

  /// Silence gate for trimming, relative to the clip's own peak. Because it
  /// is relative, a quiet recording is never trimmed to nothing.
  final double trimRelativeThreshold;

  /// Audio kept on either side of the detected speech when trimming.
  final double trimPaddingSeconds;

  /// Scale the clip towards [targetRms] (capped so it never clips). Cheap,
  /// and it helps the model with quiet recordings.
  final bool normaliseLevel;

  /// Target RMS level (~-20 dBFS) for normalisation.
  final double targetRms;

  /// Peak amplitude normalisation may never exceed.
  final double maxPeak;

  /// Stop transcription immediately after the first segment rather than
  /// searching for multiple segments across 30-second windows. Recommended
  /// for short clips, single sentences, and responsive voice interfaces.
  final bool singleSegment;

  int get minSamples => (minAudioSeconds * sampleRate).round();
  int get maxSamples => (maxAudioSeconds * sampleRate).round();
  int get trimPaddingSamples => (trimPaddingSeconds * sampleRate).round();

  static const TranscriptionConfig defaults = TranscriptionConfig();
}
