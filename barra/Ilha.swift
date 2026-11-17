import AppKit
import SwiftUI

/// A ilha em volta do notch do MacBook (no estilo do Alcove): mostra de relance se o filtro está limpando,
/// se está gravando e se você está no mudo; com o mouse em cima, abre com a chamada e os atalhos, ou com as
/// próximas reuniões. Fora de chamada fica escondida, a não ser perto de uma reunião.
///
/// Só existe na tela do MacBook (a que tem notch). Sem notch (tampa fechada, monitor externo), quem avisa é o
/// painel da barra de menu e o aviso de chamada.
@MainActor
final class Ilha {
    private let estado: EstadoDoApp
    private let modelo = ModeloIlha()
    private var janela: NSPanel?
    private var hover: Timer?
    private var fecharEm: Date?
    private var abertaAte: Date?
    private var perguntaAberta: Int?

    /// Largura e altura máximas (ilha aberta); a janela tem sempre esse tamanho e a ilha cresce dentro dela.
    private static let largura: CGFloat = 420
    private static let alturaAberta: CGFloat = 118

    init(estado: EstadoDoApp) {
        self.estado = estado
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposicionar() }
        }
    }

    /// Existe tela com notch? (sem ela, a ilha não aparece)
    var disponivel: Bool { Self.telaComNotch() != nil }

    /// Chamado a cada meio segundo pelo controlador: mostra ou esconde conforme o estado.
    func atualizar() {
        let visivel = disponivel && (estado.chamada != nil || estado.transcrevendo != nil || estado.reuniaoEmBreve != nil)
        if visivel {
            if janela == nil { criar() }
            if janela?.isVisible == false {
                reposicionar()
                janela?.orderFrontRegardless()
            }
            if hover == nil {
                hover = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.acompanharMouse() }
                }
            }
            // pergunta de quem está falando: a ilha abre sozinha e fica aberta enquanto ela existir
            let p = estado.perguntaDeVoz?.id
            if p != perguntaAberta {
                perguntaAberta = p
                if p != nil {
                    abertaAte = .distantFuture
                    definirAberta(true)
                } else {
                    if abertaAte == .distantFuture { abertaAte = Date().addingTimeInterval(1.5) }
                    devolverFoco()
                }
            }
        } else if janela?.isVisible == true {
            hover?.invalidate()
            hover = nil
            // a próxima chamada começa do zero (as perguntas dela também começam do número 1)
            perguntaAberta = nil
            abertaAte = nil
            devolverFoco()
            modelo.aberta = false
            janela?.ignoresMouseEvents = true
            janela?.orderOut(nil)
        }
    }

    /// Abre a ilha por alguns segundos sozinha (ex.: no começo da chamada, com o interruptor de transcrever).
    func abrirPorAlgunsSegundos(_ s: TimeInterval = 8) {
        guard disponivel else { return }
        atualizar()
        abertaAte = Date().addingTimeInterval(s)
        definirAberta(true)
    }

    // MARK: janela

    private func criar() {
        let p = PainelSemFoco(contentRect: NSRect(x: 0, y: 0, width: Self.largura, height: Self.alturaAberta + 40),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // acima da barra de menu, para cobrir o notch
        p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = HostAviso(rootView: IlhaView(estado: estado, modelo: modelo))
        janela = p
        reposicionar()
    }

    private func reposicionar() {
        guard let tela = Self.telaComNotch(), let janela else { return }
        let f = tela.frame
        let alturaNotch = tela.safeAreaInsets.top
        let esquerda = tela.auxiliaryTopLeftArea?.width ?? (f.width / 2 - 100)
        let direita = tela.auxiliaryTopRightArea?.width ?? (f.width / 2 - 100)
        modelo.larguraNotch = max(120, f.width - esquerda - direita)
        modelo.alturaNotch = alturaNotch
        let altura = alturaNotch + Self.alturaAberta
        // cabe a ilha aberta com os ombros, mesmo num notch mais largo
        let largura = max(Self.largura, modelo.larguraAberta + 2 * ModeloIlha.ombroAberta + 8)
        janela.setFrame(NSRect(x: f.midX - largura / 2, y: f.maxY - altura, width: largura, height: altura), display: true)
    }

    private static func telaComNotch() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
    }

    // MARK: mouse

    /// Retângulo (em coordenadas de tela) da ilha como está agora.
    private func area(aberta: Bool) -> NSRect {
        guard let j = janela else { return .zero }
        let f = j.frame
        let w = aberta ? modelo.larguraAberta : modelo.larguraFechada
        let h = aberta ? modelo.alturaNotch + Self.alturaAberta : modelo.alturaNotch
        return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    private func acompanharMouse() {
        let m = NSEvent.mouseLocation
        if area(aberta: modelo.aberta).insetBy(dx: -6, dy: -6).contains(m) {
            fecharEm = nil
            if abertaAte != .distantFuture { abertaAte = nil } // o mouse assumiu: só fecha quando ele sair
            if !modelo.aberta { definirAberta(true) }
            return
        }
        if estado.perguntaDeVoz != nil && modelo.aberta { return } // com pergunta aberta, não fecha
        if let ate = abertaAte {
            if Date() < ate { return }
            abertaAte = nil
        }
        guard modelo.aberta else { return }
        if let f = fecharEm {
            if Date() >= f {
                fecharEm = nil
                definirAberta(false)
            }
        } else {
            fecharEm = Date().addingTimeInterval(0.35)
        }
    }

    /// Depois de digitar um nome, o teclado volta para o app da chamada (o painel não pode ficar com ele:
    /// o atalho de mudo do Meet, por exemplo, viria parar aqui).
    private func devolverFoco() {
        guard let j = janela, j.isKeyWindow else { return }
        j.orderOut(nil)
        j.orderFrontRegardless()
    }

    private func definirAberta(_ aberta: Bool) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { modelo.aberta = aberta }
        // fechada, a ilha não pega cliques (a barra de menu embaixo continua funcionando)
        janela?.ignoresMouseEvents = !aberta
    }
}

