import Foundation

/// Quem atende quando é chamado pelo nome: alguém termina a fala com "…, Marina?" e logo em seguida OUTRA voz
/// começa. Cada vez que isso acontece é um voto de que aquela voz é a Marina. Se a mesma voz continua falando,
/// o chamado não conta (ninguém atendeu ainda).
///
/// Medido numa reunião de produto de 46 min, com os nomes conferidos à mão: uns 2 de cada 3 chamados são atendidos
/// pela pessoa chamada; os erros caem espalhados, então vale o nome com mais votos em cada voz.
enum Chamados {
    struct Sugestao: Equatable {
        let nome: String
        let votos: Int
    }

    /// Palavras que, logo antes do nome, mostram que se fala DA pessoa, não COM ela ("como a Marina falou").
    private static let deTerceiro: Set<String> = ["o", "a", "os", "as", "do", "da", "no", "na", "pro", "pra", "pelo", "pela",
                                                 "com", "ao", "de", "que", "e", "para", "sobre", "entre", "seu", "sua", "tipo"]
    /// Palavras que começam uma frase com maiúscula e não são nome ("Beleza?", "Pronto,").
    private static let naoNomes: Set<String> = ["beleza", "pronto", "certo", "exato", "isso", "entao", "bom", "tipo", "sim", "nao",
                                               "ok", "show", "perfeito", "legal", "enfim", "olha", "gente", "pessoal", "galera",
                                               "obrigado", "obrigada", "valeu", "oi", "ola", "ei", "fala", "agora", "depois",
                                               "aqui", "ali", "la", "ai", "ne", "viu", "sabe", "entendi", "claro", "verdade",
                                               "pix", "crm", "api", "ia", "ok", "tchau", "opa", "uai", "cara", "mano", "turma"]
    /// Palavras depois do nome, no máximo, para o chamado contar como o fim da fala (a pergunta está no fim).
    private static let palavrasDepois = 10
    /// Segundos, no máximo, entre o fim da fala com o chamado e o começo da resposta.
    private static let respostaEm = 3.0

