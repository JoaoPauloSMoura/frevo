#!/bin/zsh
# Compila o driver Frevo.driver (AudioServerPlugIn) com a libASPL, sem CMake.
# Assina com assinatura local (ad hoc), que basta para instalar nesta máquina.
set -euo pipefail
cd "${0:A:h}/.."

ASPL=third_party/libASPL
SAIDA=build/Frevo.driver
OBJ=build/obj-driver
mkdir -p "$OBJ" "$SAIDA/Contents/MacOS"

FLAGS=(-std=c++17 -O2 -fPIC -arch arm64 -arch x86_64 -mmacosx-version-min=12.0
       -I "$ASPL/include" -I "$ASPL/src" -Wno-reorder-init-list)

rm -f "$OBJ"/*.o
for f in "$ASPL"/src/*.cpp; do
  clang++ "${FLAGS[@]}" -c "$f" -o "$OBJ/aspl-${${f:t}%.cpp}.o"
done
clang++ "${FLAGS[@]}" -c driver/Driver.cpp -o "$OBJ/frevo-driver.o"

clang++ -bundle -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
  -framework CoreFoundation -framework CoreAudio \
  "$OBJ"/*.o -o "$SAIDA/Contents/MacOS/Frevo"
cp driver/Info.plist "$SAIDA/Contents/Info.plist"
codesign --force --sign - "$SAIDA"
echo "driver: $SAIDA"
