import AVFoundation

// motor-teste: passa um arquivo pelo motor do app (a mesma libDF, quadro a quadro, como ao vivo)
// e mede o tempo de cada quadro. Serve para conferir que o motor do app dá o mesmo resultado
// do deep-filter usado na comparação, e quanto ele gasta.
// Uso: motor-teste <entrada 48 kHz> <saida.wav> [limite dB]

let a = CommandLine.arguments
guard a.count >= 3 else {
    print("Uso: motor-teste <entrada 48 kHz mono> <saida.wav> [limite dB]")
    exit(1)
}

do {
    let arquivo = try AVAudioFile(forReading: URL(fileURLWithPath: a[1]))
    let fmt = arquivo.processingFormat
    guard fmt.sampleRate == 48000 else {
        print("A entrada precisa estar em 48 kHz (está em \(Int(fmt.sampleRate)) Hz).")
        exit(1)
    }
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(arquivo.length))!
    try arquivo.read(into: buf)
    let total = Int(buf.frameLength)
    let x = buf.floatChannelData![0] // primeiro canal

    let motor = try Motor(modelo: Motor.caminhoDoModelo(), limiteDb: Float(a.count > 3 ? a[3] : "100") ?? 100)
    let q = motor.quadro
    // atraso do DeepFilterNet3: janela da STFT (960 - 480) + 2 quadros de lookahead = 1440 amostras (30 ms)
    let atraso = 1440
    let n = (total + atraso + q - 1) / q * q
    let ent = UnsafeMutablePointer<Float>.allocate(capacity: n)
    ent.initialize(repeating: 0, count: n)
    ent.update(from: x, count: total)
    let sai = UnsafeMutablePointer<Float>.allocate(capacity: n)

    var tempos: [Double] = []
    for i in stride(from: 0, to: n, by: q) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        motor.processar(ent + i, sai + i)
        tempos.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }

    let saidaFmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    let out = AVAudioPCMBuffer(pcmFormat: saidaFmt, frameCapacity: AVAudioFrameCount(total))!
    out.frameLength = AVAudioFrameCount(total)
    out.floatChannelData![0].update(from: sai + atraso, count: total) // alinha com o original
    let destino = try AVAudioFile(forWriting: URL(fileURLWithPath: a[2]), settings: saidaFmt.settings)
    try destino.write(from: out)

    let ordenados = tempos.sorted()
    let soma = tempos.reduce(0, +)
    let duracao = Double(total) / 48000
    print(String(format: "quadros=%d media_ms=%.3f p99_ms=%.3f pior_ms=%.3f cpu_pct=%.2f",
                 tempos.count, soma / Double(tempos.count),
                 ordenados[Int(Double(ordenados.count - 1) * 0.99)], ordenados.last!,
                 soma / 1000 / duracao * 100))
} catch {
    print("Erro: \(error)")
    exit(1)
}
