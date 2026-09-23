/// On-device speech-to-text for Flutter.
///
/// A single-purpose transcription service: whisper.cpp through `dart:ffi`,
/// with all decoding and inference on a worker isolate so the UI never
/// stalls.
///
/// ```dart
/// final modelPath = await const WhisperModelInstaller()
///     .ensureInstalled('assets/models/ggml-tiny.en-q5_1.bin');
/// final transcriber = await WhisperTranscriber.load(modelPath);
///
/// final result = await transcriber.transcribePcm16(await recorder.stop());
/// print(result.text);
/// ```
library audio_valuation;

export 'src/audio_prep.dart' show PreparedAudio, prepareAudio;
export 'src/config.dart';
export 'src/exceptions.dart';
export 'src/model_installer.dart';
export 'src/pcm.dart'
    show WavInfo, decodeWav, parseWavHeader, pcm16Into, pcm16ToFloat32, resampleLinear;
export 'src/recorder.dart';
export 'src/transcriber.dart';
export 'src/whisper_transcriber.dart' show WhisperTranscriber;
