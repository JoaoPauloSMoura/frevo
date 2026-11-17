import AppKit
import WebKit
// foto-html: desenha uma página HTML num PNG, em resolução dupla, com o WebKit do macOS.
// Uso: foto-html pagina.html saida.png largura altura (em pontos)
let a = CommandLine.arguments
let pagina = URL(fileURLWithPath: a[1]), saida = URL(fileURLWithPath: a[2])
let w = CGFloat(Double(a[3])!), h = CGFloat(Double(a[4])!)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
final class Fim: NSObject, WKNavigationDelegate {
    let pronto: () -> Void
    init(_ f: @escaping () -> Void) { pronto = f }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pronto() }
}
var fim: Fim?
MainActor.assumeIsolated {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h))
    web.setValue(false, forKey: "drawsBackground")
    let j = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
    j.contentView = web
    j.isOpaque = false
    j.backgroundColor = .clear
    j.orderFrontRegardless()
    fim = Fim {
        Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { _ in
            MainActor.assumeIsolated {
                let c = WKSnapshotConfiguration()
                c.rect = NSRect(x: 0, y: 0, width: w, height: h)
                c.snapshotWidth = NSNumber(value: Double(w)) // em pontos: a tela de 2x dobra os pixels
                web.takeSnapshot(with: c) { img, erro in
                    guard let img, let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("falhou: \(String(describing: erro))"); exit(1) }
                    try! NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: saida)
                    print("\(saida.lastPathComponent): \(cg.width)×\(cg.height)")
                    exit(0)
                }
            }
        }
    }
    web.navigationDelegate = fim
    // a página lê as telas de build/telas, fora da pasta dela
    web.loadFileURL(pagina, allowingReadAccessTo: URL(fileURLWithPath: "/"))
}
app.run()