    static func normalizar(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    /// Nome conhecido que a palavra dita representa: igual ao primeiro nome, com uma letra de diferença
    /// ("Tiago" e "Thiago") ou o começo dele, a partir de 3 letras ("Gabi" e "Gabriela").
    static func casar(_ dita: String, com conhecidos: [String]) -> String? {
        let d = normalizar(dita).replacingOccurrences(of: " ", with: "")
        guard d.count >= 3 else { return nil }
        var parcial: String?
        for c in conhecidos {
            let partes = normalizar(c).split(separator: " ").map(String.init)
            guard let primeiro = partes.first else { continue }
            if d == primeiro || d == partes.joined() { return c }
            if primeiro.count >= 5 && d.count >= 4 && distancia(d, primeiro) <= 1 { return c }
            if parcial == nil && d.count >= 3 && d.count < primeiro.count && primeiro.hasPrefix(d) { parcial = c }
        }
        return parcial
    }

    /// Nomes chamados numa fala, perto do fim dela: "…, Marina?", "Paulo?", "Mas, Bruno, quando…", "viu, Gabi?".
    /// `conhecidos`: convidados, nomes da memória e da chamada. Um nome fora da lista só conta no padrão mais
    /// claro (", Juca?"), com maiúscula no meio da frase.
    static func chamados(em texto: String, conhecidos: [String]) -> [String] {
        let palavras = texto.split(separator: " ").map(String.init)
        var achados: [String] = []
        for (i, bruta) in palavras.enumerated() {
            let letras = bruta.filter { $0.isLetter || $0 == "-" }
            guard let primeira = letras.first, primeira.isUppercase, letras.count >= 3,
                  !letras.allSatisfy({ $0.isUppercase }) else { continue }
            let chave = normalizar(letras)
            if naoNomes.contains(chave) { continue }
            let fim = bruta.last.map { "?,.!".contains($0) } ?? false
            guard fim || i == palavras.count - 1 else { continue }
            guard palavras.count - 1 - i <= palavrasDepois else { continue }
            var antes = true // começo da fala ou depois de uma pausa da frase
            var depoisDeVirgula = false
            if i > 0 {
                let ant = palavras[i - 1]
                let antChave = normalizar(ant)
                if deTerceiro.contains(antChave) { continue }
                depoisDeVirgula = ant.last == ","
                antes = depoisDeVirgula || ant.last.map { ".?!".contains($0) } ?? false
            }
            guard antes else { continue }
            if let c = casar(letras, com: conhecidos) {
                achados.append(c)
            } else if depoisDeVirgula && bruta.last.map({ "?,".contains($0) }) == true {
                // nome que o app ainda não conhece, no padrão claro do meio da frase (", Juca?")
                achados.append(letras.prefix(1).uppercased() + letras.dropFirst().lowercased())
            }
        }
        return achados
    }

    /// Cada chamado atendido: o nome chamado, a voz que respondeu e a fala com o chamado. Vale só o último nome
    /// da fala ("tem mais algum ponto, Carla? É isso mesmo. Paulo?": quem responde é o Paulo).
    static func atendidos(falas: [Sessao.Fala], conhecidos: [String]) -> [(nome: String, voz: String, fala: Int)] {
        var saida: [(nome: String, voz: String, fala: Int)] = []
        for (i, f) in falas.enumerated() where i + 1 < falas.count {
            let prox = falas[i + 1]
            guard prox.voz != f.voz, prox.inicio - f.fim <= respostaEm else { continue }
            if let nome = chamados(em: f.texto, conhecidos: conhecidos).last { saida.append((nome, prox.voz, i)) }
        }
        return saida
    }

    /// Nome provável de cada voz dos outros (id → sugestão), pelos chamados atendidos.
    /// Cada nome vai para uma voz só (a que mais atendeu por ele). Nomes atendidos mais por você que pelos
    /// outros são seus (seus apelidos) e ficam de fora. Um nome que o app não conhece (fora dos convidados
    /// e da memória) precisa de 2 votos: com um só, pode ser palavra que o Whisper ouviu errado.
    static func sugerir(falas: [Sessao.Fala], conhecidos: [String]) -> [String: Sugestao] {
        var votos: [String: [String: Int]] = [:] // voz → nome → votos
        var porVoce: [String: Int] = [:]
        for a in atendidos(falas: falas, conhecidos: conhecidos) {
            if a.voz == "voce" {
                porVoce[a.nome, default: 0] += 1
            } else if a.voz != "outros" {
                votos[a.voz, default: [:]][a.nome, default: 0] += 1
            }
        }
        // pares (voz, nome) do mais votado ao menos; cada voz e cada nome entram uma vez
        var pares: [(voz: String, nome: String, n: Int)] = []
        for (voz, nomes) in votos {
            for (nome, n) in nomes where n > porVoce[nome, default: 0] && (n >= 2 || casar(nome, com: conhecidos) != nil) {
                // o nome precisa ganhar com folga dos outros votos da mesma voz
                let outros = nomes.filter { $0.key != nome }.map(\.value).max() ?? 0
                if n >= 2 * outros && n > outros { pares.append((voz, nome, n)) }
            }
        }
        pares.sort { $0.n != $1.n ? $0.n > $1.n : $0.nome < $1.nome }
        var saida: [String: Sugestao] = [:]
        var usados = Set<String>()
        for p in pares where saida[p.voz] == nil && !usados.contains(p.nome) {
            saida[p.voz] = Sugestao(nome: p.nome, votos: p.n)
            usados.insert(p.nome)
        }
        return saida
    }

    private static func distancia(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        var linha = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var anterior = linha[0]
            linha[0] = i
            for j in 1...max(1, y.count) where !y.isEmpty {
                let guardado = linha[j]
                linha[j] = min(linha[j] + 1, linha[j - 1] + 1, anterior + (x[i - 1] == y[j - 1] ? 0 : 1))
                anterior = guardado
            }
        }
        return linha[y.count]
    }
}
