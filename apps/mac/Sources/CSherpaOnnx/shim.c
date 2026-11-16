#include "sherpa_shim.h"

#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

#include "vendor/c-api.h"

#define SAMPLE_RATE 16000

// 只取类型、不引用符号：链接期不依赖 sherpa-onnx，全部经 dlsym 调用。
#define FN(name) static __typeof__(&name) p_##name
FN(SherpaOnnxCreateOfflineRecognizer);
FN(SherpaOnnxDestroyOfflineRecognizer);
FN(SherpaOnnxCreateOfflineStream);
FN(SherpaOnnxDestroyOfflineStream);
FN(SherpaOnnxAcceptWaveformOffline);
FN(SherpaOnnxDecodeOfflineStream);
FN(SherpaOnnxGetOfflineStreamResult);
FN(SherpaOnnxDestroyOfflineRecognizerResult);
FN(SherpaOnnxCreateVoiceActivityDetector);
FN(SherpaOnnxDestroyVoiceActivityDetector);
FN(SherpaOnnxVoiceActivityDetectorAcceptWaveform);
FN(SherpaOnnxVoiceActivityDetectorEmpty);
FN(SherpaOnnxVoiceActivityDetectorFront);
FN(SherpaOnnxVoiceActivityDetectorPop);
FN(SherpaOnnxVoiceActivityDetectorFlush);
FN(SherpaOnnxDestroySpeechSegment);

static int loaded = 0;

