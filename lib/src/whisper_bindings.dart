import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart';

// Signatures for native/whisper_shim.cpp. Four entry points is the whole
// surface: load, transcribe, read text, free.

typedef _InitNative = Pointer<Void> Function(Pointer<Utf8>, Int32);
typedef _InitDart = Pointer<Void> Function(Pointer<Utf8>, int);

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

typedef _RunNative = Int32 Function(
    Pointer<Void>, Pointer<Float>, Int32, Pointer<Utf8>, Int32, Int32);
typedef _RunDart = int Function(
    Pointer<Void>, Pointer<Float>, int, Pointer<Utf8>, int, int);

typedef _TextNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _TextDart = Pointer<Utf8> Function(Pointer<Void>);

/// Resolved entry points of the native library.
///
/// Cached per isolate: a [DynamicLibrary] handle cannot cross an isolate
/// boundary, but the native context it produces is plain process memory, so
/// its *address* can - which is how the worker isolate reaches the model.
class WhisperBindings {
  WhisperBindings._(DynamicLibrary library)
      : init = library.lookupFunction<_InitNative, _InitDart>('av_whisper_init'),
        free =
            library.lookupFunction<_FreeNative, _FreeDart>('av_whisper_free'),
        run = library.lookupFunction<_RunNative, _RunDart>('av_whisper_run'),
        text = _lookupTextFunction(library);

  static _TextDart _lookupTextFunction(DynamicLibrary library) {
    try {
      return library.lookupFunction<_TextNative, _TextDart>('av_whisper_text');
    } catch (_) {
      return library.lookupFunction<_TextNative, _TextDart>('av_whisper_full_text');
    }
  }

  /// `av_whisper_init(model_path, use_gpu)` -> context or `nullptr`.
  final _InitDart init;

  /// `av_whisper_free(context)`.
  final _FreeDart free;

  /// `av_whisper_run(context, samples, n_samples, language, n_threads, single_segment)`
  /// -> `0` on success, negative on failure.
  final _RunDart run;

  /// `av_whisper_text(context)` -> UTF-8 transcript of the last run. Owned by
  /// the context and valid until the next run or free.
  final _TextDart text;

  static WhisperBindings? _cached;

  /// Opens the platform library and resolves the symbols once per isolate.
  static WhisperBindings open() => _cached ??= WhisperBindings._(_openLibrary());

  static DynamicLibrary _openLibrary() {
    // iOS and macOS statically link the shim into the app binary.
    if (Platform.isIOS || Platform.isMacOS) return DynamicLibrary.process();
    if (Platform.isWindows) {
      return DynamicLibrary.open('audio_valuation_native.dll');
    }
    return DynamicLibrary.open('libaudio_valuation_native.so');
  }
}
