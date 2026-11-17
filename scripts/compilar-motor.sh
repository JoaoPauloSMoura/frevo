#!/bin/zsh
# Compila a libDF (DeepFilterNet3, Rust) como biblioteca estática e copia o modelo.
# Precisa do Rust (brew install rust). Baixa as dependências do crates.io na primeira vez.
set -euo pipefail
cd "${0:A:h}/.."

DFN=third_party/DeepFilterNet
export MACOSX_DEPLOYMENT_TARGET=15.0 # roda do macOS 15 em diante (o app usa Synchronization, do 15)
cargo build --release --manifest-path "$DFN/Cargo.toml" -p deep_filter --lib --no-default-features --features capi

mkdir -p build/recursos
cp "$DFN/target/release/libdf.a" build/libdf.a
cp "$DFN/models/DeepFilterNet3_onnx.tar.gz" build/recursos/
echo "motor: build/libdf.a e build/recursos/DeepFilterNet3_onnx.tar.gz"
