import Foundation
import os
import UserNotifications

/// Avisa quando sai versão nova do Frevo e atualiza com um clique.
///
/// O Frevo é compilado no próprio Mac, a partir de um clone do repositório (sem certificado pago da Apple). Na
/// compilação, o app guarda de qual pasta veio (`FrevoCodigo`) e em qual versão estava (`FrevoVersao`, a marca do
/// git, ex.: v0.3.0). De tempos em tempos ele busca as marcas novas (`git fetch --tags`); o botão "Atualizar" roda
/// scripts/atualizar.sh, que recompila só o que mudou, espera a chamada acabar e reinstala: o app fecha e abre
/// de novo, já na versão nova.
@MainActor
final class Atualizador {
    struct Versao: Equatable {
        let marca: String
        let notas: String
    }

    private(set) var disponivel: Versao?
    private(set) var atualizando = false
    private(set) var erro: String?
    var aoMudar: () -> Void = {}

    /// O clone de onde este app foi compilado (nil: compilado de outro jeito, sem como atualizar sozinho).
    let pasta: URL?
    /// `git describe` na hora da compilação: "v0.3.0", "v0.3.0-4-gabc1234" (4 commits depois) ou só o commit.
    let compilado: String
    private let fila = DispatchQueue(label: "io.github.joaopaulosmoura.frevo.atualizacao", qos: .utility)
    private var relogio: Timer?
    private let log = Logger(subsystem: "io.github.joaopaulosmoura.frevo", category: "atualizacao")
    static let registro = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Frevo/atualizacao.log")

    init() {
        let info = Bundle.main.infoDictionary ?? [:]
        compilado = info["FrevoVersao"] as? String ?? "dev"
        pasta = (info["FrevoCodigo"] as? String).map { URL(fileURLWithPath: $0) }.flatMap {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent(".git").path) ? $0 : nil
        }
    }

    /// A versão para mostrar: "v0.3.0", ou a marca com "+" se for uma compilação de depois dela.
    var versaoAtual: String {
        guard let base = Self.marca(de: compilado) else { return "versão de desenvolvimento" }
        return base == compilado ? base : base + "+"
    }

    /// Primeira busca um minuto depois de abrir (para não pesar na abertura), depois a cada 6 horas.
    func comecar() {
        guard pasta != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.procurar(manual: false) }
        relogio = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.procurar(manual: false) }
        }
    }

    /// `manual`: você pediu pelo menu; avisa também quando não há nada novo.
    func procurar(manual: Bool) {
        guard let pasta else {
            if manual { avisar("Atualização automática indisponível", "Este Frevo não foi instalado a partir de um clone do repositório.") }
            return
        }
        let compilado = self.compilado
        fila.async { [weak self] in
            let conectou = Self.git(pasta, ["fetch", "--tags", "--quiet", "origin"]) != nil
            let marcas = (Self.git(pasta, ["tag", "-l", "v[0-9]*", "--sort=-v:refname"]) ?? "").split(separator: "\n").map(String.init)
            var nova: Versao?
            if let ultima = marcas.first, Self.maisNova(ultima, que: compilado) {
                let notas = Self.git(pasta, ["tag", "-l", "--format=%(contents)", ultima]) ?? ""
                nova = Versao(marca: ultima, notas: Self.limpar(notas))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.disponivel = nova
                    let prefs = UserDefaults.standard
                    if let nova, prefs.string(forKey: "versaoAvisada") != nova.marca {
                        prefs.set(nova.marca, forKey: "versaoAvisada")
                        let resumo = nova.notas.split(separator: "\n").first.map(String.init) ?? "Abra o Frevo na barra de menu para atualizar."
                        self.avisar("Nova versão do Frevo: \(nova.marca)", resumo)
                    } else if manual && nova == nil {
                        if conectou {
                            self.avisar("O Frevo está atualizado", "Você já está na versão mais nova (\(self.versaoAtual)).")
                        } else {
                            self.avisar("Não consegui procurar atualizações", "Sem conexão com o GitHub agora. Tente de novo mais tarde.")
                        }
                    }
                    self.log.notice("procurou atualização: \(nova?.marca ?? "nenhuma", privacy: .public) (compilado: \(compilado, privacy: .public))")
                    self.aoMudar()
                }
            }
        }
    }

    /// Roda scripts/atualizar.sh. Se der certo, o script fecha este app e abre a versão nova: chegar ao fim aqui
    /// (o script terminou com o app ainda aberto) quer dizer que algo falhou.
    func atualizar() {
        guard let pasta, let v = disponivel, !atualizando else { return }
        atualizando = true
        erro = nil
        aoMudar()
        log.notice("atualizando para \(v.marca, privacy: .public)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [pasta.appendingPathComponent("scripts/atualizar.sh").path, v.marca]
        p.currentDirectoryURL = pasta
        // a saída vai para o registro (o script cuida disso): um cano ligado a este app se romperia quando ele fechar
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { processo in
            let codigo = processo.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    self.atualizando = false
                    switch codigo {
                    case 0: self.erro = "Atualizado. Feche e abra o Frevo para usar a versão nova."
                    case 2: self.erro = "Há mudanças suas no código do Frevo: atualize pelo terminal (scripts/atualizar.sh)."
                    default: self.erro = "A atualização não terminou. Detalhes em ~/Library/Logs/Frevo/atualizacao.log."
                    }
                    self.aoMudar()
                }
            }
        }
        do {
            try p.run()
        } catch {
            atualizando = false
            erro = "Não consegui rodar o atualizador: \(error.localizedDescription)"
            aoMudar()
        }
    }

    private func avisar(_ titulo: String, _ corpo: String) {
        let c = UNMutableNotificationContent()
        c.title = titulo
        c.body = corpo
        c.userInfo = ["atualizacao": true]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "atualizacao", content: c, trigger: nil))
    }

    // MARK: git e versões (fora da thread principal)

    /// Roda o git na pasta do código; nil se falhar ou passar de 60 s.
    nonisolated private static func git(_ pasta: URL, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", pasta.path] + args
        p.environment = ["GIT_TERMINAL_PROMPT": "0", "PATH": "/usr/bin:/bin:/opt/homebrew/bin",
                         "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        let saida = Pipe()
        p.standardOutput = saida
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // rede travada não pode prender a busca para sempre
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if p.isRunning { p.terminate() } }
        let dados = saida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: dados, as: UTF8.self)
    }

    /// A marca no começo de um `git describe`: "v0.3.0-4-gabc1234-dirty" → "v0.3.0". Nil se não houver marca.
    nonisolated static func marca(de descricao: String) -> String? {
        guard descricao.hasPrefix("v") else { return nil }
        let corpo = descricao.dropFirst().prefix { $0.isNumber || $0 == "." }
        guard let primeiro = corpo.first, primeiro.isNumber else { return nil }
        return "v" + corpo
    }

    /// `marca` (ex.: v0.4.0) é mais nova que a versão compilada? Uma compilação sem marca nenhuma sempre perde.
    nonisolated static func maisNova(_ marca: String, que compilado: String) -> Bool {
        guard let base = Self.marca(de: compilado) else { return true }
        func numeros(_ s: String) -> [Int] { s.dropFirst().split(separator: ".").map { Int($0) ?? 0 } }
        let a = numeros(marca), b = numeros(base)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Notas da marca sem a assinatura PGP (se a marca for assinada).
    nonisolated private static func limpar(_ notas: String) -> String {
        let semAssinatura = notas.components(separatedBy: "-----BEGIN PGP SIGNATURE-----").first ?? notas
        return semAssinatura.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
