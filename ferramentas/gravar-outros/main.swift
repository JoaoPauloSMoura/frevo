import CoreAudio
import Foundation

// gravar-outros: grava o som do app que está usando o Frevo (a voz dos outros na chamada).
// Uso: gravar-outros <saida.wav> [segundos]   (Ctrl+C ou SIGTERM param e fecham o arquivo)

setvbuf(stdout, nil, _IOLBF, 0)
let a = CommandLine.arguments
guard a.count >= 2 else {
    print("Uso: gravar-outros <saida.wav> [segundos]")
    exit(1)
}
guard let mic = Audio.porUID(Audio.uidMic) else {
    print("Frevo não encontrado")
    exit(1)
}
let processos = Audio.processosUsando(mic)
print("apps usando o Frevo: \(processos.compactMap { Audio.nomeDoApp($0) }.joined(separator: ", "))")

let destino = URL(fileURLWithPath: a[1])
let captura: CapturaDoSistema
do {
    captura = try CapturaDoSistema(processos: processos) { taxa in
        print("captura em \(Int(taxa)) Hz")
        return try Trilha(url: destino, taxa: taxa)
    }
} catch {
    print("Erro: \(error)")
    exit(1)
}

let fila = DispatchQueue(label: "drenar")
let timer = DispatchSource.makeTimerSource(queue: fila)
timer.schedule(deadline: .now() + 0.5, repeating: 0.25)
timer.setEventHandler { captura.trilha.drenar() }
timer.resume()

let comeco = Date()
func encerrar() {
    let f = captura.formato
    let l = captura.layout.load(ordering: .relaxed)
    let q = captura.quadrosRecebidos.load(ordering: .relaxed)
    print(String(format: "formato anunciado: %.0f Hz, %d canais, %@ · blocos reais: %d buffer(s) de %d canal(is)",
                 f.mSampleRate, f.mChannelsPerFrame,
                 f.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "separados" : "intercalados", l / 100, l % 100))
    print(String(format: "recebidos %.1f s de áudio em %.1f s de relógio", Double(q) / f.mSampleRate, Date().timeIntervalSince(comeco)))
    let inicio = captura.trilha.inicioReal
    captura.parar()
    fila.sync { timer.cancel(); captura.trilha.fechar() }
    if let inicio { print("primeira amostra em \(ISO8601DateFormatter().string(from: inicio)) (\(inicio.timeIntervalSince1970))") }
    print("gravado em \(destino.path)")
    exit(0)
}
for s in [SIGINT, SIGTERM] {
    signal(s, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: s, queue: .main)
    src.setEventHandler { encerrar() }
    src.resume()
    objc_setAssociatedObject(timer, "\(s)", src, .OBJC_ASSOCIATION_RETAIN)
}
if a.count > 2, let seg = Double(a[2]) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seg) { encerrar() }
}
print("gravando… (Ctrl+C para parar)")
dispatchMain()
