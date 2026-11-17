import Foundation

/// O DeepFilterNet3 rodando quadro a quadro (10 ms em 48 kHz).
final class Motor {
    private let estado: OpaquePointer
    let quadro: Int

    enum Erro: Error, CustomStringConvertible {
        case modeloNaoEncontrado(String)
        case falhaAoCriar
        var description: String {
            switch self {
            case .modeloNaoEncontrado(let p): return "modelo do DeepFilterNet3 não encontrado em \(p)"
            case .falhaAoCriar: return "não consegui iniciar o DeepFilterNet3"
            }
        }
    }

    init(modelo: String, limiteDb: Float = 100) throws {
        // df_create aborta o processo se o arquivo não abrir, então conferimos antes
        guard FileManager.default.fileExists(atPath: modelo) else { throw Erro.modeloNaoEncontrado(modelo) }
        guard let st = df_create(modelo, limiteDb, nil) else { throw Erro.falhaAoCriar }
        estado = st
        quadro = Int(df_get_frame_length(st))
    }

    deinit { df_free(estado) }

    /// Limpa um quadro. `entrada` e `saida` têm `quadro` amostras. Devolve o SNR local (dB).
    @discardableResult
    func processar(_ entrada: UnsafeMutablePointer<Float>, _ saida: UnsafeMutablePointer<Float>) -> Float {
        df_process_frame(estado, entrada, saida)
    }

    func definirLimite(_ db: Float) { df_set_atten_lim(estado, db) }

    /// Procura o modelo: variável FREVO_MODELO, pasta recursos/ ao lado do executável, ou o do código-fonte.
    static func caminhoDoModelo() -> String {
        if let p = ProcessInfo.processInfo.environment["FREVO_MODELO"] { return p }
        let nome = "DeepFilterNet3_onnx.tar.gz"
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidatos = [
            exe.appendingPathComponent("recursos/\(nome)"),
            exe.appendingPathComponent("../Resources/\(nome)"),
            exe.appendingPathComponent("../third_party/DeepFilterNet/models/\(nome)"),
        ]
        return (candidatos.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidatos[0]).standardized.path
    }
}
