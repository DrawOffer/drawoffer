#ifndef DRAWOFFER_SHERPA_SHIM_H
#define DRAWOFFER_SHERPA_SHIM_H

#include <stdint.h>

// sherpa-onnx 的最小封装：动态库在运行时 dlopen，缺库时本机识别不可用，App 照常启动。
// 只暴露 SenseVoice + Silero VAD 这一种用法；输入固定 16 kHz 单声道 float。

/// 加载 libsherpa-onnx-c-api.dylib；成功返回 1。可重复调用。
int dos_sherpa_load(const char *library_path);

typedef struct DOSRecognizer DOSRecognizer;

/// 一段说话的识别结果。时间单位为秒，`start` 是这段在整段录音里的起点，`times` 相对这段起点。
typedef struct DOSSegment {
  char *text;
  int32_t count;
  char **tokens;
  float *times;
  double start;
  double duration;
} DOSSegment;

DOSRecognizer *dos_sherpa_create(const char *model, const char *tokens, const char *vad_model, int32_t threads);
void dos_sherpa_accept(DOSRecognizer *recognizer, const float *samples, int32_t count);
/// 录音结束：把 VAD 里没说完的最后一段也切出来。
void dos_sherpa_flush(DOSRecognizer *recognizer);
/// 取下一段已切好的说话并识别；没有时返回 NULL。识别较慢，不要在音频线程调用。
DOSSegment *dos_sherpa_next(DOSRecognizer *recognizer);
void dos_sherpa_free_segment(DOSSegment *segment);
void dos_sherpa_destroy(DOSRecognizer *recognizer);

#endif
