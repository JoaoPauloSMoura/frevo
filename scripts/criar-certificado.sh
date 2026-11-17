#!/bin/zsh
# Cria, uma vez, um certificado de assinatura só deste Mac ("Frevo (assinatura local)") e o guarda no Chaveiro.
#
# Por quê: o macOS prende as permissões (Acessibilidade, gravação do áudio do sistema) à assinatura do app. Com a
# assinatura improvisada (ad hoc), cada compilação é um app "novo" e as permissões zeram a cada atualização.
# Assinando sempre com o mesmo certificado, elas continuam valendo. O certificado não sai deste Mac e não serve
# para distribuir o app a ninguém: é só para o Frevo que você mesmo compila.
#
# Se já houver um certificado "Apple Development" (de uma conta de desenvolvedor, mesmo gratuita), ele é usado no
# lugar e nada é criado.
set -euo pipefail
NOME="Frevo (assinatura local)"

if security find-identity -p codesigning -v 2>/dev/null | grep -q "Apple Development"; then
  echo "certificado: já existe um Apple Development; o Frevo será assinado com ele"
  exit 0
fi
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$NOME\""; then
  echo "certificado: \"$NOME\" já está no Chaveiro"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SENHA=$(uuidgen) # só protege o arquivo temporário até ele entrar no Chaveiro
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NOME" \
  -keyout "$TMP/chave.pem" -out "$TMP/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
openssl pkcs12 -export -name "$NOME" -inkey "$TMP/chave.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" -passout "pass:$SENHA"
# -T: o codesign pode usar a chave sem pedir autorização a cada compilação
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$SENHA" -T /usr/bin/codesign >/dev/null
echo "certificado: \"$NOME\" criado no Chaveiro (vale 10 anos, só neste Mac)"