/// Geometria e estado de abertura da ilha.
@MainActor
final class ModeloIlha: ObservableObject {
    @Published var aberta = false
    @Published var larguraNotch: CGFloat = 200
    @Published var alturaNotch: CGFloat = 32
    let orelha: CGFloat = 74
    /// Curva côncava no topo, de cada lado, por fora da largura (ver `FormaIlha`).
    static let ombroFechada: CGFloat = 6
    static let ombroAberta: CGFloat = 10
    var larguraFechada: CGFloat { larguraNotch + 2 * orelha }
    var larguraAberta: CGFloat { max(380, larguraNotch + 2 * orelha) }
}

/// Painel que recebe cliques sem ativar o app (o foco continua na chamada).
private final class PainelSemFoco: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// O contorno do notch de verdade, só que mais largo: preso no topo, com "ombros" côncavos onde encosta na borda
/// da tela (a borda curva para fora antes de descer, sem canto vivo) e cantos de baixo contínuos (a curva começa
/// antes e entra mais suave que um quarto de círculo, como os cantos do hardware). Os ombros ficam fora do corpo:
/// o retângulo desenhado tem o corpo mais um `ombro` de cada lado.
private struct FormaIlha: Shape {
    var ombro: CGFloat
    var raio: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ombro, raio) }
        set { ombro = newValue.first; raio = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let s = min(ombro, r.height / 2)
        let esq = r.minX + s, dir = r.maxX - s // laterais do corpo
        // canto contínuo: num quarto de círculo a curva ocupa 1 × o raio de cada lado; aqui ocupa 1,28 × e as alças
        // são mais longas, então ela começa antes e entra mais suave na reta
        let e = max(0, min(raio * 1.28, (dir - esq) / 2, r.height - s))
        let k: CGFloat = 0.64
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: dir, y: r.minY + s), control: CGPoint(x: dir, y: r.minY)) // ombro direito
        p.addLine(to: CGPoint(x: dir, y: r.maxY - e))
        p.addCurve(to: CGPoint(x: dir - e, y: r.maxY),
                   control1: CGPoint(x: dir, y: r.maxY - e + k * e),
                   control2: CGPoint(x: dir - e + k * e, y: r.maxY))
        p.addLine(to: CGPoint(x: esq + e, y: r.maxY))
        p.addCurve(to: CGPoint(x: esq, y: r.maxY - e),
                   control1: CGPoint(x: esq + e - k * e, y: r.maxY),
                   control2: CGPoint(x: esq, y: r.maxY - e + k * e))
        p.addLine(to: CGPoint(x: esq, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: esq, y: r.minY)) // ombro esquerdo
        p.closeSubpath()
        return p
    }
}

