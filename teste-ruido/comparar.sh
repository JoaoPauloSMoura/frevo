#!/bin/zsh
# Roda todos os modelos num áudio e abre a página de comparação.
# Uso: ./comparar.sh ~/Downloads/meu-audio.m4a [nome-do-teste]
set -e
cd "${0:A:h}"
if [[ -z "$1" ]]; then
  echo "Uso: ./comparar.sh <arquivo de áudio> [nome-do-teste]"
  exit 1
fi
.venv/bin/python -I scripts/comparar.py --abrir "$@" 2> >(grep -v Warning >&2)
