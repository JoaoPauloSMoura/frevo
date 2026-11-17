#!/bin/zsh
# Instala o Frevo neste Mac a partir do código: confere as ferramentas, baixa as bibliotecas e os modelos,
# compila tudo, instala o driver do microfone virtual e o app. Pode rodar de novo sem problema: só refaz o que falta.
#
#   git clone https://github.com/JoaoPauloSMoura/frevo.git && cd frevo && scripts/instalar.sh
set -euo pipefail
cd "${0:A:h}/.."
passo() { print -P "\n%B==> $1%b" }
falha() { print -P "\n%F{red}$1%f"; exit 1 }

passo "Conferindo o Mac"
[[ "$(uname -m)" == arm64 ]] || falha "O Frevo precisa de um Mac com Apple Silicon (M1 ou mais novo)."
macos=$(sw_vers -productVersion)
(( ${macos%%.*} >= 15 )) || falha "O Frevo precisa do macOS 15 ou mais novo (este Mac está no $macos)."
echo "macOS $macos, Apple Silicon"

passo "Ferramentas de compilação"
if ! xcode-select -p >/dev/null 2>&1; then
  xcode-select --install || true
  falha "Abriu a janela das ferramentas de linha de comando da Apple. Instale e rode scripts/instalar.sh de novo."
fi
command -v brew >/dev/null || falha "Falta o Homebrew. Instale pelo comando de https://brew.sh e rode scripts/instalar.sh de novo."
faltam=()
for f in rust whisper-cpp meson ninja; do brew list --formula $f >/dev/null 2>&1 || faltam+=$f; done
if (( ${#faltam} )); then
  echo "instalando pelo Homebrew: $faltam"
  brew install $faltam
else
  echo "rust, whisper-cpp, meson e ninja já instalados"
fi

passo "Bibliotecas e modelos (só na primeira vez)"
scripts/baixar-dependencias.sh

passo "Compilando (a primeira vez leva uns 10 minutos)"
[[ -f build/libdf.a ]] || scripts/compilar-motor.sh
[[ -f build/libeco.a ]] || scripts/compilar-eco.sh
scripts/criar-certificado.sh
scripts/compilar-driver.sh
scripts/compilar-app.sh

passo "Instalando o driver (pede a senha do Mac; o som corta por 1 ou 2 segundos)"
scripts/instalar-driver.sh

passo "Instalando o app"
scripts/instalar-app.sh

print -P "\n%BPronto!%b A sombrinha do Frevo está na barra de menu."
cat <<'FIM'

Falta pouco:
  1. Libere o que o macOS pedir: Microfone, Acessibilidade (ler o mudo do Meet/Zoom/Teams) e,
     na primeira chamada gravada, "Gravação de áudio do sistema".
  2. No Meet, Zoom, Teams ou Slack, escolha "Frevo" como microfone.

Quando sair versão nova, o próprio Frevo avisa no painel da barra de menu.
FIM
