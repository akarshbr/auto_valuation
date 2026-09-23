// Minimal C ABI over whisper.cpp for Dart FFI - transcription only.
//
// whisper_full() takes a large `whisper_full_params` struct BY VALUE. Mirroring
// that struct in Dart is fragile - its layout changes between whisper.cpp
// releases and a mismatch corrupts the stack silently. This shim keeps the
// struct on the C++ side and exposes four primitive entry points, so the Dart
// bindings stay stable across whisper.cpp upgrades.

#include "whisper.h"

#include <cstring>
#include <string>

struct av_whisper {
  whisper_context* ctx = nullptr;
  std::string text;
  std::string language;
};

extern "C" {

// Loads a ggml model. Returns nullptr on failure.
void* av_whisper_init(const char* model_path, int use_gpu) {
  whisper_context_params cparams = whisper_context_default_params();
  cparams.use_gpu = use_gpu != 0;

  whisper_context* ctx = whisper_init_from_file_with_params(model_path, cparams);
  if (ctx == nullptr) return nullptr;

  av_whisper* handle = new av_whisper();
  handle->ctx = ctx;
  return handle;
}

void av_whisper_free(void* handle) {
  av_whisper* h = static_cast<av_whisper*>(handle);
  if (h == nullptr) return;
  if (h->ctx != nullptr) whisper_free(h->ctx);
  delete h;
}

// Transcribes mono 16 kHz float samples. `language` is an ISO 639-1 code or
// "auto". Returns 0 on success, a negative value on failure. Not reentrant:
// the Dart side serialises calls per context.
int av_whisper_run(void* handle, const float* samples, int n_samples,
                   const char* language, int n_threads, int single_segment) {
  av_whisper* h = static_cast<av_whisper*>(handle);
  if (h == nullptr || h->ctx == nullptr || samples == nullptr) return -1;
  if (n_samples <= 0) return -2;

  h->text.clear();
  h->language = (language != nullptr && language[0] != '\0') ? language : "auto";

  whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  params.language         = h->language.c_str();
  params.detect_language  = false;
  params.translate        = false;
  params.n_threads        = n_threads > 0 ? n_threads : 2;
  params.greedy.best_of   = 1;
  params.temperature      = 0.0f;
  params.temperature_inc  = 0.0f;   // disable temperature fallback retries for fast single-pass inference
  params.no_context       = true;   // independent requests, nothing to carry over
  params.no_timestamps    = true;   // skip timestamp tokens: fewer decoder steps
  params.token_timestamps = false;  // no per-token timing work
  params.suppress_blank   = true;
  params.single_segment   = single_segment != 0;
  params.print_progress   = false;
  params.print_realtime   = false;
  params.print_timestamps = false;
  params.print_special    = false;

  const int rc = whisper_full(h->ctx, params, samples, n_samples);
  if (rc != 0) return rc < 0 ? rc : -rc;

  const int n_segments = whisper_full_n_segments(h->ctx);
  for (int s = 0; s < n_segments; ++s) {
    const char* seg = whisper_full_get_segment_text(h->ctx, s);
    if (seg == nullptr || seg[0] == '\0') continue;
    if (!h->text.empty()) h->text += ' ';
    h->text += seg;
  }
  return 0;
}

// Transcript of the last successful run.
const char* av_whisper_text(void* handle) {
  av_whisper* h = static_cast<av_whisper*>(handle);
  return h == nullptr ? "" : h->text.c_str();
}

const char* av_whisper_full_text(void* handle) {
  return av_whisper_text(handle);
}

}  // extern "C"
