import AppKit
import ApplicationServices
import os

/// Lê no app da chamada se o seu microfone está no mudo, pelo botão de microfone do Meet, Zoom, Teams ou Slack.
/// Usa a Acessibilidade do macOS, o mesmo caminho dos leitores de tela: só lê o rótulo do botão
/// ("Ativar microfone" = está no mudo), não clica em nada e não vê a tela.
///
/// Por que precisa: o mudo é do app da chamada. O Meet continua ouvindo o microfone no mudo (para avisar
/// "você está no mudo?"), então o Frevo recebe sua voz mesmo assim e não tem como saber sozinho.
final class VigiaDoMudo: @unchecked Sendable {
    enum Estado: String { case mudo, aberto, desconhecido }

    /// Chamado na fila principal quando o estado muda.
    var aoMudar: (Estado) -> Void = { _ in }

    private let bundle: String
    private let fila = DispatchQueue(label: "io.github.joaopaulosmoura.frevo.mudo", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var app: AXUIElement?
    private var botao: AXUIElement?
    private var ultimaBusca = Date.distantPast
    private var estado = Estado.desconhecido
    private var avisouPermissao = false
    private var buscasSemAchar = 0
    private let log = Logger(subsystem: "io.github.joaopaulosmoura.frevo", category: "mudo")

    static var permitido: Bool { AXIsProcessTrusted() }

    /// Mostra o pedido do macOS ("Frevo quer controlar este computador usando a acessibilidade").
    static func pedirPermissao() {
        let opcoes = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opcoes)
    }

    /// `familia`: bundle do app dono do áudio da chamada ("com.google.Chrome", "us.zoom.xos"...).
    init(familia: String) {
        bundle = familia == "com.apple.WebKit" ? "com.apple.Safari" : familia
        navegador = Self.ehNavegador(bundle)
    }

    /// Chamada num navegador: o botão do microfone está na página, nunca na barra do navegador.
    private let navegador: Bool
    /// Atributo que o Frevo ligou no app para ele mostrar a árvore das páginas (desligado no fim da chamada).
    private var atributoLigado: String?

