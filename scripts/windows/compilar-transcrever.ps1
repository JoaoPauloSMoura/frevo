# Compila, no Windows, a ferramenta de transcrição (build\transcrever.exe) com o mesmo núcleo em Swift do Mac.
# Por enquanto só a transcrição: o microfone limpo e o app da bandeja vêm depois.
# Precisa do Swift para Windows (swift.org) e de scripts\windows\baixar-dependencias.ps1 rodado antes.
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Set-Location (Join-Path $PSScriptRoot '..\..')
$w = 'third_party\whisper-win'
$s = 'third_party\sherpa-onnx-win'
foreach ($f in "$w\lib\whisper.lib", "$s\lib\sherpa-onnx-c-api.lib") {
  if (-not (Test-Path $f)) { throw "Falta ${f}: rode scripts\windows\baixar-dependencias.ps1" }
}

# a parte do núcleo que não depende do Mac (sem Core Audio, sem AVFoundation)
$nucleo = 'Chamados', 'Contas', 'DetectorDeFala', 'ImpressaoDeVoz', 'Modelos', 'QuemFala', 'SeparadorDeVozes',
          'Transcritor', 'Wav' | ForEach-Object { "nucleo\$_.swift" }

New-Item -ItemType Directory -Force build | Out-Null
swiftc -O -swift-version 5 -import-objc-header motor\ponte-transcricao.h `
  -I "$w\include" -I "$s\include" -L "$w\lib" -L "$s\lib" `
  -lwhisper -lggml -lggml-base -lsherpa-onnx-c-api `
  @nucleo ferramentas\transcrever\main.swift -o build\transcrever.exe

# as bibliotecas (DLLs) ficam ao lado do executável, que é onde o Windows procura primeiro
Copy-Item "$w\bin\*.dll", "$s\lib\*.dll" build\
Write-Host "build\transcrever.exe"
