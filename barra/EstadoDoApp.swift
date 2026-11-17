import AppKit
import SwiftUI

/// Tudo o que o painel e a ilha do notch mostram. O controlador atualiza; as telas só observam e chamam as ações.
@MainActor
final class EstadoDoApp: ObservableObject {
    struct Chamada: Equatable {
        var titulo: String
        var app: String?
        var transcrever: Bool
        var gravandoDesde: Date?
        /// Quando a chamada começou (o app abriu o microfone), gravando ou não.
        var desde: Date?
        var mudo: VigiaDoMudo.Estado
    }

    struct Reuniao: Identifiable, Equatable {
        let id: String
        let titulo: String
        let inicio: Date
        let fim: Date
        let link: URL?

        /// Começa em até 15 min ou já começou: hora de mostrar "Entrar".
        var naHora: Bool { inicio.timeIntervalSinceNow < 15 * 60 }
    }

    struct Arquivo: Identifiable, Equatable {
        var id: String { url.path }
        let titulo: String
        let data: Date
        let url: URL
    }

    struct Pendente: Identifiable, Equatable {
        let id: String
        let titulo: String
        let vozes: Int
    }

    struct Progresso: Equatable {
        let titulo: String
        let fracao: Double
    }

    struct Microfone: Identifiable, Equatable {
        var id: String { uid }
        let uid: String
        let nome: String
    }

    struct Atualizacao: Equatable {
        let versao: String
        let notas: String
    }

    @Published var problema: String?
    @Published var filtroLigado = true
    /// O filtro está rodando (algum app abriu o Frevo).
    @Published var limpando = false
    @Published var microfone: String?
    @Published var chamada: Chamada?
    @Published var transcrevendo: Progresso?
    @Published var baixandoModelo: Double?
    @Published var erroDeTranscricao: String?
    @Published var pendentes: [Pendente] = []
    @Published var recentes: [Arquivo] = []
    @Published var proximas: [Reuniao] = []
    @Published var cpu: Double = 0
    @Published var transcreverPadrao = false
    @Published var cancelarEco = true
    @Published var perguntarQuemFala = true
    /// "v0.3.0" (ou "versão de desenvolvimento").
    @Published var versao = ""
    /// Versão nova publicada no GitHub, ainda não instalada.
    @Published var atualizacao: Atualizacao?
    @Published var atualizando = false
    @Published var erroDeAtualizacao: String?
    /// Pergunta da ilha: quem está falando agora (nil: nenhuma).
    @Published var perguntaDeVoz: QuemFala.Pergunta?
    @Published var abrirAoIniciar = false
    @Published var microfones: [Microfone] = []
    @Published var micEscolhido: String?
    @Published var agendaLiberada = true
    @Published var acessibilidadeLiberada = true

    /// Volumes antes e depois do filtro (nil fora de chamada). A onda lê direto daqui, 30 vezes por segundo,
    /// sem passar por @Published (senão o painel inteiro seria redesenhado a cada quadro).
    var medidor: Medidor?

    /// Reunião que começa em até 10 min (ou começou há menos de 5), quando você ainda não está nela.
    var reuniaoEmBreve: Reuniao? {
        guard chamada == nil else { return nil }
        return proximas.first { r in
            let falta = r.inicio.timeIntervalSinceNow
            return falta <= 10 * 60 && falta > -5 * 60
        }
    }

    // ações (o controlador preenche)
    var alternarFiltro: () -> Void = {}
    var definirTranscricao: (Bool) -> Void = { _ in }
    var definirPadrao: (Bool) -> Void = { _ in }
    var definirEco: (Bool) -> Void = { _ in }
    var definirPerguntarQuemFala: (Bool) -> Void = { _ in }
    var atualizar: () -> Void = {}
    var procurarAtualizacao: () -> Void = {}
    var responderVoz: (Int, String) -> Void = { _, _ in }
    var recusarVoz: (Int) -> Void = { _ in }
    var dispensarVoz: (Int) -> Void = { _ in }
    var escolherMic: (String?) -> Void = { _ in }
    var definirAbrirAoIniciar: (Bool) -> Void = { _ in }
    var abrirTranscricoes: () -> Void = {}
    var nomear: (String) -> Void = { _ in }
    var permitirAgenda: () -> Void = {}
    var permitirAcessibilidade: () -> Void = {}
    var sair: () -> Void = {}

    /// Só publica se mudou: cada publicação redesenha as telas abertas.
    func definir<T: Equatable>(_ campo: ReferenceWritableKeyPath<EstadoDoApp, T>, _ valor: T) {
        if self[keyPath: campo] != valor { self[keyPath: campo] = valor }
    }

    static func tempo(desde d: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(d)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func falta(ate d: Date) -> String {
        let m = Int((d.timeIntervalSinceNow / 60).rounded(.up))
        if m <= 0 { return "agora" }
        if m < 60 { return "em \(m) min" }
        return "em \(m / 60)h\(String(format: "%02d", m % 60))"
    }
}
