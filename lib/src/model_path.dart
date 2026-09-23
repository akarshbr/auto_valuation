/// Where the app's post-install download puts the Whisper model.
///
/// whisper.cpp reads the file in place: nothing is bundled with the app or
/// copied out of an asset. Pass this to [WhisperTranscriber.load]; if the
/// download has not happened yet, loading throws
/// [ModelNotDownloadedException].
const String whisperModelPath =
    '/storage/emulated/0/Android/data/com.orell/files/downloads/'
    'ggml-tiny.en-q5_1.bin';
