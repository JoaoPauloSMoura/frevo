#!/bin/zsh
# Copia o Frevo.app para a pasta Aplicativos e abre (fechando a versão anterior, se estiver aberta).
set -euo pipefail
cd "${0:A:h}/.."

[[ -d "build/Frevo.app" ]] || { echo "Falta build/Frevo.app: rode scripts/compilar-app.sh"; exit 1; }
pkill -x Frevo 2>/dev/null || true
rm -rf "/Applications/Frevo.app"
cp -R "build/Frevo.app" /Applications/
open "/Applications/Frevo.app"
echo "Frevo instalado em Aplicativos e aberto. Procure a sombrinha na barra de menu."
