#!/bin/zsh
# Compila o app da barra de menu (build/Frevo.app), a versão de terminal (build/frevo)
# e as ferramentas de teste. Precisa de build/libdf.a (scripts/compilar-motor.sh), do Homebrew o whisper-cpp
# (brew install whisper-cpp) e do sherpa-onnx e dos modelos de voz (scripts/baixar-dependencias.sh).
set -euo pipefail
cd "${0:A:h}/.."

[[ -f build/libdf.a ]] || { echo "Falta build/libdf.a: rode scripts/compilar-motor.sh"; exit 1; }
[[ -f build/libeco.a ]] || { echo "Falta build/libeco.a: rode scripts/compilar-eco.sh"; exit 1; }
B=$(brew --prefix)
SHERPA=third_party/sherpa-onnx
MODELOS=(third_party/modelos/eres2netv2_3dspeaker.onnx third_party/modelos/pyannote_segmentation_3.onnx
         third_party/modelos/ced_mini_sons.int8.onnx third_party/modelos/ced_mini_sons.csv)
for m in $MODELOS $SHERPA/lib/libsherpa-onnx-c-api.dylib; do
  [[ -f $m ]] || { echo "Falta $m: rode scripts/baixar-dependencias.sh"; exit 1; }
done

SWIFT=(swiftc -O -swift-version 5 -target arm64-apple-macosx15.0 -import-objc-header motor/ponte.h
       -I $B/include -I $B/opt/whisper.cpp/include -I $SHERPA/include
       -L build -ldf -leco -lc++ -L $B/opt/whisper.cpp/lib -lwhisper -L $B/lib -lggml -lggml-base
       -L $SHERPA/lib -lsherpa-onnx-c-api
       -framework CoreAudio -framework AudioToolbox -framework AVFoundation)

# Assinatura estável: as permissões do macOS (Acessibilidade, áudio do sistema) ficam presas a ela e continuam
# valendo depois de cada atualização. Usa um certificado Apple Development, se houver; senão o certificado local
# do Frevo (scripts/criar-certificado.sh). Sem nenhum dos dois, assinatura improvisada (ad hoc), e as permissões
# precisam ser religadas a cada compilação.
IDENT=$(security find-identity -p codesigning -v 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
[[ -n "$IDENT" ]] || IDENT=$(security find-identity -p codesigning 2>/dev/null | awk 'index($0, "\"Frevo (assinatura local)\"") {print $2; exit}')
assinar() {
  if [[ -n "$IDENT" ]] && codesign --force --timestamp=none --sign "$IDENT" "$@" 2>/dev/null; then return; fi
  codesign --force --sign - "$@"
}

# app da barra de menu
APP="build/Frevo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
"${SWIFT[@]}" -framework AppKit -framework SwiftUI -framework ServiceManagement -framework EventKit -framework UserNotifications \
  -framework ApplicationServices -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  nucleo/*.swift barra/*.swift -o "$APP/Contents/MacOS/Frevo"
cp barra/Info.plist "$APP/Contents/Info.plist"
# versão (da marca do git, ex.: v0.3.0) e pasta do código, para o app saber se há versão nova e onde atualizar
VERSAO=$(git describe --tags --always --dirty 2>/dev/null || echo dev)
CURTA=$(git describe --tags --abbrev=0 2>/dev/null || true)
PL=/usr/libexec/PlistBuddy
$PL -c "Set :CFBundleShortVersionString ${${CURTA#v}:-0.0.0}" "$APP/Contents/Info.plist"
$PL -c "Add :FrevoVersao string $VERSAO" -c "Add :FrevoCodigo string $PWD" "$APP/Contents/Info.plist"
cp barra/icone/Frevo.icns "$APP/Contents/Resources/" # desenho em barra/icone/Frevo.svg (scripts/gerar-icone.sh)
cp build/recursos/DeepFilterNet3_onnx.tar.gz "$APP/Contents/Resources/"
cp $MODELOS "$APP/Contents/Resources/"
cp $SHERPA/lib/libsherpa-onnx-c-api.dylib $SHERPA/lib/libonnxruntime.dylib "$APP/Contents/Frameworks/"
assinar "$APP/Contents/Frameworks/"*.dylib
assinar "$APP"
# (lê a saída inteira antes de procurar: com pipefail, um grep -q que sai cedo faria o codesign "falhar")
ASSINATURA=$(codesign -dvv "$APP" 2>&1)
if [[ "$ASSINATURA" == *"Authority=Apple Development"* ]]; then echo "assinado com o certificado Apple Development"
elif [[ "$ASSINATURA" == *"Authority=Frevo (assinatura local)"* ]]; then echo "assinado com o certificado local do Frevo"
else echo "assinatura ad hoc: rode scripts/criar-certificado.sh para as permissões não zerarem a cada atualização"; fi

# versão de terminal e ferramentas de teste (acham o sherpa-onnx na pasta do projeto)
SWIFT+=(-Xlinker -rpath -Xlinker "$PWD/$SHERPA/lib")
"${SWIFT[@]}" nucleo/*.swift cli/*.swift -o build/frevo
"${SWIFT[@]}" nucleo/*.swift ferramentas/motor-teste/main.swift -o build/motor-teste
"${SWIFT[@]}" nucleo/*.swift ferramentas/transcrever/main.swift -o build/transcrever
"${SWIFT[@]}" nucleo/*.swift ferramentas/gravar-outros/main.swift -o build/gravar-outros
"${SWIFT[@]}" nucleo/*.swift ferramentas/eco-teste/main.swift -o build/eco-teste

echo "app: $APP ($VERSAO) · ferramentas: build/frevo, motor-teste, transcrever, gravar-outros, eco-teste"
