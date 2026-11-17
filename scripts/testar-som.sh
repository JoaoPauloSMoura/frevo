#!/bin/zsh
# Grava alguns segundos do "Frevo" (como um app de chamada faria), mostra o nível e toca de volta.
# O app Frevo precisa estar aberto. Uso: scripts/testar-som.sh [segundos]
set -euo pipefail
cd "${0:A:h}/.."
SEG=${1:-6}
ARQ=build/teste-de-som.wav
mkdir -p build

echo "Gravando $SEG s do Frevo. Fale normalmente agora..."
ffmpeg -hide_banner -loglevel error -y -f avfoundation -i ":Frevo" -t "$SEG" -ac 1 "$ARQ" < /dev/null
ffmpeg -i "$ARQ" -af "astats=measure_overall=RMS_level+Peak_level:measure_perchannel=none" -f null - 2>&1 \
  | grep -E "RMS level|Peak level" | sed 's/.*\] //'
echo "Tocando o que os outros ouviriam..."
afplay "$ARQ"
