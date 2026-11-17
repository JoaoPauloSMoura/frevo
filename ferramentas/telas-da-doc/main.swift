import AppKit
import SwiftUI

// telas-da-doc: desenha as telas do Frevo (painel, ilha, "Quem falou?") com dados inventados, para as imagens da
// documentação. Usa as próprias telas do app, abertas numa janela fora da tela. Uso: telas-da-doc <pasta de saída>
// (scripts/gerar-imagens-da-doc.sh junta tudo).
let saida = URL(fileURLWithPath: CommandLine.arguments[1])
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)

/// Fala de mentira: sílabas (~5 por segundo) em palavras, com pausas; antes do filtro, a mesma fala com ruído de
/// fundo e cliques de teclado.
func medidorFalso(semente: UInt64 = 7) -> Medidor {
    var r = semente
    func aleatorio() -> Float { r = r &* 6364136223846793005 &+ 1442695040888963407; return Float(r >> 33) / Float(1 << 31) }
    let m = Medidor()
    var a = [Float](repeating: 0, count: 480), d = [Float](repeating: 0, count: 480)
    for q in 0..<600 {
        let t = Double(q) / 100
        let palavra = sin(t * 2 * .pi * 0.55) > -0.35 // trechos de fala e pausas
        let silaba = Float(max(0, sin(t * 2 * .pi * 4.6))) * (0.6 + 0.4 * aleatorio())
        let voz: Float = palavra ? 0.22 * silaba + 0.02 : 0
        let ruido: Float = 0.035 + 0.02 * aleatorio() + (aleatorio() > 0.93 ? 0.12 * aleatorio() : 0)
        for i in 0..<480 {
            let s: Float = i % 2 == 0 ? 1 : -1
            a[i] = s * sqrt(voz * voz + ruido * ruido)
            d[i] = s * voz * 0.97
        }
        a.withUnsafeBufferPointer { pa in d.withUnsafeBufferPointer { pd in m.registrar(antes: pa.baseAddress!, depois: pd.baseAddress!, n: 480) } }
    }
    return m
}

@MainActor func fotografar<V: View>(_ vista: V, _ nome: String, tamanho pedido: NSSize? = nil, escala: CGFloat = 2) {
    let host = NSHostingView(rootView: vista.environment(\.colorScheme, .dark))
    let tamanho = pedido ?? host.fittingSize
    host.frame = NSRect(origin: .zero, size: tamanho)
    let w = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: tamanho.width, height: tamanho.height),
                     styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.appearance = NSAppearance(named: .darkAqua)
    w.contentView = host
    w.orderFrontRegardless()
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let px = Int(tamanho.width * escala), py = Int(tamanho.height * escala)
    let ctx = CGContext(data: nil, width: px, height: py, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // a camada desenha com a origem no alto; o contexto de bitmap tem a origem embaixo
    ctx.translateBy(x: 0, y: CGFloat(py))
    ctx.scaleBy(x: escala, y: -escala)
    host.layer!.render(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: saida.appendingPathComponent(nome + ".png"))
    w.orderOut(nil)
    print("\(nome).png  \(px)×\(py)")
}

