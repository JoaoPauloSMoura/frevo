#!/bin/zsh
# Monta build/libeco.a: o cancelador de eco do WebRTC (webrtc-audio-processing 2.1, BSD) com o abseil e a
# ponte em C (motor/eco.cpp), tudo numa biblioteca estática que vai dentro do app.
# Precisa de meson e ninja (brew install meson ninja). Baixa o código uma vez para third_party/.
set -euo pipefail
cd "${0:A:h}/.."

VERSAO=2.1
PACOTE=webrtc-audio-processing-$VERSAO
SHA=ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
BAIXADO=third_party/webrtc-baixado
DESTINO=$PWD/third_party/webrtc

if [[ ! -f $DESTINO/lib/libwebrtc-audio-processing-2.a ]]; then
  mkdir -p $BAIXADO
  if [[ ! -d $BAIXADO/$PACOTE ]]; then
    curl -sfL https://freedesktop.org/software/pulseaudio/webrtc-audio-processing/$PACOTE.tar.xz -o $BAIXADO/$PACOTE.tar.xz
    [[ "$(shasum -a 256 $BAIXADO/$PACOTE.tar.xz | cut -d' ' -f1)" == $SHA ]] || { echo "checksum do $PACOTE não confere"; exit 1; }
    tar xf $BAIXADO/$PACOTE.tar.xz -C $BAIXADO
  fi
  (cd $BAIXADO/$PACOTE && rm -rf build &&
   MACOSX_DEPLOYMENT_TARGET=15.0 meson setup build --prefix="$DESTINO" --default-library=static --buildtype=release \
     --force-fallback-for=abseil-cpp -Db_ndebug=true &&
   MACOSX_DEPLOYMENT_TARGET=15.0 ninja -C build && meson install -C build)
fi
# o abseil é compilado junto (subprojeto do meson), mas não é instalado: as bibliotecas dele ficam na pasta da compilação
ABSL=($BAIXADO/$PACOTE/build/subprojects/abseil-cpp-*/*.a)

mkdir -p build/obj-eco
clang++ -std=c++17 -O2 -arch arm64 -mmacosx-version-min=15.0 -DWEBRTC_POSIX -DWEBRTC_MAC -DWEBRTC_LIBRARY_IMPL \
  -I "$DESTINO/include/webrtc-audio-processing-2" -I "$DESTINO/include" -I motor \
  -c motor/eco.cpp -o build/obj-eco/eco.o
libtool -static -o build/libeco.a build/obj-eco/eco.o "$DESTINO/lib/libwebrtc-audio-processing-2.a" $ABSL 2>/dev/null
echo "eco: build/libeco.a ($(du -h build/libeco.a | cut -f1))"
