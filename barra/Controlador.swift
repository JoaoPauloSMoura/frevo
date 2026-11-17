import AppKit
import CoreAudio
import EventKit
import os
import ServiceManagement
import UserNotifications

/// O app da barra de menu.
///
/// Fica parado (sem abrir o microfone) até algum app abrir o "Frevo". Aí liga o microfone físico,
/// o DeepFilterNet3 e o Feed. Se o app também estiver tocando som (a voz dos outros), é uma chamada:
/// mostra o aviso "Transcrever esta chamada" e, ligado, grava a sua voz limpa e o som da chamada.
/// Áudio de WhatsApp, ditado e afins só passam pelo filtro, sem gravar. Quando a chamada fecha, transcreve.
@MainActor
final class Controlador: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    /// O que o painel e a ilha do notch mostram.
    private let estado = EstadoDoApp()
    private lazy var painel = Painel(estado: estado)
    private lazy var ilha = Ilha(estado: estado)
    private var tiques = 0
    private let prefs = UserDefaults.standard
    private let agenda = Agenda()
    private let escrivao = Escrivao()
    private let atualizador = Atualizador()
    private let janelaNomes = JanelaNomes()

    private var motor: Motor?
    private var pipe: Pipeline?
    private var micAtual: Dispositivo?
    private var emChamada = false
    private var problema: String?
    private var relogio: Timer?
    private var ultimoBloco = 0
    private var tiquesSemAudio = 0

    // chamada sendo gravada
    private var gravacao: Gravacao?
    private var sessaoAtual: Sessao?
    /// Quem está falando, ao vivo (só em chamada gravada, com a pergunta ligada nos ajustes).
    private var quemFala: QuemFala?

    // chamada atual (o app que abriu o microfone também toca som)
    private var chamadaDetectada = false
    private var numeroDaChamada = 0
    /// Interruptor "Transcrever esta chamada"; começa com o padrão do menu.
    private var transcreverEsta = false
    private var microfoneAbertoEm: Date?
    private var appDaChamada: String?
    private var eventoDaChamada: (titulo: String, convidados: [String])?
    /// Código do Meet lido no começo da chamada (para tentar a agenda de novo no fim, se precisar).
    private var codigoDaChamada: String?
    private let aviso = AvisoDeChamada()
    /// Lê o botão de microfone do app da chamada; os trechos no mudo saem da transcrição.
    private var vigia: VigiaDoMudo?
    private var estadoDoMicrofone = VigiaDoMudo.Estado.desconhecido
    private var mudoDesde: Date?
    /// Trechos no mudo desta gravação (relógio de parede; viram segundos da sessão no fim).
    private var trechosNoMudo: [(Date, Date)] = []
    /// Você desligou a transcrição nesta chamada: nada mais fica guardado nela, nem na memória.
    private var descartadaNestaChamada = false
    private let log = Logger(subsystem: "io.github.joaopaulosmoura.frevo", category: "chamada")
    private let logAudio = Logger(subsystem: "io.github.joaopaulosmoura.frevo", category: "audio")
    /// Pulos (sobra cortada) e faltas (silêncio inserido) na fila entre o microfone e o Frevo, somados até o
    /// próximo registro. Cada um é um tranco no som que vai para a chamada.
    private var pulosSomados = 0
    private var faltasSomadas = 0
    private var ultimoRegistroDoAudio = Date.distantPast

    private var filtroLigado: Bool {
        get { prefs.object(forKey: "filtroLigado") as? Bool ?? true }
        set {
            prefs.set(newValue, forKey: "filtroLigado")
            pipe?.filtroLigado.store(newValue, ordering: .relaxed)
            atualizarIcone()
        }
    }

    /// Padrão do interruptor "Transcrever esta chamada" no começo de cada chamada.
    private var transcrever: Bool {
        get { prefs.object(forKey: "transcrever") as? Bool ?? true }
        set { prefs.set(newValue, forKey: "transcrever") }
    }

    /// UID do microfone escolhido no menu; nil = automático.
    private var micEscolhido: String? {
        get { prefs.string(forKey: "micUID") }
        set { prefs.set(newValue, forKey: "micUID") }
    }

    // MARK: ciclo de vida

    func applicationDidFinishLaunching(_ notification: Notification) {
        item.button?.target = self
        item.button?.action = #selector(clicouNoIcone)
        ligarAcoes()
        do {
            motor = try Motor(modelo: Motor.caminhoDoModelo())
        } catch {
            problema = "Não consegui carregar o filtro: \(error)"
        }
        escrivao.aoMudar = { [weak self] in self?.atualizarIcone() }
        atualizador.aoMudar = { [weak self] in self?.atualizarEstado() }
        atualizador.comecar()
        // transcrição pronta com vozes novas: abre a janela "Quem falou?" (se você não estiver em outra chamada)
        escrivao.aoTerminar = { [weak self] s in
            guard let self, !s.semNome.isEmpty, !self.emChamada else { return }
            self.abrirNomes(s)
        }
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if transcrever { pedirPermissoesDeTranscricao() }
        pedirAcessibilidade()
        // A agenda (nome da reunião) e o controle do navegador (link do Meet) são pedidos na abertura, fora de
        // chamada: as permissões do macOS ficam presas à assinatura do app e podem zerar quando ela muda.
        agenda.pedirAcesso()
        DispatchQueue.global(qos: .utility).async { [log] in
            let chrome = Self.permissaoDeControlar("com.google.Chrome", pedir: true)
            let cal: String
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: cal = "liberada"
            case .notDetermined: cal = "ainda não respondida"
            case .denied: cal = "negada"
            case .restricted: cal = "restrita"
            case .writeOnly: cal = "só escrita"
            @unknown default: cal = "?"
            }
            log.notice("permissões: agenda \(cal, privacy: .public); acessibilidade \(VigiaDoMudo.permitido ? "liberada" : "negada", privacy: .public); controlar o Chrome \(chrome, privacy: .public)")
        }
        verificar()
        relogio = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.verificar() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        desligarReferenciaDoEco()
        pipe?.parar()
        encerrarGravacao()
        aviso.fechar()
    }

    // MARK: liga e desliga conforme a chamada

    /// Roda a cada meio segundo.
    private func verificar() {
        defer { atualizarIcone() }
        guard let motor else { return }

        guard let mic = Audio.porUID(Audio.uidMic), let feed = Audio.porUID(Audio.uidFeed) else {
            parar()
            encerrarGravacao()
            fimDaChamada()
            problema = "O driver do Frevo não está instalado."
            return
        }
        if problema == "O driver do Frevo não está instalado." { problema = nil }

        emChamada = Audio.emUso(mic)
        guard emChamada else {
            parar()
            encerrarGravacao()
            fimDaChamada()
            return
        }

        if !chamadaDetectada { detectarChamada(mic: mic) }
        // a gravação dura a chamada inteira, mesmo se o filtro reiniciar no meio (troca de microfone etc.). Sem
        // transcrição, fica só na memória: se você ligar depois, o começo da chamada entra junto.
        if chamadaDetectada && gravacao == nil && !descartadaNestaChamada { iniciarGravacao(mic: mic, naMemoria: !transcreverEsta) }

        let alvo = escolherMicrofone()
        if let p = pipe, p.feedID == feed, p.micID == alvo?.id {
            // Já rodando com o microfone certo. Confere se o áudio continua chegando:
            // se o serviço de áudio do Mac reiniciar, as AudioUnits morrem em silêncio.
            let blocos = p.blocosRecebidos.load(ordering: .relaxed)
            tiquesSemAudio = blocos == ultimoBloco ? tiquesSemAudio + 1 : 0
            ultimoBloco = blocos
            if tiquesSemAudio < 4 { return }
        }

        parar()
        guard let alvo else {
            problema = "Nenhum microfone encontrado."
            return
        }
        guard Audio.definirTaxa(alvo.id, Pipeline.taxa) else {
            problema = "\(alvo.nome) não aceita 48 kHz. Escolha outro microfone."
            return
        }
        let p = Pipeline(motor: motor, mic: alvo.id, feed: feed, trilhaVoz: gravacao?.voce)
        p.filtroLigado.store(filtroLigado, ordering: .relaxed)
        p.ecoLigado.store(cancelarEco, ordering: .relaxed)
        do {
            try p.iniciar()
            pipe = p
            micAtual = alvo
            problema = nil
            ultimoBloco = 0
            tiquesSemAudio = 0
            _ = p.medir()
            ligarReferenciaDoEco(p)
        } catch {
            p.parar()
            problema = "Não consegui abrir \(alvo.nome): \(error)"
        }
    }

    private func parar() {
        desligarReferenciaDoEco()
        pipe?.parar()
        pipe = nil
        micAtual = nil
    }

    // MARK: cancelador de eco

    /// Liga o cancelador de eco (padrão: ligado). Com fone ele não acha eco e deixa a voz passar.
    /// Perguntar na ilha quem está falando (para a transcrição sair com os nomes).
    private var perguntarQuemFala: Bool {
        get { prefs.object(forKey: "perguntarQuemFala") as? Bool ?? true }
        set { prefs.set(newValue, forKey: "perguntarQuemFala") }
    }

    private var cancelarEco: Bool {
        get { prefs.object(forKey: "cancelarEco") as? Bool ?? true }
        set { prefs.set(newValue, forKey: "cancelarEco") }
    }
    /// Captura do som que o Mac está tocando (tudo, menos o Frevo), usada só como referência do cancelador,
    /// enquanto o filtro roda. Fica em memória: nada disso é gravado.
    private var capturaDoEco: CapturaDoSistema?
    private let filaEco = DispatchQueue(label: "io.github.joaopaulosmoura.frevo.eco", qos: .userInitiated)
    private var ligandoEco = false
    /// A captura leva uns 2 s para começar a entregar som depois de montada.
    private var ecoLigadoEm = Date.distantPast
    private var quadrosDaReferencia = 0
    private var checagensDoEco = 0

    /// Monta a captura em segundo plano (pode demorar um instante) e entrega o som ao Pipeline.
    private func ligarReferenciaDoEco(_ p: Pipeline) {
        guard cancelarEco, capturaDoEco == nil, !ligandoEco else { return }
        ligandoEco = true
        filaEco.async { [weak self] in
            let resultado = Result { try CapturaDoSistema(processos: []) { taxa in p.receberReferencia(taxa: taxa) } }
            Task { @MainActor in
                guard let self else { return }
                self.ligandoEco = false
                switch resultado {
                case .success(let c):
                    guard self.pipe === p, self.cancelarEco, self.capturaDoEco == nil else {
                        c.parar()
                        p.perderReferencia()
                        return
                    }
                    self.capturaDoEco = c
                    self.quadrosDaReferencia = 0
                    self.ecoLigadoEm = Date()
                    self.logAudio.notice("cancelador de eco ligado (som do Mac a \(p.taxaDaReferencia) Hz)")
                case .failure(let erro):
                    p.perderReferencia()
                    self.logAudio.notice("cancelador de eco sem o som do Mac: \(String(describing: erro), privacy: .public)")
                }
            }
        }
    }

    private func desligarReferenciaDoEco() {
        capturaDoEco?.parar()
        capturaDoEco = nil
        pipe?.perderReferencia()
    }

    /// A cada 2 s (junto com as medidas do áudio): se a captura do som do Mac parou (ex.: a saída de som foi
    /// trocada e o dispositivo dela sumiu), monta de novo; a cada 30 s, registra quanto eco está saindo.
    private func vigiarEco(_ p: Pipeline) {
        guard cancelarEco else { return }
        guard let c = capturaDoEco else {
            ligarReferenciaDoEco(p)
            return
        }
        let recebidos = c.quadrosRecebidos.load(ordering: .relaxed)
        if recebidos == quadrosDaReferencia {
            guard Date().timeIntervalSince(ecoLigadoEm) > 8 else { return } // ainda começando
            logAudio.notice("o som do Mac parou de chegar ao cancelador de eco; montando a captura de novo")
            desligarReferenciaDoEco()
            ligarReferenciaDoEco(p)
            return
        }
        quadrosDaReferencia = recebidos
        checagensDoEco += 1
        if checagensDoEco % 15 == 0, let m = p.medidasDoEco(), m.erle_db >= 0 {
            logAudio.notice("eco: \(Int(m.erle_db)) dB a menos, atraso \(m.atraso_ms) ms")
        }
    }

    private func escolherMicrofone() -> Dispositivo? {
        let lista = Audio.microfones()
        if let uid = micEscolhido, let m = lista.first(where: { $0.uid == uid }) { return m }
        return Audio.microfoneAutomatico(lista)
    }

    // MARK: gravação para transcrever

    // MARK: chamada

    /// Microfone aberto: só é chamada se o mesmo app também estiver tocando som (a voz dos outros).
    /// Áudio de WhatsApp, ditado, teste de microfone: só passam pelo filtro, sem aviso e sem gravar.
    private func detectarChamada(mic: AudioObjectID) {
        let (usando, tocando) = Audio.processosDaChamada(mic)
        if microfoneAbertoEm == nil {
            microfoneAbertoEm = Date()
            log.notice("microfone aberto por \(Self.descrever(usando), privacy: .public); tocando som: \(Self.descrever(tocando), privacy: .public)")
        }
        guard !tocando.isEmpty else { return }

        chamadaDetectada = true
        numeroDaChamada += 1
        transcreverEsta = transcrever
        eventoDaChamada = nil
        codigoDaChamada = nil
        let app = usando.lazy.compactMap { Audio.nomeDoApp($0) }.first
        appDaChamada = app
        let espera = Date().timeIntervalSince(microfoneAbertoEm ?? Date())
        log.notice("chamada detectada em \(app ?? "?", privacy: .public) \(String(format: "%.1f", espera), privacy: .public) s depois de abrir o microfone; transcrever: \(self.transcreverEsta)")

        if let familia = usando.first.map(Audio.familia) {
            let v = VigiaDoMudo(familia: familia)
            v.aoMudar = { [weak self] e in self?.microfoneMudou(e) }
            v.iniciar()
            vigia = v
        }

        // O nome vem da agenda, mas só se for mesmo esta chamada (ver Agenda.evento). Ler o link do Meet
        // pode esperar a permissão "controlar o navegador", então roda em segundo plano.
        let numero = numeroDaChamada
        let inicio = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let codigo = LinkDaChamada.codigoMeet(app: app)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.chamadaDetectada, self.numeroDaChamada == numero else { return }
                    let evento = self.agenda.evento(em: inicio, codigoMeet: codigo)
                    self.eventoDaChamada = evento
                    self.codigoDaChamada = codigo
                    if let evento {
                        self.sessaoAtual?.titulo = evento.titulo
                        self.sessaoAtual?.convidados = evento.convidados
                        self.quemFala?.definirConvidados(evento.convidados)
                        self.aviso.atualizar(titulo: evento.titulo, subtitulo: codigo != nil ? "Google Meet" : "Chamada no \(app ?? "app")")
                    } else if codigo != nil {
                        self.aviso.atualizar(titulo: "Chamada no Google Meet")
                    }
                }
            }
        }

        if ilha.disponivel {
            // com notch, a ilha abre sozinha por alguns segundos com o interruptor de transcrever
            atualizarEstado()
            ilha.abrirPorAlgunsSegundos()
        } else {
            mostrarAviso(app: app, usando: usando)
        }
    }

    private func mostrarAviso(app: String?, usando: [AudioObjectID]) {
        aviso.mostrar(titulo: app.map { "Chamada no \($0)" } ?? "Chamada",
                      subtitulo: "Frevo",
                      icone: usando.first.flatMap { Self.iconeDoApp(Audio.familia($0)) },
                      transcrever: transcreverEsta,
                      ancora: item.button?.window?.frame) { [weak self] ligado in
            self?.definirTranscricaoDaChamada(ligado)
        }

    }

    private func fimDaChamada() {
        if chamadaDetectada { log.notice("chamada encerrada") }
        vigia?.parar()
        vigia = nil
        estadoDoMicrofone = .desconhecido
        mudoDesde = nil
        chamadaDetectada = false
        transcreverEsta = false
        microfoneAbertoEm = nil
        appDaChamada = nil
        eventoDaChamada = nil
        codigoDaChamada = nil
        descartadaNestaChamada = false
        aviso.fechar()
    }

    /// Interruptor do aviso (ou do menu). Ligar no meio da chamada leva junto o começo dela (até 15 min, que
    /// estavam só na memória). Desligar apaga o que já tinha sido gravado; ligar de novo grava dali em diante.
    private func definirTranscricaoDaChamada(_ ligado: Bool) {
        guard chamadaDetectada, ligado != transcreverEsta else { return }
        transcreverEsta = ligado
        log.notice("transcrever esta chamada: \(ligado)")
        if ligado {
            pedirPermissoesDeTranscricao()
            if let g = gravacao, g.estaNaMemoria {
                if let inicio = try? g.passarParaDisco() {
                    sessaoAtual?.inicio = inicio
                    sessaoAtual?.fim = inicio
                    log.notice("transcrição ligada no meio da chamada: entram junto \(Int(Date().timeIntervalSince(inicio)), privacy: .public) s que estavam na memória")
                }
                comecarQuemFala(g)
            } else if gravacao == nil, let mic = Audio.porUID(Audio.uidMic) {
                iniciarGravacao(mic: mic)
            }
        } else {
            encerrarGravacao(descartar: true)
        }
        aviso.atualizar(transcrever: ligado)
        atualizarIcone()
    }

    /// O vigia viu o botão de microfone mudar. Durante a gravação, anota os trechos no mudo.
    private func microfoneMudou(_ e: VigiaDoMudo.Estado) {
        estadoDoMicrofone = e
        guard gravacao != nil else { return }
        if e == .mudo {
            if mudoDesde == nil { mudoDesde = Date() }
        } else {
            fecharMudo(em: Date())
        }
    }

    /// Fecha o trecho no mudo aberto. O vigia lê o botão a cada 0,3 s, então o clique aconteceu até 0,3 s antes
    /// da leitura: os dois lados recuam isso (no fim, para não cortar o começo da sua fala ao sair do mudo).
    private func fecharMudo(em fim: Date) {
        defer { mudoDesde = nil }
        guard let ini = mudoDesde else { return }
        trechosNoMudo.append((ini.addingTimeInterval(-0.3), fim.addingTimeInterval(-0.3)))
    }

    /// Se o app pode mandar comandos para outro (ler as abas do Chrome atrás do link do Meet).
    /// `pedir`: mostra o pedido do macOS se ainda não foi respondido (só funciona com o app aberto).
    nonisolated private static func permissaoDeControlar(_ bundle: String, pedir: Bool) -> String {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return "não testado (app fechado)" }
        let alvo = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard let desc = alvo.aeDesc else { return "?" }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, pedir) {
        case noErr: return "liberado"
        case OSStatus(errAEEventNotPermitted): return "negado"
        case OSStatus(errAEEventWouldRequireUserConsent): return "ainda não respondido"
        case let st: return "erro \(st)"
        }
    }

    @objc private func abrirAgenda() {
        agenda.pedirAcesso()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Acessibilidade, para ler o mudo do app da chamada: pedida uma vez, fora de chamada.
    private func pedirAcessibilidade() {
        guard !VigiaDoMudo.permitido, !prefs.bool(forKey: "pediuAcessibilidade"), !emChamada else { return }
        prefs.set(true, forKey: "pediuAcessibilidade")
        VigiaDoMudo.pedirPermissao()
    }

    @objc private func abrirAcessibilidade() {
        VigiaDoMudo.pedirPermissao()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func descrever(_ processos: [AudioObjectID]) -> String {
        processos.isEmpty ? "ninguém" : processos.map { Audio.familia($0) }.joined(separator: ", ")
    }

    private static func iconeDoApp(_ bundle: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    // MARK: gravação para transcrever

    /// `naMemoria`: a transcrição está desligada; grava só na memória (sem arquivos) caso você ligue depois.
    private func iniciarGravacao(mic: AudioObjectID, naMemoria: Bool = false) {
        let id = UUID().uuidString
        let pasta = Escrivao.pastaSessoes.appendingPathComponent(id)
        guard let g = try? Gravacao(pasta: pasta, naMemoria: naMemoria) else { return }
        // o som dos outros: o app da chamada, incluindo processos auxiliares dele que tocam o áudio
        let (usando, tocando) = Audio.processosDaChamada(mic)
        var processos = usando
        for p in tocando where !processos.contains(p) { processos.append(p) }
        g.gravarOutros(processos: processos)
        if !naMemoria { comecarQuemFala(g) }
        trechosNoMudo = []
        gravacao = g
        pipe?.gravarVoz(em: g.voce) // o filtro já está rodando: passa a gravar sua voz sem reiniciar o microfone

        let hora = DateFormatter()
        hora.dateFormat = "HH'h'mm"
        sessaoAtual = Sessao(id: id, titulo: eventoDaChamada?.titulo ?? "Chamada \(hora.string(from: g.inicio))",
                             inicio: g.inicio, fim: g.inicio, app: appDaChamada, pasta: pasta.path)
        if let e = eventoDaChamada { sessaoAtual?.convidados = e.convidados }
        mudoDesde = estadoDoMicrofone == .mudo ? g.inicio : nil
    }

    /// A trilha dos outros passa também pelo detector de quem fala, que faz as perguntas da ilha.
    private func comecarQuemFala(_ g: Gravacao) {
        guard perguntarQuemFala else { return }
        let q = QuemFala(livro: LivroDeVozes(url: Modelos.livroDeVozes), convidados: eventoDaChamada?.convidados ?? []) {
            try? ImpressaoDeVoz(modelo: Modelos.voz())
        }
        q.deslocamento = g.ouvirOutros { q.receber($0) }
        quemFala = q
    }

    private func encerrarGravacao(descartar: Bool = false) {
        fecharMudo(em: Date())
        let marcas = quemFala?.marcas() ?? []
        quemFala?.parar()
        quemFala = nil
        if descartar { descartadaNestaChamada = true }
        guard let g = gravacao, var s = sessaoAtual else { return }
        if !marcas.isEmpty { s.marcas = marcas }
        gravacao = nil
        sessaoAtual = nil
        // o filtro para de escrever na trilha (ele a mantém viva até parar; escrever nela depois de fechada é inofensivo)
        pipe?.gravarVoz(em: nil)
        let soNaMemoria = g.estaNaMemoria
        let atraso = g.encerrar()
        if soNaMemoria { return } // a transcrição não foi ligada: a memória é solta e nada vai para o disco
        s.fim = Date()
        s.mudo = trechosNoMudo.compactMap { a, z -> [Double]? in
            let ra = max(0, a.timeIntervalSince(s.inicio)), rz = z.timeIntervalSince(s.inicio)
            return rz - ra >= 0.2 ? [ra, rz] : nil
        }
        trechosNoMudo = []
        // sem título da agenda no começo (ex.: a permissão da agenda chegou depois): tenta de novo agora
        if eventoDaChamada == nil, let e = agenda.evento(em: s.inicio, codigoMeet: codigoDaChamada) {
            s.titulo = e.titulo
            s.convidados = e.convidados
            log.notice("título achado no fim da chamada: \(e.titulo, privacy: .public)")
        }
        if descartar || s.fim.timeIntervalSince(s.inicio) < 20 {
            try? FileManager.default.removeItem(at: g.pasta) // chamada curta demais (ou transcrição desligada nela)
            return
        }
        escrivao.transcrever(s, atrasoOutros: atraso)
    }

    // MARK: ícone

    /// A sombrinha da barra de menu em cada estado (desenhadas uma vez só).
    private lazy var glifos: [Glifo.Marca: NSImage] = [
        .nenhuma: Glifo.sombrinha(), .ponto: Glifo.sombrinha(marca: .ponto), .risco: Glifo.sombrinha(marca: .risco),
    ]

    private func atualizarIcone() {
        guard let botao = item.button else { return }
        let imagem: NSImage?
        let descricao: String
        if problema != nil {
            imagem = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            descricao = "Frevo: problema"
        } else if gravacao != nil && transcreverEsta {
            imagem = glifos[.ponto]
            descricao = "Frevo: gravando a chamada para transcrever"
        } else if !filtroLigado {
            imagem = glifos[.risco]
            descricao = "Frevo: filtro desligado"
        } else {
            imagem = glifos[.nenhuma]
            descricao = pipe != nil ? "Frevo: limpando sua voz" : "Frevo: aguardando uma chamada"
        }
        imagem?.isTemplate = true
        if botao.image !== imagem { botao.image = imagem }
        botao.setAccessibilityLabel(descricao)
        botao.toolTip = descricao
        // aguardando chamada: ícone apagado; em chamada: aceso
        botao.appearsDisabled = pipe == nil && problema == nil && escrivao.emAndamento == nil
        atualizarEstado()
    }

    /// A cada 2 s: CPU do filtro para o painel e, no registro, os trancos da fila (no máximo uma linha a cada 10 s).
    private func medirAudio(_ p: Pipeline) {
        let m = p.medir()
        estado.definir(\.cpu, m.cpu)
        vigiarEco(p)
        pulosSomados += m.pulos
        faltasSomadas += m.faltas
        guard pulosSomados + faltasSomadas > 0, Date().timeIntervalSince(ultimoRegistroDoAudio) >= 10 else { return }
        logAudio.notice("trancos no som da chamada: \(self.pulosSomados) pulo(s), \(self.faltasSomadas) falta(s); fila \(Int(m.filaMs)) ms; microfone \(self.micAtual?.nome ?? "?", privacy: .public)")
        pulosSomados = 0
        faltasSomadas = 0
        ultimoRegistroDoAudio = Date()
    }

    // MARK: painel e ilha

    @objc private func clicouNoIcone() {
        guard let botao = item.button else { return }
        if let p = pipe { medirAudio(p) }
        atualizarEstado()
        painel.alternar(de: botao)
    }

    /// O que os botões do painel e da ilha fazem.
    private func ligarAcoes() {
        estado.alternarFiltro = { [weak self] in self?.alternarFiltro() }
        estado.definirTranscricao = { [weak self] ligado in self?.definirTranscricaoDaChamada(ligado) }
        estado.definirPadrao = { [weak self] ligado in
            guard let self, ligado != self.transcrever else { return }
            self.alternarTranscricao()
            self.atualizarEstado()
        }
        estado.definirEco = { [weak self] ligado in
            guard let self else { return }
            self.cancelarEco = ligado
            self.pipe?.ecoLigado.store(ligado, ordering: .relaxed)
            if ligado, let p = self.pipe { self.ligarReferenciaDoEco(p) } else { self.desligarReferenciaDoEco() }
            self.atualizarEstado()
        }
        estado.definirPerguntarQuemFala = { [weak self] ligado in
            guard let self else { return }
            self.perguntarQuemFala = ligado
            // desligada no meio da chamada: some a pergunta (a gravação continua; volta na próxima chamada)
            if !ligado {
                self.quemFala?.parar()
                self.quemFala = nil
            }
            self.atualizarEstado()
        }
        // compilar pesa: no meio de uma chamada, o filtro do microfone poderia engasgar
        estado.atualizar = { [weak self] in
            guard let self, !self.chamadaDetectada else { return }
            self.atualizador.atualizar()
        }
        estado.procurarAtualizacao = { [weak self] in self?.atualizador.procurar(manual: true) }
        estado.responderVoz = { [weak self] grupo, nome in self?.quemFala?.responder(grupo: grupo, nome: nome) }
        estado.recusarVoz = { [weak self] grupo in self?.quemFala?.recusar(grupo: grupo) }
        estado.dispensarVoz = { [weak self] grupo in self?.quemFala?.dispensar(grupo: grupo) }
        estado.escolherMic = { [weak self] uid in
            self?.micEscolhido = uid
            self?.verificar() // troca na hora se estiver em chamada
        }
        estado.definirAbrirAoIniciar = { [weak self] ligado in
            guard (SMAppService.mainApp.status == .enabled) != ligado else { return }
            self?.alternarInicio()
            self?.atualizarEstado()
        }
        estado.abrirTranscricoes = { [weak self] in
            self?.painel.fechar()
            self?.abrirLigacoes()
        }
        estado.nomear = { [weak self] id in
            guard let self, let s = self.escrivao.sessao(id: id) else { return }
            self.painel.fechar()
            self.abrirNomes(s)
        }
        estado.permitirAgenda = { [weak self] in self?.abrirAgenda() }
        estado.permitirAcessibilidade = { [weak self] in self?.abrirAcessibilidade() }
        estado.sair = { NSApp.terminate(nil) }
    }

    /// Passa o estado do app para o painel e a ilha. Roda a cada meio segundo; só publica o que mudou.
    private func atualizarEstado() {
        tiques += 1
        estado.definir(\.problema, problema)
        estado.definir(\.filtroLigado, filtroLigado)
        estado.definir(\.limpando, pipe != nil)
        estado.medidor = pipe?.medidor
        if let m = micAtual { estado.definir(\.microfone, m.nome) }
        if chamadaDetectada {
            let titulo = eventoDaChamada?.titulo ?? (codigoDaChamada != nil ? "Google Meet" : appDaChamada.map { "Chamada no \($0)" } ?? "Chamada")
            estado.definir(\.chamada, .init(titulo: titulo, app: appDaChamada, transcrever: transcreverEsta,
                                            gravandoDesde: transcreverEsta ? sessaoAtual?.inicio : nil, desde: microfoneAbertoEm,
                                            mudo: estadoDoMicrofone))
        } else {
            estado.definir(\.chamada, nil)
        }
        estado.definir(\.transcrevendo, escrivao.emAndamento.map { .init(titulo: $0.titulo, fracao: $0.progresso) })
        estado.definir(\.baixandoModelo, escrivao.baixandoModelo)
        estado.definir(\.erroDeTranscricao, escrivao.ultimoErro)
        estado.definir(\.pendentes, escrivao.pendentes.map { .init(id: $0.id, titulo: $0.titulo, vozes: $0.semNome.count) })
        estado.definir(\.transcreverPadrao, transcrever)
        estado.definir(\.cancelarEco, cancelarEco)
        estado.definir(\.perguntarQuemFala, perguntarQuemFala)
        estado.definir(\.versao, atualizador.versaoAtual)
        estado.definir(\.atualizacao, atualizador.disponivel.map { .init(versao: $0.marca, notas: $0.notas) })
        estado.definir(\.atualizando, atualizador.atualizando)
        estado.definir(\.erroDeAtualizacao, atualizador.erro)
        estado.definir(\.perguntaDeVoz, quemFala?.pergunta)
        estado.definir(\.micEscolhido, micEscolhido)
        estado.definir(\.acessibilidadeLiberada, VigiaDoMudo.permitido)
        // o que custa um pouco mais (disco, agenda, lista de dispositivos) roda com menos frequência
        if tiques % 4 == 1, let p = pipe { medirAudio(p) }
        if tiques % 20 == 1 {
            estado.definir(\.agendaLiberada, agenda.temAcesso)
            estado.definir(\.proximas, agenda.proximas().map { .init(id: $0.id, titulo: $0.titulo, inicio: $0.inicio, fim: $0.fim, link: $0.link) })
            estado.definir(\.recentes, Self.transcricoesRecentes())
            let lista = Audio.microfones()
            estado.definir(\.microfones, lista.map { .init(uid: $0.uid, nome: $0.nome) })
            // fora de chamada, mostra qual microfone o filtro vai usar
            if micAtual == nil {
                estado.definir(\.microfone, (micEscolhido.flatMap { uid in lista.first { $0.uid == uid } } ?? Audio.microfoneAutomatico(lista))?.nome)
            }
            estado.definir(\.abrirAoIniciar, SMAppService.mainApp.status == .enabled)
        }
        ilha.atualizar()
    }

    /// As transcrições dos últimos 7 dias, mais novas primeiro.
    private static func transcricoesRecentes() -> [EstadoDoApp.Arquivo] {
        let limite = Date().addingTimeInterval(-7 * 24 * 3600)
        guard let e = FileManager.default.enumerator(at: Escrivao.pastaLigacoes, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var achados: [EstadoDoApp.Arquivo] = []
        for case let url as URL in e where url.pathExtension == "md" {
            guard let d = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, d > limite else { continue }
            achados.append(.init(titulo: url.deletingPathExtension().lastPathComponent, data: d, url: url))
        }
        return Array(achados.sorted { $0.data > $1.data }.prefix(4))
    }

    @objc private func alternarFiltro() {
        filtroLigado.toggle()
    }

    /// Agenda e gravação do áudio do sistema: pedidas fora de chamada, uma vez.
    private func pedirPermissoesDeTranscricao() {
        agenda.pedirAcesso()
        guard !prefs.bool(forKey: "pediuAudioDoSistema"), !emChamada else { return }
        prefs.set(true, forKey: "pediuAudioDoSistema")
        DispatchQueue.global(qos: .userInitiated).async { CapturaDoSistema.pedirPermissao() }
    }

    /// Padrão para as próximas chamadas; a chamada atual muda pelo aviso ou por "Transcrever esta chamada".
    @objc private func alternarTranscricao() {
        transcrever.toggle()
        if transcrever { pedirPermissoesDeTranscricao() }
    }

    private func abrirNomes(_ s: Sessao) {
        janelaNomes.abrir(s, salvar: { [weak self] titulo, nomes in
            self?.escrivao.nomear(s, titulo: titulo, nomes: nomes)
        }, descartar: { [weak self] in
            self?.escrivao.descartarPendente(s)
        })
    }

    @objc private func abrirLigacoes() {
        try? FileManager.default.createDirectory(at: Escrivao.pastaLigacoes, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Escrivao.pastaLigacoes)
    }

    @objc private func alternarInicio() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alerta = NSAlert()
            alerta.messageText = "Não consegui mudar a abertura automática"
            alerta.informativeText = "\(error.localizedDescription)\n\nFunciona melhor com o app na pasta Aplicativos."
            alerta.runModal()
        }
    }

    @objc private func sair() {
        NSApp.terminate(nil)
    }

    // MARK: avisos

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = info["sessao"] as? String
        let atualizacao = info["atualizacao"] != nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                // aviso de versão nova: abre o painel, onde está o botão de atualizar
                if atualizacao, let botao = self.item.button, !self.painel.aberto {
                    self.painel.alternar(de: botao)
                    return
                }
                guard let id, let s = self.escrivao.sessao(id: id) else { return }
                if !s.semNome.isEmpty, FileManager.default.fileExists(atPath: URL(fileURLWithPath: s.pasta).appendingPathComponent("outros.wav").path) {
                    self.abrirNomes(s)
                } else if let md = s.markdown {
                    NSWorkspace.shared.open(URL(fileURLWithPath: md))
                }
            }
        }
        completionHandler()
    }
}
