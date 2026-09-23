# audio_valuation — on-device speech-to-text (Flutter)

A single-purpose transcription service. whisper.cpp runs **inside the app** through
`dart:ffi` — no server, no network — and every heavy step (file decoding, PCM
conversion, resampling, silence trimming, inference) runs on a worker isolate, so the
UI thread is never blocked.

```dart
final transcriber = await WhisperTranscriber.load(whisperModelPath);

final result = await transcriber.transcribePcm16(pcmBytes, languageCode: 'en-IN');
result.text;            // "the quick brown fox jumps over the lazy dog"
result.audioSeconds;    // 2.9  (after trimming)
result.processingTime;  // 0:00:01.2
```

> **v3.0.0 — breaking.** All pronunciation/accent scoring, text alignment, the ONNX
> accent model and the `AudioValuationEngine` facade are gone. This package now only
> transcribes. See *Migrating from 2.x* at the bottom.

## API

`Transcriber` (implemented by `WhisperTranscriber`) accepts three kinds of input so
you can hand over whatever you already hold — conversion happens on the worker:

| Method | Input | Notes |
|---|---|---|
| `transcribePcm16(bytes)` | raw little-endian 16-bit PCM | **Preferred for recordings.** Half the size of float32 to move across isolates. Accepts `channels` and `sampleRate`; stereo is downmixed, other rates are resampled. |
| `transcribeWavFile(path)` | 16-bit PCM `.wav` | The file is read on the worker in 64 kB chunks. Only 16-bit integer PCM is supported; other encodings raise `AudioFormatException` naming what was found. |
| `transcribe(samples)` | mono float32 at 16 kHz | For audio you already have as floats. |

All three return a `TranscriptionResult` (`text`, `language`, `audioSeconds`,
`processingTime`) and throw one of:

| Exception | Meaning |
|---|---|
| `ModelNotDownloadedException` | no model file at the path yet — prompt for the download (carries `path`). A `ModelLoadException` subclass. |
| `ModelLoadException` | model file corrupt or incomplete, or native library not in the build |
| `AudioFormatException` | not a WAV / unsupported encoding / unreadable file / empty buffer |
| `SilentAudioException` | decoded fine but no audible sound (muted mic) |
| `AudioTooShortException` | under `minAudioSeconds` after trimming (carries the durations) |
| `AudioTooLongException` | over `maxAudioSeconds` — raised **before** the audio is decoded or copied |
| `TranscriptionFailedException` | whisper.cpp returned an error (carries the code) |

They all extend the sealed `TranscriptionException`, so `on TranscriptionException`
catches everything and `.message` is safe to show to a user. Using a transcriber after
`dispose()` is a programmer error and throws `StateError`.

Requests are **serialised** — whisper.cpp contexts are not reentrant — so concurrent
calls queue up rather than running in parallel. `dispose()` waits for queued work.

### Configuration

```dart
final transcriber = await WhisperTranscriber.load(
  modelPath,
  config: const TranscriptionConfig(
    threads: 0,              // 0 = auto (≤ 4, never more than the CPU has)
    maxAudioSeconds: 120,    // hard memory ceiling per request
    minAudioSeconds: 0.3,
    trimSilence: true,       // fewer samples → faster inference
    normaliseLevel: true,    // helps quiet recordings
  ),
);
```

### Recording

`TranscriptionRecorder` captures mono 16 kHz PCM16 — the model's format — so nothing
needs converting:

```dart
final recorder = TranscriptionRecorder();
await recorder.start();
// ...
final pcm = await recorder.stop();          // Uint8List, released not copied
final result = await transcriber.transcribePcm16(pcm);
```

See `example/lib/main.dart` for a complete screen.

## How the pipeline stays light

- **UI isolate does no audio work.** Input is wrapped in a `TransferableTypedData`
  (moved into the worker, not copied) or passed as a path. Model loading is also on a
  worker, so a 30–100 MB model does not stall the first frame.
- **One intermediate buffer per request.** On the worker, trimming and gain are
  written directly into the native float array whisper.cpp reads; there is no
  trimmed copy, no normalised copy. The buffer is freed before the result returns.
