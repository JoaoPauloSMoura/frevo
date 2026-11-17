import Foundation

// transcrever: roda o transcritor do app em duas gravações (sua voz e a dos outros), sem precisar de chamada.
// Uso: transcrever --voce a.wav --outros b.wav [--titulo "Daily"] [--livro vozes.json] [--nomear "Pessoa 1=Maria,Pessoa 2=Ana"]

let args = Array(CommandLine.arguments.dropFirst())
func opcao(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

// --ata <pasta>: só reescreve o Markdown de uma chamada a partir do sessao.json (depois de corrigir nomes à mão)
// --nomear "Pessoa 6=Willian": junto com --ata, dá nome a vozes e ensina a memória (se a voz tiver fala suficiente)
if let p = opcao("--ata") {
    guard var s = Sessao.carregar(pasta: URL(fileURLWithPath: p)) else { print("Sessão não encontrada"); exit(1) }
    do {
        if let pares = opcao("--nomear") {
            let livro = LivroDeVozes(url: Modelos.livroDeVozes)
            for par in pares.split(separator: ",") {
                let lados = par.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
                guard lados.count == 2, let i = s.vozes.firstIndex(where: { $0.rotulo == lados[0] }) else { continue }
                s.vozes[i].nome = lados[1]
                let aprende = (s.vozes[i].janelas ?? 0) >= 4
                if aprende { livro.aprender(nome: lados[1], vetor: s.vozes[i].vetor) }
                print("\(lados[0]) → \(lados[1])\(aprende ? " (memória aprendeu)" : "")")
            }
            try livro.salvar()
        }
        if let titulo = opcao("--titulo"), titulo != s.titulo {
            if let antigo = s.markdown { try? FileManager.default.removeItem(atPath: antigo) }
            s.titulo = titulo
            s.markdown = nil
        }
        try s.gravarMarkdown()
        try s.salvar()
        print("salvo em \(s.markdown ?? "?")")
    } catch {
        print("Erro: \(error)")
        exit(1)
    }
    exit(0)
}

// --separar <wav> <saida.json>: só o separador de vozes (quem fala quando), para medir as fronteiras
if let wav = opcao("--separar"), let i = args.firstIndex(of: "--separar"), i + 2 < args.count {
    let x = try Audio16k.ler(URL(fileURLWithPath: wav))
    if let p = opcao("--passo").flatMap(Float.init) {
        let sep = try SeparadorDeVozes(segmentacao: Modelos.segmentacao(), impressao: Modelos.voz(), limiar: Transcritor.limiarSeparacao, passo: p)
        let t = sep.separar(x).map { ["inicio": $0.inicio, "fim": $0.fim, "falante": $0.falante] as [String: Any] }
        try JSONSerialization.data(withJSONObject: t).write(to: URL(fileURLWithPath: args[i + 2]))
    } else {
        let sep = try SeparadorDeVozes(segmentacao: Modelos.segmentacao(), impressao: Modelos.voz(), limiar: Transcritor.limiarSeparacao)
        let t = sep.separar(x).map { ["inicio": $0.inicio, "fim": $0.fim, "falante": $0.falante] as [String: Any] }
        try JSONSerialization.data(withJSONObject: t).write(to: URL(fileURLWithPath: args[i + 2]))
    }
    exit(0)
}

// --sugerir <pasta>: testa as sugestões de nome numa chamada já transcrita (apaga os nomes na memória do
// processo, sugere de novo e compara com os nomes que você deu). Não grava nada.
if let p = opcao("--sugerir") {
    guard var s = Sessao.carregar(pasta: URL(fileURLWithPath: p)) else { print("Sessão não encontrada"); exit(1) }
    // como a transcrição nova faria: vozes grandes da mesma pessoa viram uma (fica a de mais fala)
    let grandes = s.vozes.indices.filter { (s.vozes[$0].segundos ?? .infinity) >= Transcritor.segundosDePessoa && s.vozes[$0].vetor.count != 512 }
    let grupos = Transcritor.juntarMesmaPessoa(grandes, centro: Dictionary(uniqueKeysWithValues: grandes.map { ($0, s.vozes[$0].vetor) }),
                                               maximo: s.convidados.isEmpty ? nil : s.convidados.count)
    var apagar: [Int] = []
    for g in grupos where g.count > 1 {
        let dono = g.max { (s.vozes[$0].segundos ?? 0) < (s.vozes[$1].segundos ?? 0) }!
        print("juntou: " + g.map { s.vozes[$0].nome ?? s.vozes[$0].rotulo }.joined(separator: " + "))
        for i in g where i != dono {
            for k in s.falas.indices where s.falas[k].voz == s.vozes[i].id { s.falas[k].voz = s.vozes[dono].id }
            apagar.append(i)
        }
    }
    for i in apagar.sorted(by: >) { s.vozes.remove(at: i) }
    // falas seguidas da mesma voz viram uma (como sairiam da transcrição)
    var juntas: [Sessao.Fala] = []
    for f in s.falas {
        if var u = juntas.last, u.voz == f.voz, f.inicio - u.fim < 1 { u.texto += " " + f.texto; u.fim = f.fim; juntas[juntas.count - 1] = u } else { juntas.append(f) }
    }
    s.falas = juntas
    var conhecidos: [String] = s.convidados + s.vozes.compactMap(\.nome) + LivroDeVozes(url: Modelos.livroDeVozes).vozes.map(\.nome)
    conhecidos = conhecidos.filter { n in !conhecidos.contains { $0 != n && Chamados.normalizar($0) == Chamados.normalizar(n) } || conhecidos.firstIndex(of: n) == conhecidos.firstIndex { Chamados.normalizar($0) == Chamados.normalizar(n) } }
    for a in Chamados.atendidos(falas: s.falas, conhecidos: conhecidos) {
        let quem = a.voz == "voce" ? "Você" : (s.vozes.first { $0.id == a.voz }.map { $0.nome ?? $0.rotulo } ?? a.voz)
        print("  chamou \(a.nome) → respondeu \(quem): …\(s.falas[a.fala].texto.suffix(90))")
    }
    var vozes = s.vozes
    for i in vozes.indices { vozes[i].nome = nil; vozes[i].sugestao = nil }
    Transcritor.sugerirNomes(&vozes, falas: s.falas, convidados: s.convidados, livro: LivroDeVozes(url: Modelos.livroDeVozes))
    var certas = 0, erradas = 0
    for (v, verdade) in zip(vozes, s.vozes) {
        let ok = v.sugestao.map { sug in verdade.nome.map { Chamados.casar(sug, com: [$0]) != nil || Chamados.casar($0, com: [sug]) != nil } ?? false }
        let marca = verdade.nome == nil || v.sugestao == nil ? "" : ok == true ? "  ✓" : "  ✗"
        if marca == "  ✓" { certas += 1 } else if marca == "  ✗" { erradas += 1 }
        print("\(verdade.rotulo) (\(verdade.nome ?? "sem nome"), \(Int(verdade.segundos ?? 0)) s): \(v.sugestao.map { "\($0) — \(v.motivo ?? "")" } ?? "-")\(marca)")
    }
    print("certas \(certas), erradas \(erradas), de \(s.vozes.count) vozes")
    exit(0)
}

// --ao-vivo <pasta>: toca a trilha dos outros de uma chamada gravada no detector de quem fala, como se fosse ao
// vivo, e responde às perguntas com os nomes que você deu nela. Mede quantas perguntas a ilha faria e quanto do
// tempo de fala sairia com o nome certo. --sem-memoria: como se ninguém fosse conhecido. Não grava nada.
if let p = opcao("--ao-vivo") {
    let pasta = URL(fileURLWithPath: p)
    guard let s = Sessao.carregar(pasta: pasta), let outros = try? Audio16k.ler(pasta.appendingPathComponent("outros.wav")),
          let imp = try? ImpressaoDeVoz(modelo: Modelos.voz()) else { print("Sessão, áudio ou modelo não encontrado"); exit(1) }
    if let l = opcao("--limiar-grupo").flatMap(Float.init) { QuemFala.limiarGrupo = l }
    if let l = opcao("--limiar-juntar").flatMap(Float.init) { QuemFala.limiarJuntar = l }
    let livro = args.contains("--sem-memoria") ? LivroDeVozes(url: URL(fileURLWithPath: "/dev/null")) : LivroDeVozes(url: Modelos.livroDeVozes)
    let q = QuemFala(livro: livro, convidados: s.convidados) { imp }
    func verdade(_ t: Double) -> String? {
        let tv = t + s.atrasoOutros
        return s.falas.first { $0.voz != "voce" && $0.inicio - 0.2 <= tv && tv <= $0.fim + 0.2 }.map { s.nome(da: $0.voz) }
    }
    var vista = 0
    var perguntas = 0
    let passo = 4000 // 0,25 s, como chega da gravação
    let limite = opcao("--minutos").flatMap(Double.init).map { Int($0 * 60 * 16000) } ?? outros.count
    for ini in stride(from: 0, to: min(limite, outros.count), by: passo) {
        outros[ini..<min(outros.count, ini + passo)].withUnsafeBufferPointer { q.receber($0) }
        q.esperar()
        guard let pg = q.pergunta, pg.id != vista else { continue }
        vista = pg.id
        perguntas += 1
        let t = Double(ini + passo) / 16000
        let quem = verdade(t - 1)
        let texto = pg.palpite.map { "Quem está falando é \($0)?" } ?? "Quem está falando?"
        let parecidas = q.parecidas(pg.grupo).prefix(2).map { String(format: "%@ %.2f", $0.nome, $0.semelhanca) }.joined(separator: ", ")
        var resposta: String
        if let pal = pg.palpite, let quem, Chamados.normalizar(pal) == Chamados.normalizar(quem) {
            q.responder(grupo: pg.grupo, nome: quem); resposta = "Sim"
        } else if pg.palpite != nil {
            q.recusar(grupo: pg.grupo); resposta = "Não"
        } else if let quem, args.contains("--responder-tudo") || !quem.hasPrefix("Pessoa"), quem != "Outros" {
            q.responder(grupo: pg.grupo, nome: quem); resposta = quem
        } else {
            q.dispensar(grupo: pg.grupo); resposta = "(fechou)"
        }
        print("[\(Ata.tempo(t))] \(texto) → \(resposta)   (falava: \(quem ?? "?"); parecida com: \(parecidas); botões: \(pg.sugestoes.joined(separator: ", ")))")
    }
    q.esperar()
    var certo = 0.0, errado = 0.0, semMarca = 0.0
    let marcas = q.marcas()
    for m in marcas {
        guard let v = verdade((m.inicio + m.fim) / 2) else { continue }
        if Chamados.normalizar(v) == Chamados.normalizar(m.nome) { certo += 1 } else { errado += 1 }
    }
    // tempo de fala dos outros que ficou sem marca nenhuma
    var falaOutros = 0.0
    for f in s.falas where f.voz != "voce" {
        falaOutros += f.fim - f.inicio
        let marcado = marcas.contains { min(f.fim, $0.fim + s.atrasoOutros) > max(f.inicio, $0.inicio + s.atrasoOutros) }
        if !marcado { semMarca += f.fim - f.inicio }
    }
    let dur = Double(outros.count) / 16000
    print(String(format: "\n%d perguntas em %.0f min · janelas marcadas: %.0f certas, %.0f erradas (%.0f%% certas) · fala dos outros sem marca: %.0f%% · impressões: %.1f s de CPU (%.2f%% do tempo)",
                 perguntas, dur / 60, certo, errado, 100 * certo / max(1, certo + errado), 100 * semMarca / max(1, falaOutros),
                 q.tempoDeImpressao, 100 * q.tempoDeImpressao / dur))
    exit(0)
}

// --sessao <pasta>: retranscreve uma chamada gravada pelo app e reescreve o Markdown e o sessao.json dela
if let p = opcao("--sessao") {
    let pasta = URL(fileURLWithPath: p)
    guard var s = Sessao.carregar(pasta: pasta), let modelo = Modelos.whisper() else {
        print("Sessão ou modelo não encontrado")
        exit(1)
    }
    do {
        let livro = LivroDeVozes(url: Modelos.livroDeVozes)
        let t = try Transcritor.criar(whisper: modelo, livro: livro)
        let voce = (try? Audio16k.ler(pasta.appendingPathComponent("voce.wav"))) ?? []
        let outros = (try? Audio16k.ler(pasta.appendingPathComponent("outros.wav"))) ?? []
        let antiga = s
        let r = t.transcrever(voce: voce, outros: outros, atrasoOutros: s.atrasoOutros, mudo: s.mudo ?? [], convidados: s.convidados)
        s.falas = r.falas
        s.vozes = r.vozes
        // --herdar-nomes: cada voz nova sem nome herda o nome que a transcrição anterior dava aos mesmos trechos,
        // se um nome cobrir 70%+ deles (e 20 s+); a memória aprende a voz com o modelo atual
        if args.contains("--herdar-nomes") {
            for i in s.vozes.indices where s.vozes[i].nome == nil {
                var porNome: [String: Double] = [:]
                var total = 0.0
                for f in s.falas where f.voz == s.vozes[i].id {
                    for g in antiga.falas where g.voz != "voce" {
                        let sobra = min(f.fim, g.fim) - max(f.inicio, g.inicio)
                        guard sobra > 0 else { continue }
                        total += sobra
                        if let n = antiga.vozes.first(where: { $0.id == g.voz })?.nome { porNome[n, default: 0] += sobra }
                    }
                }
                guard let (nome, d) = porNome.max(by: { $0.value < $1.value }), d >= 20, d / max(total, 1) >= 0.7 else { continue }
                print("herdou: \(s.vozes[i].rotulo) → \(nome) (\(Int(d)) s, \(Int(100 * d / total))%)")
                s.vozes[i].nome = nome
                if (s.vozes[i].janelas ?? 0) >= 4 { livro.aprender(nome: nome, vetor: s.vozes[i].vetor) }
            }
            try livro.salvar()
        }
        if let titulo = opcao("--titulo"), titulo != s.titulo {
            if let antigo = s.markdown { try? FileManager.default.removeItem(atPath: antigo) }
            s.titulo = titulo
            s.markdown = nil
        }
        // --sem-salvar: só mostra (para testar sem mexer na transcrição, no Markdown nem na memória)
        if args.contains("--sem-salvar") {
            print(Ata.markdown(s))
            print("---- vozes (convidados: \(s.convidados.joined(separator: ", ")))")
            for v in s.vozes {
                let antes = Set(antiga.falas.filter { f in s.falas.contains { $0.voz == v.id && min($0.fim, f.fim) > max($0.inicio, f.inicio) } }
                    .compactMap { f in antiga.vozes.first { $0.id == f.voz }.map { $0.nome ?? $0.rotulo } })
                print("\(v.id) \(v.rotulo): nome=\(v.nome ?? "-") sugestão=\(v.sugestao ?? "-") (\(v.motivo ?? "")) · \(Int(v.segundos ?? 0)) s · antes: \(antes.sorted().joined(separator: ", "))")
            }
            exit(0)
        }
        try s.gravarMarkdown()
        try s.salvar()
        print(Ata.markdown(s))
        print("salvo em \(s.markdown ?? "?")")
    } catch {
        print("Erro: \(error)")
        exit(1)
    }
    exit(0)
}

guard let voceArq = opcao("--voce"), let outrosArq = opcao("--outros") else {
    print("Uso: transcrever --voce a.wav --outros b.wav [--titulo X] [--livro vozes.json] [--nomear \"Pessoa 1=Maria\"]")
    print("     transcrever --sessao <pasta de uma chamada gravada pelo app>")
    exit(1)
}
if let l = opcao("--limiar").flatMap(Float.init) { Transcritor.limiarSeparacao = l }
if args.contains("--sem-dtw") { Whisper.usarDTW = false }
if let p = opcao("--passo").flatMap(Float.init) { Transcritor.passoSeparador = p }
if let n = opcao("--palavras-para-trocar").flatMap(Int.init) { Transcritor.palavrasParaTrocar = n }
if let l = opcao("--limiar-memoria").flatMap(Float.init) { Transcritor.limiarMemoria = l }

do {
    guard let modeloWhisper = Modelos.whisper() else { print("Modelo do Whisper não encontrado"); exit(1) }
    let t0 = Date()
    let livro = LivroDeVozes(url: URL(fileURLWithPath: opcao("--livro") ?? Modelos.livroDeVozes.path))
    let transcritor = try Transcritor.criar(whisper: modeloWhisper, livro: livro)
    let voce = try Audio16k.ler(URL(fileURLWithPath: voceArq))
    let outros = try Audio16k.ler(URL(fileURLWithPath: outrosArq))
    let (falas, vozes) = transcritor.transcrever(voce: voce, outros: outros)
    let duracao = Double(max(voce.count, outros.count)) / 16000

    var sessao = Sessao(id: UUID().uuidString, titulo: opcao("--titulo") ?? "Teste", inicio: Date(),
                        fim: Date().addingTimeInterval(duracao), app: "teste", falas: falas, vozes: vozes, pasta: "")

    // nomear vozes novas e ensinar a memória
    if let pares = opcao("--nomear") {
        for par in pares.split(separator: ",") {
            let lados = par.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            guard lados.count == 2, let i = sessao.vozes.firstIndex(where: { $0.rotulo == lados[0] }) else { continue }
            sessao.vozes[i].nome = lados[1]
            livro.aprender(nome: lados[1], vetor: sessao.vozes[i].vetor)
        }
        try livro.salvar()
    }

    // --falas <arquivo>: grava as falas em JSON (início, fim, texto, quem), para comparar com outra transcrição
    if let arq = opcao("--falas") {
        let lista = sessao.falas.map { ["inicio": $0.inicio, "fim": $0.fim, "texto": $0.texto, "quem": sessao.nome(da: $0.voz)] as [String: Any] }
        try JSONSerialization.data(withJSONObject: lista, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: arq))
    }
    print(Ata.markdown(sessao))
    print("---- vozes")
    for v in sessao.vozes {
        let s = v.semelhanca.map { String(format: " (memória: %.2f)", $0) } ?? ""
        print("\(v.id): \(v.nome ?? v.rotulo)\(s) · amostra \(Ata.tempo(v.amostraInicio))–\(Ata.tempo(v.amostraFim))")
    }
    // semelhança entre os grupos, para calibrar o limiar
    for (i, a) in sessao.vozes.enumerated() {
        for b in sessao.vozes[(i + 1)...] {
            print(String(format: "%@ × %@: %.2f", a.id, b.id, Vozes.semelhanca(a.vetor, b.vetor)))
        }
    }
    print(String(format: "tempo=%.1fs para %.0fs de áudio", Date().timeIntervalSince(t0), duracao))
} catch {
    print("Erro: \(error)")
    exit(1)
}
