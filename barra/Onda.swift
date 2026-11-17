import AppKit
import QuartzCore
import SwiftUI

/// Escala de volume para as barras: -60 dB (silêncio) até -10 dB (voz forte perto do microfone).
private func altura(_ rms: Float) -> CGFloat {
    let db = 20 * log10(max(rms, 1e-6))
    return CGFloat(min(1, max(0, (db + 60) / 50)))
}

/// Barras desenhadas direto em camadas do Core Animation, atualizadas por um relógio próprio só enquanto estão
/// na tela. Medido: com o SwiftUI redesenhando a 24 quadros por segundo, a ilha fechada custava 8–10% de um núcleo;
/// mudar a altura de camadas custa quase nada.
final class VistaDeBarras: NSView {
    enum Modo {
        /// O som atravessando o filtro: entra pela esquerda como o microfone ouviu, cruza a linha do meio e sai
        /// pela direita como a chamada recebe. Cada barra é um pedaço de `quadrosPorBarra` × 10 ms.
        case fluxo(barras: Int, quadrosPorBarra: Int)
        /// Poucas barrinhas que pulam com a sua voz já limpa (ilha fechada).
        case aoVivo(barras: Int)
    }

    var medidor: Medidor?
    var filtroLigado = true {
        didSet { if filtroLigado != oldValue { linha?.backgroundColor = (filtroLigado ? corSaida : corEntrada).cgColor } }
    }
    private let modo: Modo
    private let fps: Double
    private let corEntrada: NSColor
    private let corSaida: NSColor
    private var barras: [CALayer] = []
    private var linha: CALayer?
    /// Componentes RGBA das duas cores, para misturar uma na outra no funil.
    private let rgbaEntrada: [CGFloat]
    private let rgbaSaida: [CGFloat]
    private var relogio: Timer?

    init(modo: Modo, corEntrada: NSColor, corSaida: NSColor, fps: Double) {
        self.modo = modo
        self.fps = fps
        self.corEntrada = corEntrada
        self.corSaida = corSaida
        func rgba(_ c: NSColor) -> [CGFloat] {
            let d = c.usingColorSpace(.deviceRGB) ?? .gray
            return [d.redComponent, d.greenComponent, d.blueComponent, d.alphaComponent]
        }
        rgbaEntrada = rgba(corEntrada)
        rgbaSaida = rgba(corSaida)
        super.init(frame: .zero)
        wantsLayer = true
        let n: Int
        switch modo {
        case .fluxo(let b, _): n = b + 1 // uma a mais: a que está entrando pela borda
        case .aoVivo(let b): n = b
        }
        for _ in 0..<n {
            let c = CALayer()
            c.backgroundColor = corSaida.cgColor
            layer?.addSublayer(c)
            barras.append(c)
        }
        if case .fluxo = modo {
            let l = CALayer()
            l.backgroundColor = corSaida.cgColor
            layer?.addSublayer(l)
            linha = l
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        relogio?.invalidate()
        relogio = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 1 / fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.desenhar() }
        }
        RunLoop.main.add(t, forMode: .common)
        relogio = t
        desenhar()
    }

    override func layout() {
        super.layout()
        desenhar()
    }

    private func desenhar() {
        guard window?.isVisible == true else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch modo {
        case .fluxo(let n, let q): desenharFluxo(n: n, q: q)
        case .aoVivo(let n): desenharAoVivo(n: n)
        }
    }

    private func desenharFluxo(n: Int, q: Int) {
        let w = bounds.width, h = bounds.height, meio = h / 2, centro = w / 2
        let passo = w / CGFloat(n)
        // a linha do filtro, no meio, mais alta que tudo
        linha?.frame = CGRect(x: centro - 1.5, y: 0, width: 3, height: h)
        linha?.cornerRadius = 1.5

        let lido = medidor?.janela((n + 1) * q)
        let pares = lido?.pares ?? []
        let total = lido?.total ?? 0
        guard total > 0 else {
            for b in barras { b.frame = .zero }
            return
        }
        // pedaço (grupo de q quadros) mais novo e quanto dele já chegou: a onda anda essa fração de um passo
        let atual = (total - 1) / q
        let fase = CGFloat((total - 1) % q + 1) / CGFloat(q)
        let primeiro = total - pares.count // quadro absoluto de pares[0]
        for s in 0...n {
            let camada = barras[s]
            // idade s: 0 = o pedaço que está entrando pela esquerda
            let x = (CGFloat(s) + fase) * passo - passo / 2
            let ini = (atual - s) * q - primeiro, fim = ini + q
            guard x > -passo, x < w + passo, fim > 0, ini < pares.count else {
                camada.frame = .zero
                continue
            }
            var a: Float = 0, d: Float = 0
            for p in pares[max(0, ini)..<min(pares.count, fim)] {
                a = max(a, p.antes)
                d = max(d, p.depois)
            }
            // perto da linha não desenha (ela fica sozinha, como na referência)
            if abs(x - centro) < passo * 0.6 {
                camada.frame = .zero
                continue
            }
            // Funil: no último quinto antes da linha a barra vai afinando, passa do cinza ao verde e troca o volume
            // do microfone pelo limpo aos poucos; a altura aperta na direção da linha e reabre do outro lado.
            let zona = w * 0.2
            let f = x >= centro ? 1 : Self.suave(max(0, 1 - (centro - x) / zona))
            let gargalo = 0.35 + 0.65 * Self.suave(min(1, abs(x - centro) / zona))
            let h0 = altura(a) + (altura(d) - altura(a)) * f
            let bw = max(1, passo * (0.5 - 0.22 * f))
            let bh = max(2 - 0.5 * f, h0 * gargalo * meio)
            let cor = filtroLigado ? f : 0 // filtro desligado: sai do jeito que entrou, cinza
            let c = (0..<4).map { rgbaEntrada[$0] + (rgbaSaida[$0] - rgbaEntrada[$0]) * cor }
            camada.backgroundColor = CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
            camada.frame = CGRect(x: x - bw / 2, y: meio - bh, width: bw, height: 2 * bh)
            camada.cornerRadius = bw / 2
        }
    }

    /// Curva suave de 0 a 1 (começa e termina devagar).
    private static func suave(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    private func desenharAoVivo(n: Int) {
        let w = bounds.width, h = bounds.height
        let pares = medidor?.ultimos(n * 5) ?? []
        let bw: CGFloat = 3, folga: CGFloat = 2.5
        var x = (w - (CGFloat(n) * bw + CGFloat(n - 1) * folga)) / 2
        for i in 0..<n {
            // cada barra olha um pedaço diferente dos últimos 200 ms, para não subirem juntas
            let fatia = pares.isEmpty ? [] : pares[(i * 5)..<min(pares.count, i * 5 + 5)]
            let v = fatia.map(\.depois).max() ?? 0
            let bh = max(3, altura(v) * h)
            barras[i].frame = CGRect(x: x, y: (h - bh) / 2, width: bw, height: bh)
            barras[i].cornerRadius = 1.5
            x += bw + folga
        }
    }
}