int dos_sherpa_load(const char *library_path) {
  if (loaded) return 1;
  void *handle = dlopen(library_path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) return 0;
#define LOAD(name)                                     \
  p_##name = (__typeof__(p_##name))dlsym(handle, #name); \
  if (!p_##name) return 0
  LOAD(SherpaOnnxCreateOfflineRecognizer);
  LOAD(SherpaOnnxDestroyOfflineRecognizer);
  LOAD(SherpaOnnxCreateOfflineStream);
  LOAD(SherpaOnnxDestroyOfflineStream);
  LOAD(SherpaOnnxAcceptWaveformOffline);
  LOAD(SherpaOnnxDecodeOfflineStream);
  LOAD(SherpaOnnxGetOfflineStreamResult);
  LOAD(SherpaOnnxDestroyOfflineRecognizerResult);
  LOAD(SherpaOnnxCreateVoiceActivityDetector);
  LOAD(SherpaOnnxDestroyVoiceActivityDetector);
  LOAD(SherpaOnnxVoiceActivityDetectorAcceptWaveform);
  LOAD(SherpaOnnxVoiceActivityDetectorEmpty);
  LOAD(SherpaOnnxVoiceActivityDetectorFront);
  LOAD(SherpaOnnxVoiceActivityDetectorPop);
  LOAD(SherpaOnnxVoiceActivityDetectorFlush);
  LOAD(SherpaOnnxDestroySpeechSegment);
#undef LOAD
  loaded = 1;
  return 1;
}

struct DOSRecognizer {
  const SherpaOnnxOfflineRecognizer *recognizer;
  const SherpaOnnxVoiceActivityDetector *vad;
};

DOSRecognizer *dos_sherpa_create(const char *model, const char *tokens, const char *vad_model, int32_t threads) {
  if (!loaded) return NULL;
  SherpaOnnxOfflineRecognizerConfig config;
  memset(&config, 0, sizeof(config));
  config.feat_config.sample_rate = SAMPLE_RATE;
  config.feat_config.feature_dim = 80;
  config.model_config.sense_voice.model = model;
  config.model_config.sense_voice.language = "auto";
  config.model_config.sense_voice.use_itn = 1;
  config.model_config.tokens = tokens;
  config.model_config.num_threads = threads;
  config.model_config.provider = "cpu";
  config.decoding_method = "greedy_search";
  const SherpaOnnxOfflineRecognizer *recognizer = p_SherpaOnnxCreateOfflineRecognizer(&config);
  if (!recognizer) return NULL;

  SherpaOnnxVadModelConfig vad_config;
  memset(&vad_config, 0, sizeof(vad_config));
  vad_config.silero_vad.model = vad_model;
  vad_config.silero_vad.threshold = 0.5f;
  // 停顿 0.5 秒切一段；单段最长 20 秒，SenseVoice 在这个长度内最准。
  vad_config.silero_vad.min_silence_duration = 0.5f;
  vad_config.silero_vad.min_speech_duration = 0.25f;
  vad_config.silero_vad.window_size = 512;
  vad_config.silero_vad.max_speech_duration = 20.0f;
  vad_config.sample_rate = SAMPLE_RATE;
  vad_config.num_threads = 1;
  const SherpaOnnxVoiceActivityDetector *vad = p_SherpaOnnxCreateVoiceActivityDetector(&vad_config, 60.0f);
  if (!vad) {
    p_SherpaOnnxDestroyOfflineRecognizer(recognizer);
    return NULL;
  }
  DOSRecognizer *result = calloc(1, sizeof(DOSRecognizer));
  result->recognizer = recognizer;
  result->vad = vad;
  return result;
}

void dos_sherpa_accept(DOSRecognizer *r, const float *samples, int32_t count) {
  if (r && count > 0) p_SherpaOnnxVoiceActivityDetectorAcceptWaveform(r->vad, samples, count);
}

void dos_sherpa_flush(DOSRecognizer *r) {
  if (r) p_SherpaOnnxVoiceActivityDetectorFlush(r->vad);
}

static char *copy_string(const char *s) { return strdup(s ? s : ""); }

DOSSegment *dos_sherpa_next(DOSRecognizer *r) {
  if (!r || p_SherpaOnnxVoiceActivityDetectorEmpty(r->vad)) return NULL;
  const SherpaOnnxSpeechSegment *speech = p_SherpaOnnxVoiceActivityDetectorFront(r->vad);
  DOSSegment *segment = calloc(1, sizeof(DOSSegment));
  segment->start = speech->start > 0 ? (double)speech->start / SAMPLE_RATE : 0;
  segment->duration = (double)speech->n / SAMPLE_RATE;

  const SherpaOnnxOfflineStream *stream = p_SherpaOnnxCreateOfflineStream(r->recognizer);
  p_SherpaOnnxAcceptWaveformOffline(stream, SAMPLE_RATE, speech->samples, speech->n);
  p_SherpaOnnxDecodeOfflineStream(r->recognizer, stream);
  const SherpaOnnxOfflineRecognizerResult *result = p_SherpaOnnxGetOfflineStreamResult(stream);
  segment->text = copy_string(result ? result->text : NULL);
  if (result && result->count > 0 && result->tokens_arr) {
    segment->count = result->count;
    segment->tokens = calloc((size_t)result->count, sizeof(char *));
    segment->times = calloc((size_t)result->count, sizeof(float));
    for (int32_t i = 0; i < result->count; ++i) {
      segment->tokens[i] = copy_string(result->tokens_arr[i]);
      segment->times[i] = result->timestamps ? result->timestamps[i] : 0;
    }
  }
  if (result) p_SherpaOnnxDestroyOfflineRecognizerResult(result);
  p_SherpaOnnxDestroyOfflineStream(stream);
  p_SherpaOnnxDestroySpeechSegment(speech);
  p_SherpaOnnxVoiceActivityDetectorPop(r->vad);
  return segment;
}

void dos_sherpa_free_segment(DOSSegment *segment) {
  if (!segment) return;
  for (int32_t i = 0; i < segment->count; ++i) free(segment->tokens[i]);
  free(segment->tokens);
  free(segment->times);
  free(segment->text);
  free(segment);
}

void dos_sherpa_destroy(DOSRecognizer *r) {
  if (!r) return;
  p_SherpaOnnxDestroyVoiceActivityDetector(r->vad);
  p_SherpaOnnxDestroyOfflineRecognizer(r->recognizer);
  free(r);
}
