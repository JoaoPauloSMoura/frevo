import EventKit

/// Lê o evento da agenda do Mac que está acontecendo agora, para dar nome à transcrição.
final class Agenda {
    private let loja = EKEventStore()

    var temAcesso: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func pedirAcesso() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        loja.requestFullAccessToEvents { _, _ in }
    }

    struct Proxima {
        let id: String
        let titulo: String
        let inicio: Date
        let fim: Date
        let link: URL?
    }

    /// Reuniões das próximas horas (inclusive a que está acontecendo), sem as de dia inteiro, as canceladas e as
    /// que você recusou.
    func proximas(horas: Double = 12, limite: Int = 4) -> [Proxima] {
        guard temAcesso else { return [] }
        let agora = Date()
        let busca = loja.predicateForEvents(withStart: agora.addingTimeInterval(-60 * 60), end: agora.addingTimeInterval(horas * 3600), calendars: nil)
        return loja.events(matching: busca)
            .filter { e in
                !e.isAllDay && e.endDate > agora && e.status != .canceled
                    && e.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limite)
            .map { e in
                Proxima(id: (e.calendarItemIdentifier) + "\(e.startDate.timeIntervalSince1970)",
                        titulo: (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Reunião" : e.title!,
                        inicio: e.startDate, fim: e.endDate, link: Self.link(e))
            }
    }

    /// Link de entrada da reunião (Meet, Zoom ou Teams) no evento.
    static func link(_ e: EKEvent) -> URL? {
        let texto = [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " ")
        let padrao = try! NSRegularExpression(pattern:
            "https://(meet\\.google\\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}|[a-z0-9.-]*zoom\\.us/j/[^\\s\"<>]+|teams\\.microsoft\\.com/l/meetup-join/[^\\s\"<>]+)")
        let ns = texto as NSString
        guard let m = padrao.firstMatch(in: texto, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return URL(string: ns.substring(with: m.range))
    }

    /// O evento da agenda que é esta chamada, ou nil se nenhum bater com segurança.
    /// - Com o código do Meet: só vale o evento que tem esse link. Um evento com outro link de Meet
    ///   nunca é esta chamada (é o caso de uma ligação criada na hora durante outra reunião marcada).
    /// - Sem link para comparar: só vale um evento que começa até 10 minutos antes ou depois da chamada.
    func evento(em data: Date, codigoMeet: String?) -> (titulo: String, convidados: [String])? {
        guard temAcesso else { return nil }
        let busca = loja.predicateForEvents(withStart: data.addingTimeInterval(-3 * 3600),
                                            end: data.addingTimeInterval(3600), calendars: nil)
        let doDia = loja.events(matching: busca).filter { !$0.isAllDay && $0.endDate >= data.addingTimeInterval(-15 * 60) }
        func codigos(_ e: EKEvent) -> [String] {
            LinkDaChamada.codigos(em: [e.url?.absoluteString, e.location, e.notes].compactMap { $0 }.joined(separator: " "))
        }
        var escolhido: EKEvent?
        if let codigoMeet, let e = doDia.first(where: { codigos($0).contains(codigoMeet) }) {
            escolhido = e
        } else {
            let semOutroLink = doDia.filter { codigoMeet == nil || codigos($0).isEmpty }
            escolhido = semOutroLink
                .filter { abs($0.startDate.timeIntervalSince(data)) <= 10 * 60 }
                .min { abs($0.startDate.timeIntervalSince(data)) < abs($1.startDate.timeIntervalSince(data)) }
        }
        guard let e = escolhido else { return nil }
        let convidados = (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p -> String? in
            if let n = p.name, !n.isEmpty, !n.contains("@") { return n }
            // só o e-mail: "maria.silva@empresa.com" vira "Maria Silva"
            guard let usuario = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                .components(separatedBy: "@").first, !usuario.isEmpty else { return nil }
            return usuario.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
                .split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        let titulo = (e.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (titulo.isEmpty ? "Reunião" : titulo, convidados)
    }
}
