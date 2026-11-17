import AppKit
import Foundation
import os
import UserNotifications

/// Cuida das chamadas gravadas: transcreve depois que a chamada acaba, salva o Markdown,
/// aprende vozes e guarda as sessões que ainda têm vozes sem nome.
@MainActor
final class Escrivao {
    private let fila = DispatchQueue(label: "io.github.joaopaulosmoura.frevo.transcricao", qos: .utility)
    private(set) var emAndamento: (titulo: String, progresso: Double)?
    private(set) var baixandoModelo: Double?
    private(set) var pendentes: [Sessao] = []
    private(set) var ultimoErro: String?
    var aoMudar: () -> Void = {}
    /// Chamado quando uma transcrição fica pronta (o app abre a janela de nomes se houver vozes novas).
    var aoTerminar: (Sessao) -> Void = { _ in }

    static var pastaSessoes: URL { Modelos.pastaApp.appendingPathComponent("sessoes") }
    static var pastaLigacoes: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Ligações")
    }

    init() {
        limparAntigas()
        recarregarPendentes()
    }

    // MARK: transcrever

    func transcrever(_ sessao: Sessao, atrasoOutros: Double) {
        emAndamento = (sessao.titulo, 0)
        aoMudar()
        guard let modelo = Modelos.whisper() else {
            baixarModelo { [weak self] in self?.transcrever(sessao, atrasoOutros: atrasoOutros) }
            return
        }
        fila.async { [weak self] in
            var s = sessao
            s.atrasoOutros = atrasoOutros
            let pasta = URL(fileURLWithPath: s.pasta)
            let urlOutros = pasta.appendingPathComponent("outros.wav")
            let voce = (try? Audio16k.ler(pasta.appendingPathComponent("voce.wav"))) ?? []
            let outros = (try? Audio16k.ler(urlOutros)) ?? []
            // Sem a voz de mais ninguém não houve conversa (áudio de WhatsApp, ditado, teste de microfone):
            // apaga tudo e não transcreve. Se a captura do som da chamada falhou (sem arquivo), segue só com a sua voz.
            if FileManager.default.fileExists(atPath: urlOutros.path) && !Trechos.houveFala(outros, minimo: 3) {
                try? FileManager.default.removeItem(at: pasta)
                Logger(subsystem: "io.github.joaopaulosmoura.frevo", category: "chamada")
                    .notice("descartada \(s.titulo, privacy: .public): ninguém mais falou")
                DispatchQueue.main.async {
                    self?.emAndamento = nil
                    self?.aoMudar()
                }
                return
            }
            do {
                let livro = LivroDeVozes(url: Modelos.livroDeVozes)
                let transcritor = try Transcritor.criar(whisper: modelo, livro: livro)
                let r = transcritor.transcrever(voce: voce, outros: outros, atrasoOutros: atrasoOutros, mudo: s.mudo ?? [],
                                                      convidados: s.convidados, marcas: s.marcas ?? []) { p in
                    DispatchQueue.main.async { self?.emAndamento?.progresso = p; self?.aoMudar() }
                }
                s.falas = r.falas
                s.vozes = r.vozes
                // reforça a memória só com reconhecimentos bem seguros
                for v in s.vozes where v.reconhecida && (v.semelhanca ?? 0) >= 0.88 && (v.janelas ?? 0) >= 4 { livro.aprender(nome: v.nome!, vetor: v.vetor) }
                // e com os nomes que você deu na ilha durante a chamada
                for v in s.vozes where v.aoVivo == true && !v.reconhecida && (v.janelas ?? 0) >= 4 { livro.aprender(nome: v.nome!, vetor: v.vetor) }
                try livro.salvar()
                try s.gravarMarkdown()
                try s.salvar()
                if s.semNome.isEmpty { s.apagarAudio() }
                DispatchQueue.main.async {
                    self?.emAndamento = nil
                    self?.ultimoErro = nil
                    self?.recarregarPendentes()
                    self?.avisar(s)
                    self?.aoTerminar(s)
                    self?.aoMudar()
                }
            } catch {
                DispatchQueue.main.async {
                    self?.emAndamento = nil
                    self?.ultimoErro = "Não consegui transcrever \(s.titulo): \(error)"
                    self?.aoMudar()
                }
            }
        }
    }

    // MARK: nomear vozes

    /// Salva os nomes dados na janela: atualiza a memória de vozes e reescreve o Markdown.
    func nomear(_ sessao: Sessao, titulo: String, nomes: [String: String]) {
        fila.async { [weak self] in
            var s = sessao
            let livro = LivroDeVozes(url: Modelos.livroDeVozes)
            for i in s.vozes.indices {
                guard let n = nomes[s.vozes[i].id]?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { continue }
                // só impressões com fala suficiente (4+ janelas de 3 s) entram na memória; fragmentos confundem
                if (n != s.vozes[i].nome || !s.vozes[i].reconhecida) && (s.vozes[i].janelas ?? 0) >= 4 { livro.aprender(nome: n, vetor: s.vozes[i].vetor) }
                s.vozes[i].nome = n
            }
            let novoTitulo = titulo.trimmingCharacters(in: .whitespaces)
            let antigo = s.markdown
            if !novoTitulo.isEmpty && novoTitulo != s.titulo {
                s.titulo = novoTitulo
                s.markdown = nil
            }
            try? livro.salvar()
            try? s.gravarMarkdown()
            if let antigo, antigo != s.markdown { try? FileManager.default.removeItem(atPath: antigo) }
            try? s.salvar()
            if s.semNome.isEmpty { s.apagarAudio() }
            DispatchQueue.main.async {
                self?.recarregarPendentes()
                self?.aoMudar()
            }
        }
    }

    func descartarPendente(_ sessao: Sessao) {
        sessao.apagarAudio()
        recarregarPendentes()
        aoMudar()
    }

    // MARK: arquivos

    /// Sessões com vozes sem nome e áudio ainda guardado (para você ouvir e nomear).
    func recarregarPendentes() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let pastas = (try? FileManager.default.contentsOfDirectory(at: Self.pastaSessoes, includingPropertiesForKeys: nil)) ?? []
        pendentes = pastas.compactMap { p -> Sessao? in
            guard let d = try? Data(contentsOf: p.appendingPathComponent("sessao.json")),
                  let s = try? dec.decode(Sessao.self, from: d),
                  !s.semNome.isEmpty,
                  FileManager.default.fileExists(atPath: p.appendingPathComponent("outros.wav").path) else { return nil }
            return s
        }.sorted { $0.inicio > $1.inicio }
    }

    /// Áudio de chamadas com mais de 7 dias é apagado, mesmo com vozes sem nome.
    private func limparAntigas() {
        let limite = Date().addingTimeInterval(-7 * 24 * 3600)
        let pastas = (try? FileManager.default.contentsOfDirectory(at: Self.pastaSessoes, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for p in pastas {
            let criada = (try? p.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            if criada < limite {
                for f in ["voce.wav", "outros.wav"] { try? FileManager.default.removeItem(at: p.appendingPathComponent(f)) }
            }
        }
    }

    // MARK: modelo do Whisper

    private var observacao: NSKeyValueObservation?

    private func baixarModelo(depois: @escaping @MainActor () -> Void) {
        guard baixandoModelo == nil else { return }
        baixandoModelo = 0
        aoMudar()
        let destino = Modelos.destinoWhisper
        let tarefa = URLSession.shared.downloadTask(with: Modelos.urlWhisper) { [weak self] tmp, _, erro in
            var ok = false
            if let tmp {
                try? FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destino)
                ok = (try? FileManager.default.moveItem(at: tmp, to: destino)) != nil
            }
            DispatchQueue.main.async {
                self?.baixandoModelo = nil
                self?.observacao = nil
                if ok {
                    depois()
                } else {
                    self?.emAndamento = nil
                    self?.ultimoErro = "Não consegui baixar o modelo de transcrição: \(erro?.localizedDescription ?? "erro desconhecido")"
                }
                self?.aoMudar()
            }
        }
        observacao = tarefa.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { self?.baixandoModelo = f; self?.aoMudar() }
        }
        tarefa.resume()
    }

    // MARK: aviso

    private func avisar(_ s: Sessao) {
        let c = UNMutableNotificationContent()
        c.title = "Transcrição pronta: \(s.titulo)"
        c.body = s.semNome.isEmpty
            ? "Salva em Ligações. Clique para abrir."
            : "\(s.semNome.count) voz(es) sem nome. Clique para ouvir e dar nome; o app passa a reconhecer essas pessoas."
        c.userInfo = ["sessao": s.id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: s.id, content: c, trigger: nil))
    }

    func sessao(id: String) -> Sessao? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let url = Self.pastaSessoes.appendingPathComponent(id).appendingPathComponent("sessao.json")
        return (try? Data(contentsOf: url)).flatMap { try? dec.decode(Sessao.self, from: $0) }
    }
}
