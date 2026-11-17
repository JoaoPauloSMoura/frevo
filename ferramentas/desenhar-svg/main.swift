import AppKit
import WebKit

// desenhar-svg: desenha um SVG num PNG quadrado com fundo transparente, usando o WebKit do macOS
// (o mesmo motor do Safari: filtros, máscaras e gradientes saem como no navegador).
// Uso: desenhar-svg entrada.svg saida.png [lado em pixels, padrão 1024]

let args = CommandLine.arguments
guard args.count >= 3, let svg = try? String(contentsOfFile: args[1], encoding: .utf8) else {
    FileHandle.standardError.write("uso: desenhar-svg entrada.svg saida.png [lado]\n".data(using: .utf8)!)
    exit(1)
}
let lado = args.count > 3 ? Int(args[3]) ?? 1024 : 1024
let saida = URL(fileURLWithPath: args[2])

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

MainActor.assumeIsolated {
    // a tela tem o tamanho do SVG em pontos; a foto sai em pixels exatos
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    web.setValue(false, forKey: "drawsBackground")
    let janela = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1024, height: 1024), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    janela.contentView = web
    janela.backgroundColor = .clear
    janela.isOpaque = false
    janela.orderFrontRegardless()
    let html = """
    <html><head><style>html,body{margin:0;background:transparent}svg{display:block;width:1024px;height:1024px}</style></head>
    <body>\(svg)</body></html>
    """
    web.loadHTMLString(html, baseURL: nil)

    func fotografar() {
        let conf = WKSnapshotConfiguration()
        conf.rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
        web.takeSnapshot(with: conf) { imagem, erro in
            guard let imagem, let cg = imagem.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("falhou: \(String(describing: erro))"); exit(1)
            }
            // redesenha no tamanho pedido, com alfa
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: lado, pixelsHigh: lado, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext(bitmapImageRep: rep)!
            ctx.imageInterpolation = .high
            NSGraphicsContext.current = ctx
            ctx.cgContext.clear(CGRect(x: 0, y: 0, width: lado, height: lado))
            ctx.cgContext.draw(cg, in: CGRect(x: 0, y: 0, width: lado, height: lado))
            NSGraphicsContext.restoreGraphicsState()
            try! rep.representation(using: .png, properties: [:])!.write(to: saida)
            print("\(saida.path): \(lado)×\(lado) (foto do WebKit: \(cg.width)×\(cg.height))")
            exit(0)
        }
    }
    // espera o WebKit terminar de desenhar (filtros de desfoque levam um instante)
    Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in MainActor.assumeIsolated { fotografar() } }
}
app.run()