MainActor.assumeIsolated {
    let agora = Date()
    @MainActor func estadoEmChamada() -> EstadoDoApp {
        let e = EstadoDoApp()
        e.chamada = .init(titulo: "Planejamento da sprint", app: "Zoom", transcrever: true,
                          gravandoDesde: agora.addingTimeInterval(-754), desde: agora.addingTimeInterval(-760), mudo: .aberto)
        e.limpando = true
        e.filtroLigado = true
        e.microfone = "HyperX Cloud III"
        e.cpu = 2.8
        e.medidor = medidorFalso()
        e.versao = "v0.1.0"
        let cal = Calendar.current
        func hora(_ h: Int, _ m: Int) -> Date { cal.date(bySettingHour: h, minute: m, second: 0, of: agora)! }
        e.proximas = [.init(id: "1", titulo: "1:1 com a Marina", inicio: hora(15, 30), fim: hora(16, 0), link: nil),
                      .init(id: "2", titulo: "Revisão de design", inicio: hora(16, 30), fim: hora(17, 0), link: nil)]
        e.recentes = [.init(titulo: "Daily do time", data: agora.addingTimeInterval(-3 * 3600), url: URL(fileURLWithPath: "/a")),
                      .init(titulo: "Entrevista com cliente", data: agora.addingTimeInterval(-26 * 3600), url: URL(fileURLWithPath: "/b")),
                      .init(titulo: "Retrospectiva", data: agora.addingTimeInterval(-50 * 3600), url: URL(fileURLWithPath: "/c"))]
        return e
    }
    @MainActor func painel(_ e: EstadoDoApp) -> some View {
        PainelView(estado: e)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.15)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .padding(1)
    }

    // sombrinha da barra de menu (branca), para a barra de menu de mentira
    fotografar(Image(nsImage: Glifo.sombrinha(lado: 18, marca: .ponto)).renderingMode(.template).foregroundStyle(.white)
                .frame(width: 22, height: 22), "glifo", tamanho: NSSize(width: 22, height: 22))

    // painel em chamada
    let e1 = estadoEmChamada()
    fotografar(painel(e1).fixedSize(), "painel")

    // painel com versão nova, fora de chamada
    let e2 = estadoEmChamada()
    e2.chamada = nil
    e2.limpando = false
    e2.atualizacao = .init(versao: "v0.2.0", notas: "Pergunta na ilha quem está falando\n- A ilha pergunta o nome de cada voz nova durante a chamada.\n- A transcrição sai com os nomes, sem a janela do fim.")
    fotografar(painel(e2).fixedSize(), "painel-atualizacao")

    // ilha
    @MainActor func ilha(_ e: EstadoDoApp, aberta: Bool) -> some View {
        let m = ModeloIlha()
        m.larguraNotch = 186
        m.alturaNotch = 32
        m.aberta = aberta
        return IlhaView(estado: e, modelo: m).frame(width: 440, height: aberta ? 150 : 32)
    }
    fotografar(ilha(estadoEmChamada(), aberta: false), "ilha-fechada", tamanho: NSSize(width: 440, height: 32))
    let mudo = estadoEmChamada()
    mudo.chamada?.mudo = .mudo
    fotografar(ilha(mudo, aberta: false), "ilha-mudo", tamanho: NSSize(width: 440, height: 32))
    fotografar(ilha(estadoEmChamada(), aberta: true), "ilha-aberta", tamanho: NSSize(width: 440, height: 150))
    let p1 = estadoEmChamada()
    p1.perguntaDeVoz = .init(id: 1, grupo: 0, palpite: nil, sugestoes: ["Marina Costa", "Bruno Lima", "Paulo Souza"])
    fotografar(ilha(p1, aberta: true), "ilha-pergunta", tamanho: NSSize(width: 440, height: 150))
    let p2 = estadoEmChamada()
    p2.perguntaDeVoz = .init(id: 2, grupo: 0, palpite: "Gabriela Rocha", sugestoes: [])
    fotografar(ilha(p2, aberta: true), "ilha-palpite", tamanho: NSSize(width: 440, height: 150))

    // janela "Quem falou?"
    func voz(_ id: String, _ rotulo: String, nome: String?, reconhecida: Bool = false, seg: Double, exemplo: String,
             sugestao: String? = nil, motivo: String? = nil) -> Sessao.Voz {
        Sessao.Voz(id: id, rotulo: rotulo, nome: nome, reconhecida: reconhecida, semelhanca: reconhecida ? 0.91 : nil, vetor: [],
                   amostraInicio: 0, amostraFim: 5, exemplo: exemplo, janelas: 12, segundos: seg, sugestao: sugestao, motivo: motivo)
    }
    let s = Sessao(id: "x", titulo: "Planejamento da sprint", inicio: agora, fim: agora, app: "Zoom",
                   convidados: ["Marina Costa", "Bruno Lima", "Gabriela Rocha", "Paulo Souza"],
                   vozes: [voz("v1", "Gabriela Rocha", nome: "Gabriela Rocha", reconhecida: true, seg: 640,
                               exemplo: "Então a ideia é fechar o fluxo de cadastro até quinta e deixar a revisão para sexta."),
                           voz("v2", "Pessoa 1", nome: nil, seg: 410,
                               exemplo: "Eu consigo pegar a parte do back, mas preciso do contrato da API até amanhã.",
                               sugestao: "Marina Costa", motivo: "respondeu 3 vezes quando chamaram “Marina”"),
                           voz("v3", "Pessoa 2", nome: nil, seg: 220,
                               exemplo: "Do lado do design já está tudo no Figma, só falta o estado de erro.",
                               sugestao: "Bruno Lima", motivo: "é o único convidado que ainda não tinha voz")],
                   pasta: "/tmp")
    fotografar(NomesView(sessao: s, reprodutor: Reprodutor(), salvar: { _, _ in }, depois: {}, descartar: {})
                .background(Color(white: 0.17)).fixedSize(), "quem-falou")
}
