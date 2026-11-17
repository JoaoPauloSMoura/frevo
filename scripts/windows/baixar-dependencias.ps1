# Prepara, no Windows, o que o núcleo do Frevo precisa para transcrever: compila o whisper.cpp (na mesma versão
# do Mac, só CPU por enquanto), baixa o sherpa-onnx pronto e os modelos de voz.
# Precisa de git, cmake e do Visual Studio (C++). Rode da pasta do projeto: scripts\windows\baixar-dependencias.ps1
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-Location (Join-Path $PSScriptRoot '..\..')
$tp = 'third_party'
New-Item -ItemType Directory -Force $tp, "$tp\modelos" | Out-Null

# whisper.cpp: a mesma versão que o Homebrew instala no Mac
$WHISPER = 'v1.9.5'
$w = "$tp\whisper-win"
if (-not (Test-Path "$w\lib\whisper.lib")) {
  if (-not (Test-Path "$tp\whisper.cpp")) {
    git clone -q --depth 1 --branch $WHISPER https://github.com/ggml-org/whisper.cpp.git "$tp\whisper.cpp"
  }
  # AVX2 fixo em vez de "nativo": o resultado roda em qualquer PC dos últimos ~10 anos, não só no que compilou
  cmake -S "$tp\whisper.cpp" -B "$tp\whisper.cpp\build" -DBUILD_SHARED_LIBS=ON -DWHISPER_BUILD_EXAMPLES=OFF `
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DGGML_NATIVE=OFF -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON
  cmake --build "$tp\whisper.cpp\build" --config Release --parallel
  New-Item -ItemType Directory -Force "$w\include", "$w\lib", "$w\bin" | Out-Null
  Copy-Item "$tp\whisper.cpp\include\*.h", "$tp\whisper.cpp\ggml\include\*.h" "$w\include"
  Get-ChildItem "$tp\whisper.cpp\build" -Recurse -Filter *.lib | Where-Object { $_.FullName -match '\\Release\\' } | Copy-Item -Destination "$w\lib"
  Get-ChildItem "$tp\whisper.cpp\build" -Recurse -Filter *.dll | Where-Object { $_.FullName -match '\\Release\\' } | Copy-Item -Destination "$w\bin"
}
Write-Host "whisper.cpp @ $WHISPER em $w"

# sherpa-onnx (Apache-2.0): biblioteca C já compilada, para separar vozes e tirar impressão de voz
$SHERPA = '2.0.1'
$s = "$tp\sherpa-onnx-win"
if (-not (Test-Path "$s\lib\sherpa-onnx-c-api.lib")) {
  New-Item -ItemType Directory -Force "$s\include\sherpa-onnx\c-api" | Out-Null
  curl.exe -sSfL -o "$tp\sherpa-onnx-win.tar.bz2" `
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v$SHERPA/sherpa-onnx-v$SHERPA-win-x64-shared-MD-Release-no-tts-lib.tar.bz2"
  tar xjf "$tp\sherpa-onnx-win.tar.bz2" -C $s --strip-components 1
  Remove-Item "$tp\sherpa-onnx-win.tar.bz2"
  curl.exe -sSfL -o "$s\include\sherpa-onnx\c-api\c-api.h" `
    "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$SHERPA/sherpa-onnx/c-api/c-api.h"
}
Write-Host "sherpa-onnx @ v$SHERPA em $s"

# modelos de voz: os mesmos do Mac (scripts/baixar-dependencias.sh)
$M = "$tp\modelos"
if (-not (Test-Path "$M\eres2netv2_3dspeaker.onnx")) {
  curl.exe -sSfL -o "$M\eres2netv2_3dspeaker.onnx" `
    https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2netv2_sv_zh-cn_16k-common.onnx
}
if (-not (Test-Path "$M\pyannote_segmentation_3.onnx")) {
  curl.exe -sSfL -o "$tp\pyannote.tar.bz2" `
    https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2
  tar xjf "$tp\pyannote.tar.bz2" -C $M
  Move-Item "$M\sherpa-onnx-pyannote-segmentation-3-0\model.onnx" "$M\pyannote_segmentation_3.onnx"
  Move-Item "$M\sherpa-onnx-pyannote-segmentation-3-0\LICENSE" "$M\pyannote_segmentation_3.LICENSE" -Force
  Remove-Item -Recurse "$M\sherpa-onnx-pyannote-segmentation-3-0", "$tp\pyannote.tar.bz2"
}
if (-not (Test-Path "$M\ced_mini_sons.int8.onnx")) {
  $CED = 'sherpa-onnx-ced-mini-audio-tagging-2024-04-19'
  curl.exe -sSfL -o "$tp\ced.tar.bz2" "https://github.com/k2-fsa/sherpa-onnx/releases/download/audio-tagging-models/$CED.tar.bz2"
  tar xjf "$tp\ced.tar.bz2" -C $M
  Move-Item "$M\$CED\model.int8.onnx" "$M\ced_mini_sons.int8.onnx"
  Move-Item "$M\$CED\class_labels_indices.csv" "$M\ced_mini_sons.csv"
  Remove-Item -Recurse "$M\$CED", "$tp\ced.tar.bz2"
}
Write-Host "modelos de voz e de sons em $M"
