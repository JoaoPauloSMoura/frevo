import Foundation

/// Diz onde há fala no som da chamada, para música, sinos de entrada e outros sons não virarem texto nem "pessoa".
/// Usa o CED mini (Apache-2.0), que classifica 527 tipos de som do AudioSet, pelo sherpa-onnx.
///
/// Por que é preciso: o Chrome mistura todas as abas num processo de áudio só. Uma música no YouTube durante
/// um Meet chega junto com a voz das pessoas, e o Whisper inventa letra em cima de música e de sinos
/// ("A CIDADE NO BRASIL" saiu do sino de entrada do Meet).
///
/// A regra guarda a fala em vez de caçar música: um segundo só sai se NENHUMA janela de 3 s que o cobre tem sinal
/// de fala (ou se o canto domina a fala). Medido nas suas reuniões: 0% da fala perdida numa reunião normal,
/// 100% de música pura retirada, e 1% retirado de fala com música por baixo.
final class DetectorDeFala {
    private let tagger: OpaquePointer
    private let textos: [UnsafeMutablePointer<CChar>]
    private let indiceFala: Int32
    private let indiceCanto: Int32

    static var limiarFala: Float = 0.2
    static var limiarCanto: Float = 0.3

    struct Falha: Error, CustomStringConvertible { let description: String }

    init(modelo: String, rotulos: String) throws {
        for m in [modelo, rotulos] where !FileManager.default.fileExists(atPath: m) {
            throw Falha(description: "modelo de sons não encontrado em \(m)")
        }
        let m = strdup(modelo)!, r = strdup(rotulos)!, cpu = strdup("cpu")!
        textos = [m, r, cpu]
        var c = SherpaOnnxAudioTaggingConfig()
        c.model.ced = UnsafePointer(m)
        c.model.num_threads = 4
        c.model.provider = UnsafePointer(cpu)
        c.labels = UnsafePointer(r)
        c.top_k = 527
        guard let t = SherpaOnnxCreateAudioTagging(&c) else {
            textos.forEach { free($0) }
            throw Falha(description: "não consegui abrir o modelo de sons")
        }
        tagger = t
        // no AudioSet: 0 = "Speech", 27 = "Singing"
        indiceFala = 0
        indiceCanto = 27
    }

    deinit {
        SherpaOnnxDestroyAudioTagging(tagger)
        textos.forEach { free($0) }
    }

    /// Para cada segundo de `x` (16 kHz): true se não tem fala e pode sair da transcrição.
    func semFala(_ x: [Float], progresso: (Double) -> Void = { _ in }) -> [Bool] {
        let sr = 16000
        let n = x.count / sr
        guard n > 0 else { return [] }
        var fala = [Bool](repeating: false, count: n)
        var som = [Bool](repeating: false, count: n)
        let piso: Float = 0.001 // -60 dBFS: abaixo disso é silêncio, nem passa pelo modelo
        for i in 0..<max(1, n - 2) {
            let a = i * sr, z = min(x.count, (i + 3) * sr)
            var energia: Float = 0
            for k in a..<z { energia += x[k] * x[k] }
            guard (energia / Float(z - a)).squareRoot() >= piso else { continue }
            let (pFala, pCanto) = probabilidades(x[a..<z])
            let temFala = pFala >= Self.limiarFala && !(pCanto >= Self.limiarCanto && pCanto > pFala)
            for k in i..<min(n, i + 3) {
                som[k] = true
                if temFala { fala[k] = true }
            }
            if i % 300 == 0 { progresso(Double(i) / Double(n)) }
        }
        return (0..<n).map { som[$0] && !fala[$0] }
    }

    private func probabilidades(_ trecho: ArraySlice<Float>) -> (fala: Float, canto: Float) {
        guard let s = SherpaOnnxAudioTaggingCreateOfflineStream(tagger) else { return (1, 0) } // na dúvida, é fala
        defer { SherpaOnnxDestroyOfflineStream(s) }
        Array(trecho).withUnsafeBufferPointer { SherpaOnnxAcceptWaveformOffline(s, 16000, $0.baseAddress, Int32($0.count)) }
        guard let r = SherpaOnnxAudioTaggingCompute(tagger, s, 527) else { return (1, 0) }
        defer { SherpaOnnxAudioTaggingFreeResults(r) }
        var fala: Float = 0, canto: Float = 0
        var i = 0
        while let e = r[i] {
            if e.pointee.index == indiceFala { fala = e.pointee.prob }
            if e.pointee.index == indiceCanto { canto = e.pointee.prob }
            i += 1
        }
        return (fala, canto)
    }
}