/// O som atravessando o filtro, de verdade: entra pela esquerda como o seu microfone ouve (cinza), cruza a linha
/// do filtro e sai pela direita como a chamada recebe (verde). Na fala a barra segue quase do mesmo tamanho; onde
/// era só ruído, ela some ao cruzar a linha.
struct OndaAntesDepois: NSViewRepresentable {
    let medidor: Medidor?
    var filtroLigado = true
    var barras = 40
    /// Quadros de 10 ms por barra: 12 = 120 ms; 40 barras = 4,8 s de som atravessando a tela (mais rápido
    /// que isso ficava agitado).
    var quadrosPorBarra = 12
    /// cinza claro translúcido: aparece no fundo escuro do painel e da ilha
    var corEntrada = NSColor(white: 0.78, alpha: 0.55)
    var corSaida = NSColor(red: 0.30, green: 0.80, blue: 0.62, alpha: 1)

    func makeNSView(context: Context) -> VistaDeBarras {
        let v = VistaDeBarras(modo: .fluxo(barras: barras, quadrosPorBarra: quadrosPorBarra),
                              corEntrada: corEntrada, corSaida: corSaida, fps: 30)
        v.setAccessibilityLabel("Sua voz atravessando o filtro: à esquerda como o microfone ouve, à direita como a chamada recebe")
        return v
    }

    func updateNSView(_ v: VistaDeBarras, context: Context) {
        v.medidor = medidor
        v.filtroLigado = filtroLigado
    }
}

/// Barrinhas que pulam com a sua voz já limpa, para a ilha do notch.
struct BarrasAoVivo: NSViewRepresentable {
    let medidor: Medidor?
    var cor = NSColor(red: 0.36, green: 0.79, blue: 0.65, alpha: 1)

    func makeNSView(context: Context) -> VistaDeBarras {
        let v = VistaDeBarras(modo: .aoVivo(barras: 4), corEntrada: .clear, corSaida: cor, fps: 15)
        v.setAccessibilityLabel("Sua voz, depois do filtro")
        return v
    }

    func updateNSView(_ v: VistaDeBarras, context: Context) { v.medidor = medidor }
}

/// Ponto vermelho pulsando (está gravando). A animação roda no Core Animation, fora do app: não gasta CPU dele.
struct PontoGravando: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 7, height: 7))
        v.wantsLayer = true
        let ponto = CALayer()
        ponto.frame = CGRect(x: 0, y: 0, width: 7, height: 7)
        ponto.cornerRadius = 3.5
        ponto.backgroundColor = NSColor(red: 0.89, green: 0.29, blue: 0.29, alpha: 1).cgColor
        let pulso = CABasicAnimation(keyPath: "opacity")
        pulso.fromValue = 1
        pulso.toValue = 0.35
        pulso.duration = 0.7
        pulso.autoreverses = true
        pulso.repeatCount = .infinity
        pulso.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        ponto.add(pulso, forKey: "pulso")
        v.layer?.addSublayer(ponto)
        v.setAccessibilityLabel("Gravando")
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {}
}

/// Quanto ruído o filtro está tirando: compara antes e depois só nos momentos sem fala (os 40% mais baixos dos
/// últimos 6 s), onde o que o microfone ouve é o ruído de fundo. Na fala os dois lados quase não mudam.
struct RuidoTirado: View {
    let medidor: Medidor?
    /// Só o número ("−29 dB"), para caber embaixo da linha do filtro.
    var curto = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(texto).monospacedDigit()
        }
    }

    private var texto: String {
        guard let pares = medidor?.ultimos(600), !pares.isEmpty else { return "" }
        let fundo = pares.sorted { $0.antes < $1.antes }.prefix(pares.count * 4 / 10).filter { $0.antes > 0.0018 } // > -55 dB
        guard fundo.count >= 20 else { return curto ? "" : "ambiente em silêncio" }
        let ea = fundo.reduce(Float(0)) { $0 + $1.antes * $1.antes }
        let ed = fundo.reduce(Float(0)) { $0 + $1.depois * $1.depois }
        let db = 10 * log10(ea / max(ed, 1e-12))
        if curto { return db < 3 ? "0 dB" : String(format: "−%.0f dB", db) }
        return db < 3 ? "sem ruído agora" : String(format: "−%.0f dB de ruído", db)
    }
}