    private static let navegadores: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "com.apple.Safari", "com.kagi.kagimacOS",
    ]

    static func ehNavegador(_ bundle: String) -> Bool {
        if navegadores.contains(bundle) { return true }
        // família do Firefox (Firefox, Zen, LibreWolf, Floorp…): todos trazem o XUL
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/MacOS/XUL").path)
    }

    func iniciar() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: fila)
        t.schedule(deadline: .now(), repeating: 0.3)
        t.setEventHandler { [weak self] in self?.ler() }
        timer = t
        t.resume()
    }

    func parar() {
        timer?.cancel()
        timer = nil
        fila.async { [self] in
            // devolve o app ao normal (a árvore de acessibilidade das páginas custa um pouco de CPU)
            if let atributoLigado, let app {
                AXUIElementSetAttributeValue(app, atributoLigado as CFString, kCFBooleanFalse)
            }
            atributoLigado = nil
            botao = nil
            app = nil
        }
    }

    // MARK: leitura (fila própria)

    private func ler() {
        guard AXIsProcessTrusted() else {
            if !avisouPermissao {
                avisouPermissao = true
                log.notice("sem permissão de Acessibilidade: não dá para ler o mudo de \(self.bundle, privacy: .public)")
            }
            return mudar(.desconhecido)
        }
        if app == nil {
            guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier else {
                return mudar(.desconhecido)
            }
            let a = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(a, 0.5)
            // Navegadores e apps feitos com eles só montam a árvore das páginas quando um leitor de tela pede.
            // Os de Electron (Slack…) aceitam AXManualAccessibility; o Chrome e os da família do Firefox (Zen),
            // só AXEnhancedUserInterface, o sinal do VoiceOver. Se já estava ligado (VoiceOver aberto), não mexe.
            var situacao = "erro"
            for atributo in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
                if (Self.atributo(a, atributo) as? Bool) == true {
                    situacao = "já ligada (\(atributo))"
                    break
                }
                let r = AXUIElementSetAttributeValue(a, atributo as CFString, kCFBooleanTrue)
                if r == .success {
                    atributoLigado = atributo
                    situacao = "ligada por \(atributo)"
                    break
                }
                situacao += " \(r.rawValue)"
            }
            log.notice("lendo o mudo em \(self.bundle, privacy: .public)\(self.navegador ? " (navegador)" : "", privacy: .public) (árvore das páginas: \(situacao, privacy: .public))")
            app = a
        }
        if let b = botao, let rotulo = Self.rotulo(b), let e = Self.estado(doRotulo: rotulo) {
            return mudar(e)
        }
        // botão sumiu (aba trocada, layout mudou) ou ainda não achado: procura de novo, sem exagero
        botao = nil
        // procura a cada 3 s no começo; depois de várias tentativas sem achar, a cada 15 s (a busca pesa no app)
        let intervalo: TimeInterval = buscasSemAchar < 5 ? 3 : 15
        guard Date().timeIntervalSince(ultimaBusca) > intervalo, let app else { return }
        ultimaBusca = Date()
        var d = Diagnostico()
        if let (b, rotulo) = Self.procurarBotao(em: app, navegador: navegador, diag: &d), let e = Self.estado(doRotulo: rotulo) {
            botao = b
            buscasSemAchar = 0
            log.notice("botão do microfone: \(rotulo, privacy: .public) (\(d.resumo, privacy: .public))")
            mudar(e)
        } else {
            buscasSemAchar += 1
            if buscasSemAchar == 1 || buscasSemAchar % 10 == 0 {
                log.notice("não achei o botão do microfone em \(self.bundle, privacy: .public): \(d.resumo, privacy: .public)")
            }
        }
        // sem botão: mantém o último estado conhecido (ex.: você foi para outra aba do Chrome)
    }

    private func mudar(_ novo: Estado) {
        guard novo != estado else { return }
        estado = novo
        log.notice("microfone na chamada: \(novo.rawValue, privacy: .public)")
        DispatchQueue.main.async { [aoMudar] in aoMudar(novo) }
    }

    // MARK: botão do microfone

    private static func atributo(_ e: AXUIElement, _ nome: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, nome as CFString, &v) == .success ? v : nil
    }

    private static func rotulo(_ e: AXUIElement) -> String? {
        let partes = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
            .compactMap { atributo(e, $0) as? String }
            .filter { !$0.isEmpty }
        return partes.isEmpty ? nil : partes.joined(separator: " · ")
    }

    /// O que a busca viu, para o registro (sem isso, um "não achei" não diz nada).
    struct Diagnostico {
        var areasWeb = 0
        var buscaDoNavegador = false
        var controles = 0
        var visitados = 0
        var segundos = 0.0
        var parecidos: [String] = []

        var resumo: String {
            String(format: "%d página(s), lista de botões do navegador: %@, %d controles, %d elementos percorridos, %.1f s",
                   areasWeb, buscaDoNavegador ? "sim" : "não", controles, visitados, segundos)
                + (parecidos.isEmpty ? "" : "; rótulos de áudio: " + parecidos.prefix(6).joined(separator: " | "))
        }
    }

    /// Procura o botão de microfone do app; fica com o mais provável de ser o seu (o da barra da chamada tem
    /// atalho de teclado no rótulo; os de "desativar o microfone de Fulano", não).
    ///
    /// 1) Em navegador, pede à página a lista de controles de uma vez (o mesmo recurso que o VoiceOver usa).
    /// 2) Senão (apps nativos, ou o navegador não respondeu), percorre a árvore do FIM para o começo, lendo cada
    ///    elemento numa consulta só: a barra do Meet fica no fim da página, depois da grade de vídeos.
    private static func procurarBotao(em app: AXUIElement, navegador: Bool, diag: inout Diagnostico) -> (AXUIElement, String)? {
        let inicio = Date()
        defer { diag.segundos = Date().timeIntervalSince(inicio) }
        let janelas = (atributo(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var candidatos: [(elemento: AXUIElement, rotulo: String, naPagina: Bool)] = []

        let areas = janelas.flatMap { areasWeb(em: $0) }
        diag.areasWeb = areas.count
        for a in areas {
            guard let controles = controlesPorBusca(em: a) else { continue }
            diag.buscaDoNavegador = true
            for c in controles {
                diag.controles += 1
                if let r = rotulo(c) { candidatos.append((c, r, true)) }
            }
        }

        if !candidatos.contains(where: { estado(doRotulo: $0.rotulo, naPagina: $0.naPagina, navegador: navegador) != nil }) {
            var pilha = janelas.map { ($0, false) }
            while let (e, naPagina) = pilha.popLast(), diag.visitados < 40000, Date().timeIntervalSince(inicio) < 4 {
                diag.visitados += 1
                let v = valores(e, [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute, kAXChildrenAttribute])
                let papel = v[0] as? String ?? ""
                if papeisDeBotao.contains(papel) {
                    let r = [v[1], v[2], v[3]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !r.isEmpty { candidatos.append((e, r, naPagina)) }
                }
                // filhos na ordem: o último sai primeiro da pilha, então a página é lida do fim para o começo
                let filhosNaPagina = naPagina || papel == "AXWebArea"
                if !folhas.contains(papel), let filhos = v[4] as? [AXUIElement] { pilha += filhos.map { ($0, filhosNaPagina) } }
            }
        }

        diag.parecidos = candidatos.map(\.rotulo).filter {
            let r = normalizar($0)
            return r.contains("micro") || r.contains("mute") || r.contains("mudo") || r.contains("audio") || r.contains("som")
        }
        let melhor = candidatos.filter { estado(doRotulo: $0.rotulo, naPagina: $0.naPagina, navegador: navegador) != nil }
            .max { pontuacao($0.rotulo) < pontuacao($1.rotulo) }
        guard let m = melhor, pontuacao(m.rotulo) > -3 else { return nil }
        return (m.elemento, m.rotulo)
    }

    /// O estado que um botão candidato indica, ou nil se ele não deve contar como o microfone da chamada:
    /// - num navegador, só vale botão de dentro da página (o "Ativar som" da aba do navegador é do alto-falante);
    /// - dentro de uma página, só vale rótulo que fale de microfone ou mudo: "Ativar som" ou "áudio ativado" sozinhos
    ///   costumam ser do vídeo, do alto-falante ou do quadradinho de outra pessoa. Em app nativo (Zoom) eles valem.
    static func estado(doRotulo rotulo: String, naPagina: Bool, navegador: Bool) -> Estado? {
        if navegador && !naPagina { return nil }
        let r = normalizar(rotulo)
        let falaDoMicrofone = r.contains("micro") || r.contains("mudo") || r.contains("mute")
        if (navegador || naPagina) && !falaDoMicrofone { return nil }
        return estado(doRotulo: rotulo)
    }

    private static let papeisDeBotao: Set<String> = [kAXButtonRole, kAXCheckBoxRole, "AXToggle", kAXMenuItemRole, kAXPopUpButtonRole]
    private static let folhas: Set<String> = [kAXStaticTextRole, kAXImageRole, kAXButtonRole, kAXCheckBoxRole, kAXTextFieldRole,
                                              kAXTextAreaRole, "AXToggle", kAXMenuItemRole]

    /// Várias propriedades de um elemento numa consulta só (cada consulta é uma ida e volta ao outro app).
    private static func valores(_ e: AXUIElement, _ nomes: [String]) -> [Any?] {
        var v: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, nomes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &v) == .success,
              let lista = v as? [Any] else { return nomes.map { _ in nil } }
        return lista.map { item -> Any? in
            // valor que faltou volta como um AXValue de erro
            if CFGetTypeID(item as CFTypeRef) == AXValueGetTypeID(), AXValueGetType(item as! AXValue) == .axError { return nil }
            return item
        }
    }

    /// As páginas abertas (AXWebArea) de uma janela; não entra nelas.
    private static func areasWeb(em janela: AXUIElement) -> [AXUIElement] {
        var achadas: [AXUIElement] = []
        var pilha: [(AXUIElement, Int)] = [(janela, 0)]
        var n = 0
        while let (e, prof) = pilha.popLast(), n < 3000 {
            n += 1
            let v = valores(e, [kAXRoleAttribute, kAXChildrenAttribute])
            if v[0] as? String == "AXWebArea" {
                achadas.append(e)
                continue
            }
            if prof < 25, let filhos = v[1] as? [AXUIElement] { pilha += filhos.map { ($0, prof + 1) } }
        }
        return achadas
    }

    /// Todos os controles de uma página numa consulta só (busca por predicado, a do rotor do VoiceOver).
    private static func controlesPorBusca(em area: AXUIElement) -> [AXUIElement]? {
        let predicado: [String: Any] = [
            "AXSearchKey": "AXControlSearchKey",
            "AXResultsLimit": 2000,
            "AXDirection": "AXDirectionNext",
            "AXImmediateDescendantsOnly": false,
            "AXVisibleOnly": false,
        ]
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(area, "AXUIElementsForSearchPredicate" as CFString,
                                                         predicado as CFDictionary, &v) == .success else { return nil }
        return v as? [AXUIElement]
    }

    private static func normalizar(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "pt_BR"))
    }

    private static func pontuacao(_ rotulo: String) -> Int {
        let r = normalizar(rotulo)
        var p = 0
        if r.contains("⌘") || r.contains("ctrl") || r.contains("cmd") { p += 3 } // botão principal tem atalho
        if r.contains("micro") { p += 1 }
        // botões de anfitrião: "Desativar o microfone de Ana", "Mute all", "Silenciar todos"
        for termo in [" de ", " do ", " da ", "todos", " all", "participante", "someone", "everyone"] where r.contains(termo) { p -= 4 }
        return p
    }

    /// Estado atual a partir do rótulo do botão. O rótulo diz a AÇÃO do botão:
    /// "Ativar microfone" / "Turn on microphone" / "Unmute" / "Desativar mudo" = você está no mudo.
    static func estado(doRotulo rotulo: String) -> Estado? {
        let r = normalizar(rotulo)
        let temMicro = r.contains("micro")
        let temSom = r.contains("audio") || r.contains("som") || r.contains("mudo") || r.contains("mute")
        guard temMicro || temSom else { return nil }
        // inglês
        if r.contains("unmute") { return .mudo }
        if r.contains("mute") { return .aberto }
        if temMicro && r.contains("turn on") { return .mudo }
        if temMicro && r.contains("turn off") { return .aberto }
        // português: "mudo" inverte o sentido ("ativar mudo" = vai ficar mudo, então está aberto)
        if r.contains("mudo") {
            if r.contains("desativar mudo") || r.contains("desativar o mudo") || r.contains("sair do mudo") || r.contains("tirar do mudo") { return .mudo }
            if r.contains("ativar mudo") || r.contains("ativar o mudo") || r.contains("ficar mudo") || r.contains("colocar no mudo") { return .aberto }
            return nil
        }
        if r.contains("silenciar") { return .aberto }
        if r.contains("desativar") || r.contains("desligar") || r.contains("desabilitar") { return .aberto }
        if r.contains("ativar") || r.contains("ligar") || r.contains("habilitar") { return .mudo }
        return nil
    }
}
