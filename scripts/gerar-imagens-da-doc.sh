#!/bin/zsh
# Refaz as imagens do README (docs/imagens) a partir das telas de verdade do app, com dados inventados:
# 1. ferramentas/telas-da-doc desenha o painel, a ilha e a janela "Quem falou?" em build/telas/;
# 2. ferramentas/foto-html monta as composições de docs/imagens/fonte/*.html e fotografa cada uma.
# Precisa do app já compilado uma vez (scripts/compilar-app.sh), pelas bibliotecas em build/.
set -euo pipefail
cd "${0:A:h}/.."
B=$(brew --prefix)
SHERPA=third_party/sherpa-onnx
mkdir -p build/telas
swiftc -O -swift-version 5 -target arm64-apple-macosx15.0 -import-objc-header motor/ponte.h \
  -I $B/include -I $B/opt/whisper.cpp/include -I $SHERPA/include \
  -L build -ldf -leco -lc++ -L $B/opt/whisper.cpp/lib -lwhisper -L $B/lib -lggml -lggml-base -L $SHERPA/lib -lsherpa-onnx-c-api \
  -framework CoreAudio -framework AudioToolbox -framework AVFoundation -framework AppKit -framework SwiftUI \
  -framework ServiceManagement -framework EventKit -framework UserNotifications -framework ApplicationServices \
  -Xlinker -rpath -Xlinker "$PWD/$SHERPA/lib" \
  nucleo/*.swift ${(f)"$(ls barra/*.swift | grep -v main.swift)"} ferramentas/telas-da-doc/main.swift -o build/telas-da-doc
swiftc -O ferramentas/foto-html/main.swift -o build/foto-html
[[ -x build/desenhar-svg ]] || swiftc -O -swift-version 5 -target arm64-apple-macosx15.0 ferramentas/desenhar-svg/main.swift -o build/desenhar-svg

build/telas-da-doc build/telas
build/desenhar-svg barra/icone/Frevo.svg build/telas/icone.png 448 >/dev/null
F=docs/imagens/fonte
for pagina tamanho in banner "1280 640" como-funciona "1280 520" ilha "1280 600" transcricao "1100 700" \
                      quem-falou "1100 620" painel "1000 620" instalar "1100 800"; do
  build/foto-html $F/$pagina.html docs/imagens/$pagina.png ${=tamanho}
done
# a abertura tem degradês grandes: em JPEG fica com um quinto do tamanho
sips -s format jpeg -s formatOptions 88 docs/imagens/banner.png --out docs/imagens/banner.jpg >/dev/null
rm docs/imagens/banner.png
echo "imagens em docs/imagens"
