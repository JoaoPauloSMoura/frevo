import AVFoundation
import Foundation

// eco-teste: mede o cancelador de eco sem precisar de uma chamada.
// Monta o que o microfone ouviria com o som saindo do alto-falante: a voz do "professor" (outra pessoa)
// passa por um atraso, um eco de sala e uma leve distorção de alto-falante pequeno, e se mistura com a
// sua voz. Depois compara o microfone sem cancelamento com o que o cancelador entrega (e com o filtro de
// ruído depois dele, como no app).
//
// Uso: eco-teste sua-voz.wav voz-do-outro.wav [pasta para salvar os .wav]
// Trechos: 0–12 s só o outro falando (só eco no microfone) · 12–24 s só você · 24–36 s os dois juntos.

let taxa = 48000
let q = taxa / 100
let a = CommandLine.arguments
guard a.count >= 3 else {
    print("uso: eco-teste sua-voz.wav voz-do-outro.wav [pasta]")
    exit(1)
}

func ler48k(_ caminho: String) -> [Float] {
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: caminho))
    precondition(f.processingFormat.sampleRate == Double(taxa) && f.processingFormat.channelCount == 1, "precisa ser mono 48 kHz")
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try! f.read(into: b)
    return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
}

func salvar(_ x: [Float], _ nome: String) {
    guard a.count > 3 else { return }
    let fmt = AVAudioFormat(standardFormatWithSampleRate: Double(taxa), channels: 1)!
    let f = try! AVAudioFile(forWriting: URL(fileURLWithPath: a[3]).appendingPathComponent(nome), settings: fmt.settings)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
    b.frameLength = AVAudioFrameCount(x.count)
    x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
    try! f.write(from: b)
}

func rms(_ x: ArraySlice<Float>) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(x.count, 1))) }
func db(_ v: Float) -> Float { 20 * log10(max(v, 1e-9)) }
func normalizar(_ x: [Float], para alvo: Float) -> [Float] { let r = rms(x[...]); return x.map { $0 * alvo / max(r, 1e-9) } }

// as duas vozes, com 12 s cada, no mesmo volume (−26 dBFS, fala normal no microfone)
let trecho = 12 * taxa
var voce = normalizar(Array(ler48k(a[1]).prefix(trecho)), para: 0.05)
var outro = normalizar(Array(ler48k(a[2]).prefix(trecho)), para: 0.05)
voce += [Float](repeating: 0, count: trecho - voce.count)
outro += [Float](repeating: 0, count: trecho - outro.count)
let total = 3 * trecho
let silencio = [Float](repeating: 0, count: trecho)
let perto = silencio + voce + voce // você: calado, falando, falando
let longe = outro + silencio + outro // o outro: falando, calado, falando
// a referência é o que o Mac toca: a voz do outro, como chega da chamada

// caminho do eco: 45 ms até o microfone, som direto + reflexões da sala (cauda de ~250 ms), alto-falante que distorce
// um pouco, e os relógios do alto-falante e do microfone 80 ppm diferentes
var gerador = SystemRandomNumberGenerator()
let cauda = Int(0.25 * Double(taxa))
var sala = [Float](repeating: 0, count: cauda)
sala[0] = 0.6
for i in 1..<cauda {
    let env = exp(-6.9 * Float(i) / Float(cauda)) // −60 dB no fim
    sala[i] = 0.12 * env * Float.random(in: -1...1, using: &gerador)
}
let atraso = Int(0.045 * Double(taxa))
let deriva = 1.00008
var eco = [Float](repeating: 0, count: total)
var falado = [Float](repeating: 0, count: total)
for i in 0..<total { falado[i] = tanh(longe[i] * 6) / 6 } // alto-falante pequeno no limite
// convolução esparsa: o direto + 400 reflexões sorteadas da cauda (rápido o bastante e realista para o teste)
let picos = [0] + (0..<400).map { _ in Int.random(in: 1..<cauda, using: &gerador) }
for i in 0..<total {
    let t = Double(i) / deriva - Double(atraso)
    let j = Int(t)
    guard j >= 0 else { continue }
    var s: Float = 0
    for p in picos where j - p >= 0 && j - p < total { s += sala[p] * falado[j - p] }
    eco[i] = s
}
// volume do eco e do ruído da sala (dBFS); padrão: eco só 3 dB abaixo da sua voz (notebook no colo, volume alto)
let ambiente = ProcessInfo.processInfo.environment
let ecoDb = Float(ambiente["ECO_DB"] ?? "") ?? -29
let ruidoDb = Float(ambiente["RUIDO_DB"] ?? "") ?? -71
eco = normalizar(eco, para: pow(10, ecoDb / 20))
let ruido = (0..<total).map { _ in Float.random(in: -1...1, using: &gerador) * pow(10, ruidoDb / 20) * 1.73 }
let mic = (0..<total).map { perto[$0] + eco[$0] + ruido[$0] }

