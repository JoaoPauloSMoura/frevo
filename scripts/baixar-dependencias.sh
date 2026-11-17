#!/bin/zsh
# Baixa as bibliotecas de terceiros nas versões testadas.
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p third_party

baixar() { # pasta url commit
  if [[ ! -d "third_party/$1/.git" ]]; then
    git clone -q "$2" "third_party/$1"
  fi
  git -C "third_party/$1" fetch -q --depth 1 origin "$3" 2>/dev/null || true
  git -C "third_party/$1" checkout -q "$3"
  echo "$1 @ $3"
}

baixar DeepFilterNet https://github.com/Rikorose/DeepFilterNet.git d375b2d
baixar libASPL https://github.com/gavv/libASPL.git 633e0f7

# sherpa-onnx (Apache-2.0): biblioteca C já compilada, para separar vozes e tirar impressão de voz
SHERPA_VER=2.0.1
if [[ ! -f third_party/sherpa-onnx/lib/libsherpa-onnx-c-api.dylib ]]; then
  mkdir -p third_party/sherpa-onnx/include/sherpa-onnx/c-api
  curl -sSfL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA_VER/sherpa-onnx-v$SHERPA_VER-osx-arm64-shared-no-tts-lib.tar.bz2" \
    | tar xj -C third_party/sherpa-onnx --strip-components 1
  rm -f third_party/sherpa-onnx/lib/libsherpa-onnx-cxx-api.dylib
  curl -sSfL -o third_party/sherpa-onnx/include/sherpa-onnx/c-api/c-api.h \
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$SHERPA_VER/sherpa-onnx/c-api/c-api.h"
fi
echo "sherpa-onnx @ v$SHERPA_VER"

# modelos de voz: ERes2NetV2 do 3D-Speaker (Apache-2.0) e segmentação 3.0 do pyannote (MIT)
M=third_party/modelos
mkdir -p $M
[[ -f $M/eres2netv2_3dspeaker.onnx ]] || curl -sSfL -o $M/eres2netv2_3dspeaker.onnx \
  https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx
if [[ ! -f $M/pyannote_segmentation_3.onnx ]]; then
  curl -sSfL https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2 \
    | tar xj -C $M sherpa-onnx-pyannote-segmentation-3-0/model.onnx sherpa-onnx-pyannote-segmentation-3-0/LICENSE
  mv $M/sherpa-onnx-pyannote-segmentation-3-0/model.onnx $M/pyannote_segmentation_3.onnx
  mv $M/sherpa-onnx-pyannote-segmentation-3-0/LICENSE $M/pyannote_segmentation_3.LICENSE
  rmdir $M/sherpa-onnx-pyannote-segmentation-3-0
fi
# classificador de sons (fala × música): CED mini (Apache-2.0)
if [[ ! -f $M/ced_mini_sons.int8.onnx ]]; then
  CED=sherpa-onnx-ced-mini-audio-tagging-2024-04-19
  curl -sSfL "https://github.com/k2-fsa/sherpa-onnx/releases/download/audio-tagging-models/$CED.tar.bz2" \
    | tar xj -C $M $CED/model.int8.onnx $CED/class_labels_indices.csv
  mv $M/$CED/model.int8.onnx $M/ced_mini_sons.int8.onnx
  mv $M/$CED/class_labels_indices.csv $M/ced_mini_sons.csv
  rmdir $M/$CED
fi
echo "modelos de voz e de sons em $M"
