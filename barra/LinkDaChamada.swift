import Foundation

/// Descobre o código da reunião do Google Meet (abc-defg-hij) aberta no navegador que está na chamada,
/// para achar o evento da agenda com o mesmo link. Pede uma vez a permissão "controlar o navegador".
/// Bloqueia enquanto o macOS espera essa resposta: chame em segundo plano.
enum LinkDaChamada {
    private static let navegadores: [String: String] = [
        "Google Chrome": "Google Chrome", "Microsoft Edge": "Microsoft Edge", "Brave Browser": "Brave Browser",
        "Arc": "Arc", "Safari": "Safari",
    ]

    static func codigoMeet(app: String?) -> String? {
        guard let app, let nome = navegadores[app] else { return nil }
        let script = nome == "Safari"
            ? "tell application \"Safari\" to get URL of every tab of every window"
            : "tell application \"\(nome)\" to get URL of every tab of every window"
        var erro: NSDictionary?
        guard let resultado = NSAppleScript(source: script)?.executeAndReturnError(&erro), erro == nil else { return nil }
        let texto = urls(resultado).joined(separator: " ")
        return codigos(em: texto).first
    }

    /// Todos os códigos de Meet num texto (link do evento, descrição, local).
    static func codigos(em texto: String) -> [String] {
        let padrao = try! NSRegularExpression(pattern: "meet\\.google\\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})")
        let ns = texto as NSString
        return padrao.matches(in: texto, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    private static func urls(_ d: NSAppleEventDescriptor) -> [String] {
        if d.numberOfItems == 0 { return d.stringValue.map { [$0] } ?? [] }
        return (1...d.numberOfItems).flatMap { d.atIndex($0).map(urls) ?? [] }
    }
}
