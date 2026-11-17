#!/bin/zsh
# Instala (ou remove, com -u) o driver do Frevo. Pede a senha de administrador
# e reinicia o serviço de áudio do macOS: o som corta por 1 ou 2 segundos.
set -euo pipefail
cd "${0:A:h}/.."

HAL=/Library/Audio/Plug-Ins/HAL
DESTINO=$HAL/Frevo.driver

if [[ "${1:-}" == "-u" ]]; then
  sudo rm -rf "$DESTINO"
  echo "Driver removido."
else
  [[ -d build/Frevo.driver ]] || { echo "Falta build/Frevo.driver: rode scripts/compilar-driver.sh"; exit 1; }
  sudo rm -rf "$DESTINO"
  sudo cp -R build/Frevo.driver "$DESTINO"
  echo "Driver instalado em $DESTINO."
fi

sudo killall coreaudiod
sleep 2
system_profiler SPAudioDataType | grep -A4 "Frevo:" || echo "(o Frevo não apareceu na lista de áudio)"
