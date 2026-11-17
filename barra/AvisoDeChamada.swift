import AppKit
import SwiftUI

/// O que o aviso mostra. A janela observa; o controlador muda.
@MainActor
final class EstadoAviso: ObservableObject {
    @Published var titulo = "Chamada"
    @Published var subtitulo = "Frevo"
    @Published var icone: NSImage?
    @Published var transcrever = true
    var aoMudar: (Bool) -> Void = { _ in }
    var aoFechar: () -> Void = {}
    var aoPassarMouse: (Bool) -> Void = { _ in }
}

/// Aviso que aparece ao entrar numa chamada, logo abaixo do ícone na barra de menu, com o interruptor
/// "Transcrever esta chamada". Não tira o foco do Meet/Zoom e some sozinho depois de alguns segundos;
/// a escolha continua valendo e dá para mudar depois pelo menu.
@MainActor
final class AvisoDeChamada {
    private var painel: NSPanel?
    private let estado = EstadoAviso()
    private var sumir: DispatchWorkItem?
    private var mouseDentro = false
    private static let largura: CGFloat = 330
    private static let tempoNaTela: TimeInterval = 12

    var aberto: Bool { painel?.isVisible == true }

    /// `ancora`: moldura do ícone na barra de menu (coordenadas de tela), para o aviso aparecer logo abaixo dele.
    func mostrar(titulo: String, subtitulo: String, icone: NSImage?, transcrever: Bool, ancora: NSRect?,
                 aoMudar: @escaping (Bool) -> Void) {
        estado.titulo = titulo
        estado.subtitulo = subtitulo
        estado.icone = icone
        estado.transcrever = transcrever
        estado.aoMudar = { [weak self] ligado in
            aoMudar(ligado)
            self?.agendarSumico() // mexeu: dá mais tempo para ver o resultado
        }
        estado.aoFechar = { [weak self] in self?.fechar() }
        estado.aoPassarMouse = { [weak self] dentro in
            self?.mouseDentro = dentro
            if !dentro { self?.agendarSumico() }
        }

        let p = painel ?? criarPainel()
        painel = p
        p.contentView?.layoutSubtreeIfNeeded()
        let tamanho = p.contentView?.fittingSize ?? NSSize(width: Self.largura, height: 120)
        p.setFrame(Self.posicao(tamanho: tamanho, ancora: ancora), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        p.invalidateShadow()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.18
            p.animator().alphaValue = 1
        }
        agendarSumico()
    }

    func atualizar(titulo: String? = nil, subtitulo: String? = nil, transcrever: Bool? = nil) {
        if let titulo { estado.titulo = titulo }
        if let subtitulo { estado.subtitulo = subtitulo }
        if let transcrever { estado.transcrever = transcrever }
    }

    func fechar() {
        sumir?.cancel()
        sumir = nil
        mouseDentro = false
        guard let p = painel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { p.orderOut(nil) }
        })
    }

    private func agendarSumico() {
        sumir?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.mouseDentro { return } // sai quando o mouse sair (aoPassarMouse reagenda)
            self.fechar()
        }
        sumir = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tempoNaTela, execute: item)
    }

    private func criarPainel() -> NSPanel {
        let p = PainelAviso(contentRect: NSRect(x: 0, y: 0, width: Self.largura, height: 120),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true

        // fundo translúcido do sistema (claro/escuro), com cantos arredondados
        let fundo = NSVisualEffectView()
        fundo.material = .popover
        fundo.blendingMode = .behindWindow
        fundo.state = .active
        fundo.maskImage = Self.mascara(raio: 14)
        let host = HostAviso(rootView: AvisoView(estado: estado))
        host.translatesAutoresizingMaskIntoConstraints = false
        fundo.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fundo.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fundo.trailingAnchor),
            host.topAnchor.constraint(equalTo: fundo.topAnchor),
            host.bottomAnchor.constraint(equalTo: fundo.bottomAnchor),
        ])
        p.contentView = fundo
        return p
    }

    /// Logo abaixo do ícone da barra, alinhado à direita dele; sem ícone visível, no canto superior direito da tela.
    private static func posicao(tamanho: NSSize, ancora: NSRect?) -> NSRect {
        let tela = NSScreen.screens.first { ancora.map($0.frame.intersects) ?? false } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = tela.visibleFrame
        var x: CGFloat
        var y: CGFloat
        if let a = ancora, a.width > 0 {
            x = a.maxX - tamanho.width + 10
            y = a.minY - tamanho.height - 6
        } else {
            x = area.maxX - tamanho.width - 12
            y = area.maxY - tamanho.height - 8
        }
        x = min(max(x, area.minX + 8), area.maxX - tamanho.width - 8)
        y = min(y, area.maxY - tamanho.height - 4)
        return NSRect(x: x, y: y, width: tamanho.width, height: tamanho.height)
    }

    private static func mascara(raio: CGFloat) -> NSImage {
        let lado = raio * 2 + 1
        let img = NSImage(size: NSSize(width: lado, height: lado), flipped: false) { r in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: r, xRadius: raio, yRadius: raio).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: raio, left: raio, bottom: raio, right: raio)
        img.resizingMode = .stretch
        return img
    }
}

/// Painel que pode receber cliques e teclado sem ativar o app (o foco continua na chamada).
private final class PainelAviso: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// O primeiro clique já liga/desliga o interruptor, mesmo com a janela inativa.
final class HostAviso<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct AvisoView: View {
    @ObservedObject var estado: EstadoAviso

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if let i = estado.icone {
                        Image(nsImage: i).resizable().interpolation(.high)
                    } else {
                        Image(systemName: "phone.circle.fill").resizable().foregroundStyle(.green)
                    }
                }
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(estado.titulo)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(estado.subtitulo)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { estado.aoFechar() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Fechar o aviso (a escolha continua valendo)")
                .accessibilityLabel("Fechar o aviso")
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcrever esta chamada")
                        .font(.system(size: 13, weight: .medium))
                    Text(estado.transcrever
                         ? "Gravando para transcrever no fim.\nFica só neste Mac."
                         : "Nada desta chamada é gravado.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Transcrever esta chamada", isOn: Binding(
                    get: { estado.transcrever },
                    set: { estado.transcrever = $0; estado.aoMudar($0) }))
                    .toggleStyle(Interruptor())
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.06)))
        }
        .padding(14)
        .frame(width: 330)
        .onHover { estado.aoPassarMouse($0) }
    }
}

/// Interruptor desenhado à mão: o do sistema fica cinza (mesmo ligado) numa janela que não está ativa,
/// e este aviso nunca fica ativo para não tirar o foco da chamada.
struct Interruptor: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let ligado = configuration.isOn
        return Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(ligado ? Color.accentColor : Color.primary.opacity(0.2))
                .frame(width: 38, height: 22)
                .overlay(alignment: ligado ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: ligado)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Transcrever esta chamada")
        .accessibilityValue(ligado ? "ligado" : "desligado")
        .help(ligado ? "Desligar: apaga o que já foi gravado desta chamada" : "Ligar: grava a partir de agora")
    }
}
