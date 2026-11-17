// Passa um arquivo de áudio pelo isolamento de voz da Apple (AUSoundIsolation, macOS 13+).
// Uso: apple_isolamento <entrada.wav> <saida.wav> [tipo: 0 = voz alta qualidade (macOS 15+), 1 = voz] [mistura 0-100]
// Imprime "segundos=<tempo de processamento>" no fim.

import AVFoundation
import AudioToolbox

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("uso: apple_isolamento <entrada> <saida> [tipo] [mistura]")
    exit(1)
}
let tipo = args.count > 3 ? Float(args[3])! : 0
let mistura = args.count > 4 ? Float(args[4])! : 100

let entrada = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let formato = entrada.processingFormat

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let desc = AudioComponentDescription(
    componentType: kAudioUnitType_Effect,
    componentSubType: kAudioUnitSubType_AUSoundIsolation,
    componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
let isolamento = AVAudioUnitEffect(audioComponentDescription: desc)

engine.attach(player)
engine.attach(isolamento)
engine.connect(player, to: isolamento, format: formato)
engine.connect(isolamento, to: engine.mainMixerNode, format: formato)

func param(_ id: Int, _ valor: Float) {
    let st = AudioUnitSetParameter(isolamento.audioUnit, AudioUnitParameterID(id), kAudioUnitScope_Global, 0, valor, 0)
    if st != noErr { FileHandle.standardError.write("parametro \(id) falhou: \(st)\n".data(using: .utf8)!) }
}
param(Int(kAUSoundIsolationParam_SoundToIsolate), tipo)
param(Int(kAUSoundIsolationParam_WetDryMixPercent), mistura)

try engine.enableManualRenderingMode(.offline, format: formato, maximumFrameCount: 1024)
try engine.start()
player.scheduleFile(entrada, at: nil)
player.play()

let latencia = AVAudioFramePosition(isolamento.auAudioUnit.latency * formato.sampleRate)
let total = entrada.length + latencia
let saida = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: formato.settings)
let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!

var descartar = latencia  // tira o atraso do começo para alinhar com o original
let t0 = Date()
while engine.manualRenderingSampleTime < total {
    let falta = AVAudioFrameCount(min(Int64(buffer.frameCapacity), total - engine.manualRenderingSampleTime))
    let status = try engine.renderOffline(falta, to: buffer)
    guard status == .success else { break }
    if descartar >= AVAudioFramePosition(buffer.frameLength) {
        descartar -= AVAudioFramePosition(buffer.frameLength)
        continue
    }
    if descartar > 0 {
        let resto = Int(buffer.frameLength) - Int(descartar)
        let parte = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(resto))!
        parte.frameLength = AVAudioFrameCount(resto)
        for c in 0..<Int(buffer.format.channelCount) {
            parte.floatChannelData![c].update(from: buffer.floatChannelData![c] + Int(descartar), count: resto)
        }
        descartar = 0
        try saida.write(from: parte)
    } else {
        try saida.write(from: buffer)
    }
}
let segundos = Date().timeIntervalSince(t0)
saida.close()  // fecha o arquivo e grava o cabeçalho
print("latencia_ms=\(Int(isolamento.auAudioUnit.latency * 1000)) segundos=\(segundos)")
