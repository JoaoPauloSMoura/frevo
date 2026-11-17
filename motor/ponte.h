// Tudo em C que o app usa: DeepFilterNet (libDF), Whisper (whisper.cpp), sherpa-onnx (vozes) e o cancelador
// de eco do WebRTC (motor/eco.h).
#include "deep_filter.h"
#include <whisper.h>
#include <ggml-backend.h>
#include <sherpa-onnx/c-api/c-api.h>
#include "eco.h"
