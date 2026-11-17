import Foundation

/// Lê um WAV (PCM de 16, 24 ou 32 bits, ou float de 32 bits) e devolve mono 16 kHz, sem depender do sistema.
/// No Mac o `Audio16k` usa o AVFoundation; isto é para onde ele não existe (Windows).
enum Wav {
    struct Falha: Error, CustomStringConvertible { let description: String }

    static func ler16k(_ url: URL) throws -> [Float] {
        let d = try Data(contentsOf: url)
        func u16(_ i: Int) -> Int { Int(d[d.startIndex + i]) | Int(d[d.startIndex + i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        func texto(_ i: Int) -> String { String(decoding: d[(d.startIndex + i)..<(d.startIndex + i + 4)], as: UTF8.self) }
        guard d.count >= 12, texto(0) == "RIFF", texto(8) == "WAVE" else { throw Falha(description: "\(url.lastPathComponent) não é WAV") }

        var formato = 0, canais = 0, taxa = 0, bits = 0
        var dados: Range<Int>?
        var i = 12
        while i + 8 <= d.count {
            let id = texto(i), tam = u32(i + 4), ini = i + 8
            if id == "fmt " && tam >= 16 {
                formato = u16(ini)
                canais = u16(ini + 2)
                taxa = u32(ini + 4)
                bits = u16(ini + 14)
                if formato == 0xFFFE && tam >= 26 { formato = u16(ini + 24) } // WAVE_FORMAT_EXTENSIBLE: o subformato
            } else if id == "data" {
                dados = ini..<min(d.count, ini + tam)
                break
            }
            i = ini + tam + (tam & 1)
        }
        guard let dados, canais > 0, taxa > 0 else { throw Falha(description: "\(url.lastPathComponent): WAV sem formato ou sem dados") }

        let bytes = bits / 8
        let quadros = dados.count / (bytes * canais)
        var mono = [Float](repeating: 0, count: quadros)
        try d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let base = p.baseAddress!.advanced(by: dados.lowerBound)
            func amostra(_ k: Int) throws -> Float {
                let q = base.advanced(by: k * bytes)
                switch (formato, bits) {
                case (1, 16): return Float(q.loadUnaligned(as: Int16.self)) / 32768
                case (1, 24):
                    let b = q.assumingMemoryBound(to: UInt8.self)
                    let v = Int32(bitPattern: UInt32(b[0]) << 8 | UInt32(b[1]) << 16 | UInt32(b[2]) << 24) >> 8
                    return Float(v) / 8_388_608
                case (1, 32): return Float(q.loadUnaligned(as: Int32.self)) / 2_147_483_648
                case (3, 32): return q.loadUnaligned(as: Float.self)
                default: throw Falha(description: "\(url.lastPathComponent): WAV de formato \(formato) com \(bits) bits não suportado")
                }
            }
            for f in 0..<quadros {
                var s: Float = 0
                for c in 0..<canais { s += try amostra(f * canais + c) }
                mono[f] = s / Float(canais)
            }
        }
        return taxa == 16000 ? mono : reamostrar(mono, de: taxa, para: 16000)
    }

    /// Troca a taxa de amostragem por interpolação com sinc janelado (filtro passa-baixa no menor dos dois Nyquist).
    static func reamostrar(_ x: [Float], de origem: Int, para destino: Int) -> [Float] {
        guard !x.isEmpty, origem != destino else { return x }
        let razao = Double(destino) / Double(origem)
        let corte = min(1, razao) // fração do Nyquist da origem
        let meia = 16 // amostras de cada lado, na escala da origem
        let largura = Double(meia) / corte
        let n = Int((Double(x.count) * razao).rounded())
        var y = [Float](repeating: 0, count: n)
        for j in 0..<n {
            let t = Double(j) / razao // posição na origem
            let a = max(0, Int((t - largura).rounded(.up))), b = min(x.count - 1, Int((t + largura).rounded(.down)))
            var s = 0.0, peso = 0.0
            if a <= b {
                for k in a...b {
                    let u = (Double(k) - t) * corte
                    let sinc = u == 0 ? 1 : sin(.pi * u) / (.pi * u)
                    let janela = 0.5 + 0.5 * cos(.pi * (Double(k) - t) / largura) // Hann
                    let w = sinc * janela
                    s += Double(x[k]) * w
                    peso += w
                }
            }
            y[j] = peso > 0 ? Float(s / peso) : 0
        }
        return y
    }
}
