#if canImport(Accelerate)
import Accelerate // no Windows, as mesmas contas estão em Contas.swift
#endif
import Foundation

/// Impressão de voz pelo sherpa-onnx (Apache-2.0), com o ERes2NetV2 do 3D-Speaker (Apache-2.0).
/// Entra áudio de 16 kHz, sai um vetor de norma 1: vozes parecidas dão vetores parecidos.
///
/// Medido com as suas reuniões (sua voz × a dos outros, janelas de 3 s): erro igual de 2,8%, contra 10,8% do
/// CAM++ que usávamos antes. Os vetores dos dois modelos não se comparam (nem têm o mesmo tamanho).
final class ImpressaoDeVoz {
    private let ex: OpaquePointer
    private let textos: [UnsafeMutablePointer<CChar>]
    let dimensao: Int

    struct Falha: Error, CustomStringConvertible { let description: String }

    init(modelo: String) throws {
        guard FileManager.default.fileExists(atPath: modelo) else { throw Falha(description: "modelo de voz não encontrado em \(modelo)") }
        let m = strdup(modelo)!, cpu = strdup("cpu")!
        textos = [m, cpu]
        var c = SherpaOnnxSpeakerEmbeddingExtractorConfig()
        c.model = UnsafePointer(m)
        c.num_threads = 4
        c.provider = UnsafePointer(cpu)
        guard let p = SherpaOnnxCreateSpeakerEmbeddingExtractor(&c) else {
            textos.forEach { free($0) }
            throw Falha(description: "não consegui abrir o modelo de voz")
        }
        ex = p
        dimensao = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(p))
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(ex)
        textos.forEach { free($0) }
    }

    /// Precisa de pelo menos ~0,5 s de fala (16 kHz). Devolve nil se for curto demais.
    func vetor(_ amostras16k: ArraySlice<Float>) throws -> [Float]? {
        guard amostras16k.count >= 8000, let fluxo = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(ex) else { return nil }
        defer { SherpaOnnxDestroyOnlineStream(fluxo) }
        Array(amostras16k).withUnsafeBufferPointer { SherpaOnnxOnlineStreamAcceptWaveform(fluxo, 16000, $0.baseAddress, Int32($0.count)) }
        SherpaOnnxOnlineStreamInputFinished(fluxo)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(ex, fluxo) != 0,
              let v = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(ex, fluxo) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(v) }
        return Vozes.normalizar(Array(UnsafeBufferPointer(start: v, count: dimensao)))
    }
}

/// Contas com impressões de voz.
enum Vozes {
    static func normalizar(_ v: [Float]) -> [Float] {
        var n: Float = 0
        vDSP_svesq(v, 1, &n, vDSP_Length(v.count))
        let k = 1 / max(sqrt(n), 1e-9)
        return v.map { $0 * k }
    }

    /// Semelhança de 0 (vozes diferentes) a 1 (mesma voz), para vetores com norma 1.
    static func semelhanca(_ a: [Float], _ b: [Float]) -> Float {
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
        return d
    }

    static func media(_ vs: [[Float]]) -> [Float] {
        guard let primeiro = vs.first else { return [] }
        var soma = [Float](repeating: 0, count: primeiro.count)
        for v in vs { vDSP_vadd(soma, 1, v, 1, &soma, 1, vDSP_Length(soma.count)) }
        return normalizar(soma)
    }

