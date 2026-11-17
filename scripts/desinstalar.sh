#!/bin/zsh
# Tira o Frevo deste Mac: o app, o driver do microfone virtual e o certificado local.
#   scripts/desinstalar.sh          # mantém seus dados (memória de vozes, modelo do Whisper, chamadas sem nome)
#   scripts/desinstalar.sh --tudo   # apaga também esses dados e os ajustes
# As transcrições em ~/Documents/Ligações nunca são apagadas: são suas.
set -euo pipefail
cd "${0:A:h}/.."
ID=io.github.joaopaulosmoura.frevo

pkill -x Frevo 2>/dev/null || true
rm -rf /Applications/Frevo.app
echo "app removido"
scripts/instalar-driver.sh -u
security delete-identity -c "Frevo (assinatura local)" >/dev/null 2>&1 && echo "certificado local removido" || true

if [[ "${1:-}" == "--tudo" ]]; then
  read "r?Apagar também a memória de vozes, o modelo do Whisper (1,6 GB) e as chamadas guardadas? [s/N] " || true
  if [[ "${r:-}" == [sSyY]* ]]; then
    rm -rf ~/Library/Application\ Support/Frevo ~/Library/Logs/Frevo
    defaults delete $ID 2>/dev/null || true
    tccutil reset All $ID >/dev/null 2>&1 || true
    echo "dados, ajustes e permissões apagados"
  fi
fi
echo "Frevo desinstalado. As transcrições em ~/Documents/Ligações continuam lá."