private let verdeIlha = Color(red: 0.36, green: 0.79, blue: 0.65)
private let verdeIlhaNS = NSColor(red: 0.36, green: 0.79, blue: 0.65, alpha: 1)
private let laranja = Color(red: 0.94, green: 0.62, blue: 0.15)

struct IlhaView: View {
    @ObservedObject var estado: EstadoDoApp
    @ObservedObject var modelo: ModeloIlha

    private var largura: CGFloat { modelo.aberta ? modelo.larguraAberta : modelo.larguraFechada }
    private var altura: CGFloat { modelo.aberta ? modelo.alturaNotch + 118 : modelo.alturaNotch }
    private var ombro: CGFloat { modelo.aberta ? ModeloIlha.ombroAberta : ModeloIlha.ombroFechada }

    var body: some View {
        ZStack(alignment: .top) {
            FormaIlha(ombro: ombro, raio: modelo.aberta ? 22 : 10)
                .fill(Color.black)
            VStack(spacing: 0) {
                faixaDoNotch.frame(height: modelo.alturaNotch)
                if modelo.aberta {
                    conteudoAberto
                        .padding(.horizontal, 18)
                        .padding(.bottom, 12)
                        .transition(.opacity)
                }
            }
            .frame(width: largura) // o conteúdo fica no corpo, nunca embaixo dos ombros
        }
        .frame(width: largura + 2 * ombro, height: altura)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: fechada: as "orelhas" de cada lado do notch

    private var faixaDoNotch: some View {
        HStack(spacing: 0) {
            orelhaEsquerda.frame(width: modelo.orelha)
            Spacer(minLength: modelo.larguraNotch)
            orelhaDireita.frame(width: modelo.orelha)
        }
        .frame(width: largura)
    }

    @ViewBuilder private var orelhaEsquerda: some View {
        if estado.chamada?.mudo == .mudo {
            Image(systemName: "mic.slash.fill").font(.system(size: 12)).foregroundStyle(laranja)
        } else if estado.limpando && estado.filtroLigado {
            BarrasAoVivo(medidor: estado.medidor, cor: verdeIlhaNS).frame(width: 26, height: 16)
        } else if estado.limpando {
            Image(systemName: "waveform.slash").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if estado.transcrevendo != nil {
            Image(systemName: "text.bubble").font(.system(size: 12)).foregroundStyle(Color(red: 0.69, green: 0.66, blue: 0.93))
        } else if estado.reuniaoEmBreve != nil {
            Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var orelhaDireita: some View {
        if let desde = estado.chamada?.gravandoDesde {
            HStack(spacing: 5) {
                PontoGravando().frame(width: 7, height: 7)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(EstadoDoApp.tempo(desde: desde)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                }
            }
            .foregroundStyle(.white)
        } else if let c = estado.chamada {
            // em chamada sem gravar: anel cinza vazio no lugar do ponto vermelho, com o tempo da chamada
            HStack(spacing: 5) {
                Circle().strokeBorder(Color.white.opacity(0.45), lineWidth: 1.2).frame(width: 7, height: 7)
                if let desde = c.desde {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(EstadoDoApp.tempo(desde: desde)).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    }
                } else {
                    Text("sem gravar").font(.system(size: 11))
                }
            }
            .foregroundStyle(Color.white.opacity(0.55))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sem gravar esta chamada")
            .help("Esta chamada não está sendo gravada")
        } else if let t = estado.transcrevendo {
            Text("\(Int(t.fracao * 100))%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                .foregroundStyle(Color(red: 0.81, green: 0.80, blue: 0.96))
        } else if let r = estado.reuniaoEmBreve {
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                Text(EstadoDoApp.falta(ate: r.inicio)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: aberta

    @ViewBuilder private var conteudoAberto: some View {
        if let p = estado.perguntaDeVoz {
            PerguntaDeVoz(pergunta: p,
                          responder: { estado.responderVoz(p.grupo, $0) },
                          recusar: { estado.recusarVoz(p.grupo) },
                          dispensar: { estado.dispensarVoz(p.grupo) })
                .id(p.id) // pergunta nova, campo vazio
        } else if let c = estado.chamada {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(c.titulo).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if c.mudo == .mudo {
                        Label("No mudo", systemImage: "mic.slash.fill").font(.system(size: 11)).foregroundStyle(laranja)
                    }
                }
                if estado.limpando {
                    OndaAntesDepois(medidor: estado.medidor, filtroLigado: estado.filtroLigado,
                                    corEntrada: NSColor(white: 1, alpha: 0.42), corSaida: verdeIlhaNS)
                        .frame(height: 30)
                }
                HStack(spacing: 8) {
                    Chip(titulo: "Filtro", ligado: estado.filtroLigado) { estado.alternarFiltro() }
                    Chip(titulo: "Transcrever", ligado: c.transcrever) { estado.definirTranscricao(!c.transcrever) }
                    Spacer()
                    if estado.filtroLigado && estado.limpando {
                        RuidoTirado(medidor: estado.medidor).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
        } else if let t = estado.transcrevendo {
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcrevendo “\(t.titulo)”").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                ProgressView(value: t.fracao).tint(Color(red: 0.69, green: 0.66, blue: 0.93))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(estado.proximas.prefix(2)) { r in
                    HStack(spacing: 8) {
                        Text(r.inicio, format: .dateTime.hour().minute()).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Text(r.titulo).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        if let link = r.link, r.naHora {
                            Button("Entrar") { NSWorkspace.shared.open(link) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        } else {
                            Text(EstadoDoApp.falta(ate: r.inicio)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// "Quem está falando?" na ilha: com palpite da memória, Sim ou Não; sem palpite, um campo para o nome e os
/// convidados que ainda não têm voz, para responder com um clique.
private struct PerguntaDeVoz: View {
    let pergunta: QuemFala.Pergunta
    let responder: (String) -> Void
    let recusar: () -> Void
    let dispensar: () -> Void
    @State private var nome = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.wave.2.fill").font(.system(size: 12)).foregroundStyle(verdeIlha)
                Text(pergunta.palpite.map { "Quem está falando é \($0)?" } ?? "Quem está falando?")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button(action: dispensar) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Agora não")
                .accessibilityLabel("Agora não")
            }
            if let palpite = pergunta.palpite {
                HStack(spacing: 8) {
                    Botao(titulo: "Sim, é \(palpite)", destaque: true) { responder(palpite) }
                    Botao(titulo: "Não", destaque: false, acao: recusar)
                    Spacer()
                }
                Text("Uma vez por pessoa: a transcrição sai com os nomes.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    TextField("Nome de quem está falando", text: $nome)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.1)))
                        .onSubmit { if !nome.trimmingCharacters(in: .whitespaces).isEmpty { responder(nome) } }
                    Botao(titulo: "OK", destaque: true) { if !nome.trimmingCharacters(in: .whitespaces).isEmpty { responder(nome) } }
                }
                if !pergunta.sugestoes.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(pergunta.sugestoes.prefix(3), id: \.self) { s in
                            Botao(titulo: s, destaque: false) { responder(s) }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

private struct Botao: View {
    let titulo: String
    let destaque: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            Text(titulo).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(destaque ? verdeIlha.opacity(0.85) : Color.white.opacity(0.1)))
                .foregroundStyle(destaque ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}

/// Botão-pílula da ilha aberta (filtro, transcrever).
private struct Chip: View {
    let titulo: String
    let ligado: Bool
    let acao: () -> Void

    var body: some View {
        Button(action: acao) {
            HStack(spacing: 5) {
                Circle().fill(ligado ? verdeIlha : Color.white.opacity(0.3)).frame(width: 6, height: 6)
                Text(titulo).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(ligado ? 0.14 : 0.07)))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityValue(ligado ? "ligado" : "desligado")
    }
}
