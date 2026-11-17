#!/bin/zsh
# Atualiza o Frevo para a versão mais nova publicada (uma marca vX.Y.Z no GitHub), ou para a marca pedida:
# baixa o código, recompila só o que mudou, espera a chamada acabar e reinstala. O app chama este script pelo
# botão "Atualizar"; dá para rodar no terminal também. O registro fica em ~/Library/Logs/Frevo/atualizacao.log.
#
#   scripts/atualizar.sh            # versão mais nova
#   scripts/atualizar.sh v0.3.0     # uma versão específica
set -euo pipefail
# Tudo dentro de uma função: o shell lê o script inteiro antes de começar, e o `git checkout` abaixo pode trocar
# este próprio arquivo no meio do caminho.
atualizar() {
cd "${ZSH_ARGZERO:A:h}/.."
LOG=${FREVO_LOG:-~/Library/Logs/Frevo/atualizacao.log}
mkdir -p "${LOG:h}"
# sem terminal (chamado pelo app), tudo vai para o registro: o app fecha no meio e não pode receber nada
[[ -t 1 ]] || exec >>"$LOG" 2>&1
print "\n=== $(date '+%d/%m/%Y %H:%M') atualização"
# o Homebrew não está no PATH quando o app chama o script
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

git fetch --tags --quiet origin
ALVO=${1:-$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)}
[[ -n "$ALVO" ]] || { echo "Nenhuma versão publicada ainda."; exit 1; }
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "Há mudanças suas no código desta pasta: atualize à mão (git stash, git checkout $ALVO, scripts/instalar.sh)."
  exit 2
fi
ANTES=$(git rev-parse HEAD)
git checkout --quiet --detach "$ALVO"
echo "código: $(git rev-parse --short "$ANTES") → $ALVO"

mudou() { ! git diff --quiet "$ANTES" HEAD -- "$@" }
mudou scripts/baixar-dependencias.sh && scripts/baixar-dependencias.sh
if [[ ! -f build/libdf.a ]] || mudou scripts/compilar-motor.sh; then scripts/compilar-motor.sh; fi
if [[ ! -f build/libeco.a ]] || mudou motor/eco.cpp motor/eco.h scripts/compilar-eco.sh; then scripts/compilar-eco.sh; fi
scripts/criar-certificado.sh
scripts/compilar-app.sh
DRIVER=0
if [[ ! -d build/Frevo.driver ]] || mudou driver scripts/compilar-driver.sh; then
  scripts/compilar-driver.sh
  DRIVER=1
fi

# nunca troca nada no meio de uma chamada
while build/frevo --em-uso >/dev/null 2>&1; do
  echo "esperando a chamada acabar…"
  sleep 30
done

if (( DRIVER )); then
  echo "o driver mudou: reinstalando (o macOS pede a senha de administrador)"
  if [[ -t 0 ]]; then
    scripts/instalar-driver.sh
  else
    osascript -e "do shell script \"/bin/zsh '$PWD/scripts/instalar-driver.sh'\" with prompt \"O Frevo precisa da sua senha para atualizar o microfone virtual.\" with administrator privileges"
  fi
fi
scripts/instalar-app.sh
echo "Frevo atualizado para $ALVO."
}
atualizar "$@"