- **Bounded allocations.** `maxAudioSeconds` is checked from the byte count or WAV
  header *before* anything is decoded, so an oversized input never becomes an
  oversized allocation. WAV files are streamed through a 64 kB chunk buffer.
- **Fast PCM decode.** PCM16 → float uses an `Int16List` view (one multiply per
  sample), not per-sample `ByteData` reads.
- **Lean native shim.** The C++ side collects only the transcript — no per-token text
  or probability vectors — and runs whisper without timestamp tokens, which shortens
  the decode.
- **Model read in place.** The model is not bundled as an asset. whisper.cpp opens
  the downloaded file directly, so it is never loaded into the Dart heap or copied.

## Setup

**1. Add the package**

```yaml
dependencies:
  audio_valuation:
    path: ../audio_valuation
```

**2. Download the model after install**

The model is **not** a Flutter asset. The app downloads it after install to
`whisperModelPath`:

```
/storage/emulated/0/Android/data/com.orell/files/downloads/ggml-tiny.en-q5_1.bin
```

That is the app's own external storage directory, so no storage permission is
needed. Until the file is there, `WhisperTranscriber.load` throws
`ModelNotDownloadedException`. Catch it to offer the download:

```dart
try {
  transcriber = await WhisperTranscriber.load(whisperModelPath);
} on ModelNotDownloadedException catch (e) {
  showDownloadPrompt(saveTo: e.path);
}
```

Have the download write to a temporary name and rename it to the final path once
it completes. An interrupted download left at the final path would pass the
existence check and then fail as a `ModelLoadException`.

To test on a device without the download flow, fetch the model on your desktop and
push it:

```bash
./tools/fetch_whisper_model.sh tiny.en q5_1      # ~31 MB
adb push assets/models/ggml-tiny.en-q5_1.bin \
  /storage/emulated/0/Android/data/com.orell/files/downloads/
```

Use a multilingual model (drop the `.en`) for `hi-IN` or other languages. Pass
`languageCode: ''` to let the model auto-detect. A multilingual model has a different
file name, so change `whisperModelPath` to match.

**3. Build whisper.cpp into your app**

```bash
git clone https://github.com/ggml-org/whisper.cpp native/whisper.cpp
```

`native/whisper_shim.cpp` is a four-function C wrapper (`init`, `run`, `text`, `free`).
`whisper_full()` takes a large struct by value, and mirroring that layout in Dart breaks
silently whenever whisper.cpp changes it, so the struct stays on the C side.

- **Android** — point `externalNativeBuild` at `native/CMakeLists.txt`
- **iOS/macOS** — add whisper.cpp's xcframework and `whisper_shim.cpp` to the target
  (`DynamicLibrary.process()` picks it up)

## Tests

```bash
flutter test
```

`test/audio_test.dart` covers PCM decoding (aligned, unaligned, stereo), WAV header
parsing and its error cases, resampling, silence/too-short/too-long rejection, trimming
and level normalisation, and language-code handling. No model or native build needed.

## Footprint

Whisper tiny q5_1 is about 31 MB on disk and roughly 90 MB resident during
transcription. Dart-side memory per request is one float32 copy of the clip
(64 kB per second of audio) plus the native input buffer of the trimmed clip.

## Migrating from 2.x

| 2.x | 3.x |
|---|---|
| `AudioValuationEngine.convertStudentAudio(audio: samples)` | `transcriber.transcribe(samples)` (or `transcribePcm16` / `transcribeWavFile`) |
| `engine.valuate(...)`, `valuateUserAudio(...)` | removed — scoring is no longer part of this package |
| `ValuationResult`, `UserAudioResult`, `PronunciationOutcome`, `RecognisedWord` | removed; use `TranscriptionResult` |
| `ValuationException` (with HTTP-style `code`) | `TranscriptionException` subclasses |
| `ValuationConfig` | `TranscriptionConfig` (scoring fields removed) |
| `ValuationRecorder.stop()` → `Float32List` | `TranscriptionRecorder.stop()` → `Uint8List` PCM16 |
| `OnnxAccentScorer`, `AccentScorer`, `onnxruntime` dependency | removed |
| `cleanText`, `wordsOf`, `align`, `pronunciationScore`, `clarityScore` | removed |
