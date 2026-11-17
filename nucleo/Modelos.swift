import Foundation

/// Onde ficam os modelos de transcrição e de voz.
enum Modelos {
    static let nomeWhisper = "ggml-large-v3-turbo.bin"
    static let urlWhisper = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!
    /// Impressão de voz: ERes2NetV2 do 3D-Speaker (Apache-2.0), exportado pelo sherpa-onnx.
    static let nomeVoz = "eres2netv2_3dspeaker.onnx"
    /// Separação de quem fala quando: segmentação 3.0 do pyannote (MIT), exportada pelo sherpa-onnx.
    static let nomeSegmentacao = "pyannote_segmentation_3.onnx"
    /// Classificador de sons (fala, música, canto…): CED mini (Apache-2.0), exportado pelo sherpa-onnx.
    static let nomeSons = "ced_mini_sons.int8.onnx"
    static let nomeRotulosDeSons = "ced_mini_sons.csv"

    /// ~/Library/Application Support/Frevo: o Whisper, a memória de vozes e as sessões com vozes sem nome.
    static var pastaApp: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Frevo")
    }

    /// O Whisper (1,6 GB) não vai dentro do app: fica na pasta do app, baixado uma vez.
    static var destinoWhisper: URL { pastaApp.appendingPathComponent("modelos/\(nomeWhisper)") }

    static func whisper() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidatos = [destinoWhisper, home.appendingPathComponent(".cache/digestor/models/\(nomeWhisper)")]
        return candidatos.first { FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    /// Os modelos de voz e de separação vão dentro do app (as ferramentas de teste acham na pasta do projeto).
    static func voz() -> String { embutido(nomeVoz) }
    static func segmentacao() -> String { embutido(nomeSegmentacao) }
    static func sons() -> String { embutido(nomeSons) }
    static func rotulosDeSons() -> String { embutido(nomeRotulosDeSons) }

    private static func embutido(_ nome: String) -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let candidatos = [
            exe.appendingPathComponent("../Resources/\(nome)"),
            exe.appendingPathComponent("recursos/\(nome)"),
            exe.appendingPathComponent("../third_party/modelos/\(nome)"),
        ]
        return (candidatos.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidatos[0]).standardized.path
    }

    static var livroDeVozes: URL { pastaApp.appendingPathComponent("vozes.json") }
}
