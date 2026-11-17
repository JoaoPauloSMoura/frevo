#!/bin/zsh
# Gera o ícone do app (barra/icone/Frevo.icns) a partir de barra/icone/Frevo.svg.
# Só precisa rodar de novo quando o desenho mudar: o .icns gerado fica no repositório.
set -euo pipefail
cd "${0:A:h}/.."

mkdir -p build
swiftc -O -swift-version 5 -target arm64-apple-macosx15.0 ferramentas/desenhar-svg/main.swift -o build/desenhar-svg
CONJ=build/Frevo.iconset
rm -rf "$CONJ" && mkdir -p "$CONJ"
build/desenhar-svg barra/icone/Frevo.svg "$CONJ/icon_512x512@2x.png" 1024
for lado in 16 32 128 256 512; do
  sips -z $lado $lado "$CONJ/icon_512x512@2x.png" --out "$CONJ/icon_${lado}x${lado}.png" >/dev/null
  sips -z $((lado * 2)) $((lado * 2)) "$CONJ/icon_512x512@2x.png" --out "$CONJ/icon_${lado}x${lado}@2x.png" >/dev/null
done
iconutil -c icns "$CONJ" -o barra/icone/Frevo.icns
echo "ícone: barra/icone/Frevo.icns"
