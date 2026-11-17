// Só o que a transcrição usa em C: Whisper (whisper.cpp) e sherpa-onnx (vozes). É a ponte da versão de Windows,
// que por enquanto só transcreve; a ponte completa, com o DeepFilterNet e o cancelador de eco, é motor/ponte.h.
#include <whisper.h>
#include <ggml-backend.h>
#include <sherpa-onnx/c-api/c-api.h>