    /// Agrupa vetores por semelhança média entre grupos (agrupamento hierárquico, "average linkage"),
    /// parando quando os grupos mais parecidos ficam abaixo do limiar. Devolve o grupo de cada vetor,
    /// numerado na ordem em que aparece. Rápido o bastante para os ~1.200 trechos de uma reunião de 1 hora.
    static func agrupar(_ vs: [[Float]], limiar: Float) -> [Int] {
        let n = vs.count
        guard n > 1 else { return Array(repeating: 0, count: n) }
        let d = vs[0].count
        // matriz de semelhança n × n = V · Vᵀ
        var v = [Float](repeating: 0, count: n * d)
        for i in 0..<n { for k in 0..<d { v[i * d + k] = vs[i][k] } }
        var vt = [Float](repeating: 0, count: n * d)
        vDSP_mtrans(v, 1, &vt, 1, vDSP_Length(d), vDSP_Length(n))
        var s = [Float](repeating: 0, count: n * n)
        vDSP_mmul(v, 1, vt, 1, &s, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(d))

        var tamanho = [Int](repeating: 1, count: n)
        var vivo = [Bool](repeating: true, count: n)
        var dono = Array(0..<n) // grupo de cada vetor (índice do representante)
        var melhor = [Int](repeating: -1, count: n)
        func recalcular(_ i: Int) {
            var b = -1
            var bv = -Float.infinity
            for j in 0..<n where j != i && vivo[j] && s[i * n + j] > bv {
                bv = s[i * n + j]
                b = j
            }
            melhor[i] = b
        }
        for i in 0..<n { recalcular(i) }

        while true {
            var a = -1
            var av = -Float.infinity
            for i in 0..<n where vivo[i] && melhor[i] >= 0 && s[i * n + melhor[i]] > av {
                av = s[i * n + melhor[i]]
                a = i
            }
            guard a >= 0, av >= limiar else { break }
            let b = melhor[a]
            // média ponderada das semelhanças do grupo novo com os outros
            for k in 0..<n where vivo[k] && k != a && k != b {
                let novo = (Float(tamanho[a]) * s[a * n + k] + Float(tamanho[b]) * s[b * n + k]) / Float(tamanho[a] + tamanho[b])
                s[a * n + k] = novo
                s[k * n + a] = novo
            }
            tamanho[a] += tamanho[b]
            vivo[b] = false
            for i in 0..<n where dono[i] == b { dono[i] = a }
            recalcular(a)
            for k in 0..<n where vivo[k] && k != a {
                if melhor[k] == a || melhor[k] == b {
                    recalcular(k)
                } else if melhor[k] < 0 || s[k * n + a] > s[k * n + melhor[k]] {
                    melhor[k] = a
                }
            }
        }
        var numero: [Int: Int] = [:]
        return dono.map { r in
            if let g = numero[r] { return g }
            numero[r] = numero.count
            return numero[r]!
        }
    }
}

/// As vozes que o app já conhece, guardadas só neste Mac.
final class LivroDeVozes {
    struct Voz: Codable {
        var nome: String
        var vetores: [[Float]] // um por reunião em que a pessoa foi reconhecida ou nomeada (até 20)
        var atualizado: Date
    }

    let url: URL
    private(set) var vozes: [Voz] = []

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode([Voz].self, from: d) { vozes = v }
    }

    func salvar() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(vozes).write(to: url, options: .atomic)
    }

    /// Quem é a dona desta voz: a mais parecida precisa passar do limiar e ganhar da segunda com folga,
    /// para não confundir duas pessoas de voz parecida.
    func reconhecer(_ v: [Float], limiar: Float, folga: Float = 0.08) -> (nome: String, semelhanca: Float)? {
        // vetores de outro modelo (o CAM++ antigo, de outro tamanho) não se comparam: ficam de fora
        let ranking = vozes.map { voz in (voz.nome, voz.vetores.filter { $0.count == v.count }.map { Vozes.semelhanca(v, $0) }.max() ?? 0) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        guard let primeira = ranking.first, primeira.1 >= limiar else { return nil }
        if ranking.count > 1 && primeira.1 - ranking[1].1 < folga { return nil }
        return primeira
    }

    func aprender(nome: String, vetor: [Float]) {
        if let i = vozes.firstIndex(where: { $0.nome.caseInsensitiveCompare(nome) == .orderedSame }) {
            vozes[i].vetores.append(vetor)
            // os do modelo antigo saem primeiro quando passa do limite
            while vozes[i].vetores.count > 20 {
                let antigo = vozes[i].vetores.firstIndex { $0.count != vetor.count } ?? 0
                vozes[i].vetores.remove(at: antigo)
            }
            vozes[i].atualizado = Date()
        } else {
            vozes.append(Voz(nome: nome, vetores: [vetor], atualizado: Date()))
        }
    }
}