// cancelador
guard let e = eco_criar(Int32(taxa)) else { fatalError("não criou o cancelador") }
var saida = [Float](repeating: 0, count: total)
var medidas: [EcoMedidas] = []
let inicio = Date()
var i = 0
while i + q <= total {
    longe.withUnsafeBufferPointer { eco_referencia(e, $0.baseAddress! + i, Int32(taxa)) }
    mic.withUnsafeBufferPointer { m in saida.withUnsafeMutableBufferPointer { s in
        _ = eco_limpar(e, m.baseAddress! + i, s.baseAddress! + i, 40)
    } }
    if (i / q) % 100 == 99 { medidas.append(eco_medidas(e)) }
    i += q
}
let segundos = Date().timeIntervalSince(inicio)
eco_destruir(e)

// filtro de ruído depois, como no app
let motor = try! Motor(modelo: Motor.caminhoDoModelo())
var final = [Float](repeating: 0, count: total)
var semEcoDepoisDoFiltro = [Float](repeating: 0, count: total)
for (origem, destino) in [(saida, 0), (mic, 1)] {
    var j = 0
    var ent = [Float](repeating: 0, count: motor.quadro), sai = [Float](repeating: 0, count: motor.quadro)
    while j + motor.quadro <= total {
        for k in 0..<motor.quadro { ent[k] = origem[j + k] }
        _ = motor.processar(&ent, &sai)
        for k in 0..<motor.quadro {
            if destino == 0 { final[j + k] = sai[k] } else { semEcoDepoisDoFiltro[j + k] = sai[k] }
        }
        j += motor.quadro
    }
}

// medidas por trecho (descontando os 3 primeiros segundos, quando o cancelador ainda está aprendendo)
func trechoDe(_ x: [Float], _ n: Int, pular: Int = 0) -> ArraySlice<Float> { x[(n * trecho + pular * taxa)..<((n + 1) * trecho)] }
let ecoSo = rms(trechoDe(eco, 0, pular: 3))
print(String(format: "cancelador: %.2f ms por quadro de 10 ms (%.1f%% de um núcleo)", segundos * 1000 / Double(total / q),
             segundos / (Double(total) / Double(taxa)) * 100))
print("\nTrecho 1, só o outro falando (o que sobra é eco; quanto mais baixo, melhor):")
print(String(format: "  eco no microfone:            %6.1f dBFS", db(ecoSo)))
print(String(format: "  sem cancelador, após filtro: %6.1f dBFS", db(rms(trechoDe(semEcoDepoisDoFiltro, 0, pular: 3)))))
print(String(format: "  com cancelador:              %6.1f dBFS  (%.0f dB a menos)", db(rms(trechoDe(saida, 0, pular: 3))),
             db(ecoSo) - db(rms(trechoDe(saida, 0, pular: 3)))))
print(String(format: "  com cancelador e filtro:     %6.1f dBFS  (%.0f dB a menos)", db(rms(trechoDe(final, 0, pular: 3))),
             db(ecoSo) - db(rms(trechoDe(final, 0, pular: 3)))))
print("\nTrecho 2, só você (sua voz tem que passar inteira):")
print(String(format: "  sua voz: %.1f dBFS · depois do cancelador: %.1f dBFS", db(rms(trechoDe(perto, 1))), db(rms(trechoDe(saida, 1)))))
print("\nTrecho 3, os dois ao mesmo tempo:")
// eco que sobrou: a parte da saída que acompanha o eco (as duas vozes não têm nada a ver uma com a outra,
// então a projeção da saída no eco mede só o eco que passou)
func ecoQueSobrou(_ x: ArraySlice<Float>) -> Float {
    let ecoT = trechoDe(eco, 2)
    let g = zip(x, ecoT).reduce(0) { $0 + $1.0 * $1.1 } / max(ecoT.reduce(0) { $0 + $1 * $1 }, 1e-12)
    return abs(g) * rms(ecoT)
}
print(String(format: "  sua voz: %.1f dBFS · saída do cancelador: %.1f dBFS", db(rms(trechoDe(perto, 2))), db(rms(trechoDe(saida, 2)))))
print(String(format: "  eco que passou: sem cancelador %.1f dBFS · com cancelador %.1f dBFS · com cancelador e filtro %.1f dBFS",
             db(ecoQueSobrou(trechoDe(mic, 2))), db(ecoQueSobrou(trechoDe(saida, 2))), db(ecoQueSobrou(trechoDe(final, 2)))))
if let m = medidas.last {
    print(String(format: "\nO próprio cancelador: eco reduzido %.1f dB, atraso achado %d ms (real: %d ms)", m.erle_db, m.atraso_ms, 45))
}
salvar(mic, "1-microfone.wav")
salvar(semEcoDepoisDoFiltro, "2-sem-cancelador.wav")
salvar(final, "3-com-cancelador.wav")
