import Foundation

/// Separa quem fala quando na trilha dos outros: o pyannote (segmentação 3.0, MIT) marca as trocas de voz a cada
/// ~17 ms e as falas sobrepostas; uma impressão de voz e um agrupamento juntam os trechos da mesma pessoa.
/// Roda pelo sherpa-onnx (Apache-2.0). Os falantes saem numerados (0, 1, 2…), sem nome.
final class SeparadorDeVozes {
    struct Trecho {
        var inicio: Double
        var fim: Double
        var falante: Int
    }

    struct Falha: Error, CustomStringConvertible { let description: String }

    private let sd: OpaquePointer
    private var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
    private let textos: [UnsafeMutablePointer<CChar>] // caminhos em C, vivos enquanto o separador existir

    /// `limiar`: distância (cosseno) para dois trechos serem a mesma pessoa; maior junta mais.
    /// `passo`: quanto a janela de 10 s do pyannote anda, em fração dela (0,1 = sobreposição de 10x, mais lento).
    init(segmentacao: String, impressao: String, limiar: Float, passo: Float = 0.5) throws {
        for m in [segmentacao, impressao] where !FileManager.default.fileExists(atPath: m) {
            throw Falha(description: "modelo não encontrado em \(m)")
        }
        let seg = strdup(segmentacao)!, imp = strdup(impressao)!, cpu = strdup("cpu")!
        textos = [seg, imp, cpu]
        config.segmentation.pyannote.model = UnsafePointer(seg)
        config.segmentation.pyannote.window_shift_ratio = passo
        config.segmentation.num_threads = 4
        config.segmentation.provider = UnsafePointer(cpu)
        config.embedding.model = UnsafePointer(imp)
        config.embedding.num_threads = 4
        config.embedding.provider = UnsafePointer(cpu)
        config.clustering.num_clusters = -1
        config.clustering.threshold = limiar
        config.min_duration_on = 0.3 // trechos de fala mais curtos que isto são descartados
        config.min_duration_off = 0.5 // pausas mais curtas que isto não separam a fala da mesma pessoa
        guard let p = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else {
            textos.forEach { free($0) }
            throw Falha(description: "não consegui abrir o separador de vozes")
        }
        sd = p
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(sd)
        textos.forEach { free($0) }
    }

    /// `x`: áudio de 16 kHz. `falantes`: quantas pessoas, se souber (senão o limiar decide).
    func separar(_ x: [Float], falantes: Int? = nil, progresso: (Double) -> Void = { _ in }) -> [Trecho] {
        guard x.count >= 16000 else { return [] }
        config.clustering.num_clusters = Int32(falantes ?? -1)
        SherpaOnnxOfflineSpeakerDiarizationSetConfig(sd, &config)
        // o progresso só é chamado durante o processamento, que termina antes desta função voltar
        let r = withoutActuallyEscaping(progresso) { p in
            let caixa = Unmanaged.passRetained(Progresso(p))
            defer { caixa.release() }
            return x.withUnsafeBufferPointer { b in
                SherpaOnnxOfflineSpeakerDiarizationProcessWithCallback(sd, b.baseAddress, Int32(b.count), { feito, total, arg in
                    if let arg, total > 0 { Unmanaged<Progresso>.fromOpaque(arg).takeUnretainedValue().f(Double(feito) / Double(total)) }
                    return 0
                }, caixa.toOpaque())
            }
        }
        guard let r else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(r) }
        let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(r))
        guard n > 0, let segs = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(r) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segs) }
        return (0..<n).map { Trecho(inicio: Double(segs[$0].start), fim: Double(segs[$0].end), falante: Int(segs[$0].speaker)) }
    }

    private final class Progresso {
        let f: (Double) -> Void
        init(_ f: @escaping (Double) -> Void) { self.f = f }
    }
}
