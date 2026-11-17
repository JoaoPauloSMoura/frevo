import Foundation

/// Quem está falando agora, ao vivo, pela trilha dos outros de uma chamada gravada.
///
/// A cada 1,5 s de fala, uma impressão de voz dos últimos 3 s. Impressões parecidas formam um grupo (uma pessoa);
/// um grupo novo, depois de uns 6 s de fala, vira uma pergunta na ilha: "Quem está falando é Gabriela?" quando a memória de vozes
/// tem um palpite, "Quem está falando?" quando não tem. O que você responde marca os trechos daquela voz, e a
/// transcrição do fim da chamada usa essas marcas para dar nome às pessoas sem precisar perguntar de novo.
///
/// `receber` vem da thread da gravação; o resto roda na fila própria. As leituras (`pergunta`, `marcas`) são
/// seguras de qualquer thread.
final class QuemFala: @unchecked Sendable {
    struct Pergunta: Equatable {
        /// Muda a cada pergunta nova (a ilha usa para saber que é outra).
        let id: Int
        let grupo: Int
        /// Nome que a memória acha que é (nil: não faz ideia).
        let palpite: String?
        /// Convidados que ainda não têm voz, para responder com um clique.
        let sugestoes: [String]
    }

    private struct Grupo {
        var soma: [Float]
        var janelas = 0
        var nome: String?
        var recusados: Set<String> = []
        var perguntas = 0
        var perguntadoEm: Double = -.infinity
        var palpite: String?
        var centro: [Float] { Vozes.normalizar(soma) }
    }

    private struct Janela {
        let inicio: Double
        let fim: Double
        var grupo: Int
    }

    // calibrado em reuniões gravadas (ferramentas/transcrever --ao-vivo)
    /// Semelhança mínima de uma janela de 3 s com o centro de um grupo para entrar nele.
    static var limiarGrupo: Float = 0.5
    /// Dois grupos com centros parecidos assim são a mesma pessoa (partida no começo, com pouca fala).
    static var limiarJuntar: Float = 0.75
    /// Janelas (de 1,5 s de passo) que um grupo precisa antes de virar pergunta: ~6 s de fala.
    static var janelasParaPerguntar = 4
    /// Janelas para a memória arriscar um palpite.
    static var janelasParaPalpite = 4
    static var limiarPalpite: Float = 0.7
    /// Semelhança com uma voz já nomeada nesta chamada para perguntar "é Fulano?" em vez de "quem é?".
    static var limiarPalpiteNaChamada: Float = 0.65
    /// Intervalo mínimo entre uma pergunta e a próxima (s).
    static var intervalo: Double = 30
    /// Perguntas por chamada: 2 por convidado, no mínimo 6. Numa chamada em que as vozes saem embaralhadas
    /// (sala com microfone de mesa, por exemplo), o detector partia a mesma pessoa e perguntava de novo a cada
    /// poucos segundos; o resto fica para a janela de nomes do fim.
    private var maximoDePerguntas: Int { max(6, 2 * convidados.count) }

    private let impressao: () -> ImpressaoDeVoz?
    private let livro: LivroDeVozes
    private let fila = DispatchQueue(label: "io.github.joaopaulosmoura.frevo.quemfala", qos: .utility)
    private let trava = NSLock()

    // só na fila
    private var modelo: ImpressaoDeVoz?
    private var audio: [Float] = []   // os últimos segundos, 16 kHz
    private var inicioDoAudio = 0     // amostra (na linha do tempo da trilha) do audio[0]
    private var total = 0             // amostras recebidas desde o começo
    private var proximaJanela = 0     // amostra em que cabe a próxima janela
    private var niveis: [Float] = []  // volume (dB) dos últimos quadros de 30 ms, para o piso de ruído
    private var grupos: [Grupo] = []
    private var janelas: [Janela] = []
    private var convidados: [String] = []
    private var atual: Pergunta?
    private var contador = 0
    private var feitas = 0                  // perguntas sobre vozes novas (o "Não" não conta)
    private var proximaEm: Double = 0       // segundos na trilha: antes disso, nenhuma pergunta nova
    private(set) var tempoDeImpressao: Double = 0 // segundos gastos com impressões (para medir o custo)

    init(livro: LivroDeVozes, convidados: [String], impressao: @escaping () -> ImpressaoDeVoz?) {
        self.livro = livro
        self.convidados = convidados
        self.impressao = impressao
    }

    /// Pergunta para mostrar agora (nil: nenhuma).
    var pergunta: Pergunta? {
        trava.lock()
        defer { trava.unlock() }
        return atual
    }

    func definirConvidados(_ c: [String]) { fila.async { self.convidados = c } }

    private var parado = false // protegido pela trava

    /// Para de analisar (a pergunta foi desligada nos ajustes no meio da chamada).
    func parar() {
        trava.lock()
        parado = true
        atual = nil
        trava.unlock()
    }

    /// Áudio de 16 kHz da trilha dos outros, na ordem e no ritmo em que é gravado (silêncio incluído).
    func receber(_ x: UnsafeBufferPointer<Float>) {
        trava.lock()
        let p = parado
        trava.unlock()
        guard !p else { return }
        let copia = Array(x)
        fila.async { self.alimentar(copia) }
    }

    /// Sua resposta: é esta pessoa.
    func responder(grupo: Int, nome: String) {
        fila.async {
            let n = nome.trimmingCharacters(in: .whitespaces)
            guard self.grupos.indices.contains(grupo), !n.isEmpty else { return }
            self.grupos[grupo].nome = n
            // outro grupo com o mesmo nome é a mesma pessoa partida em dois: junta
            for (i, g) in self.grupos.enumerated() where i != grupo && g.janelas > 0
                && g.nome.map({ Chamados.normalizar($0) == Chamados.normalizar(n) }) == true { self.juntar(i, em: grupo) }
            self.fechar(grupo)
        }
    }

    /// Sua resposta: não é quem a memória achou. Vira "Quem está falando?" para a mesma voz.
    func recusar(grupo: Int) {
        fila.async {
            guard self.grupos.indices.contains(grupo) else { return }
            if let p = self.grupos[grupo].palpite { self.grupos[grupo].recusados.insert(p) }
            self.grupos[grupo].palpite = nil
            self.perguntar(grupo, agora: self.segundos(self.total))
        }
    }

    /// Você fechou sem responder: só pergunta de novo por aquela voz daqui a uns 5 min (pode ser um vídeo, ou
    /// alguém que você não sabe quem é).
    func dispensar(grupo: Int) {
        fila.async {
            guard self.grupos.indices.contains(grupo) else { return }
            self.grupos[grupo].perguntadoEm = self.segundos(self.total) + 240
            self.fechar(grupo)
        }
    }

    /// Segundos da trilha dos outros que já existiam quando o detector começou (o começo da chamada que estava
    /// na memória quando você ligou a transcrição). Somado aos horários das marcas.
    var deslocamento: Double = 0

    /// Trechos (segundos na trilha dos outros) de cada voz que você nomeou.
    func marcas() -> [Sessao.Marca] {
        let d = deslocamento
        return fila.sync {
            janelas.compactMap { j in grupos[j.grupo].nome.map { Sessao.Marca(inicio: j.inicio + d, fim: j.fim + d, nome: $0) } }
        }
    }

    /// Semelhança do centro de um grupo com cada voz já nomeada (para calibrar).
    func parecidas(_ g: Int) -> [(nome: String, semelhanca: Float, janelas: Int)] {
        fila.sync {
            guard grupos.indices.contains(g) else { return [] }
            return grupos.enumerated().compactMap { i, h in
                guard i != g, h.janelas > 0, let n = h.nome else { return nil }
                return (n, Vozes.semelhanca(grupos[g].centro, h.centro), grupos[g].janelas)
            }.sorted { $0.semelhanca > $1.semelhanca }
        }
    }

    /// Espera o que já chegou ser processado (para os testes).
    func esperar() { fila.sync {} }

    // MARK: análise (na fila)

    private static let sr = 16000
    private static let quadro = 480        // 30 ms
    private static let tamJanela = 48000   // 3 s
    private static let passo = 24000       // 1,5 s

    private func segundos(_ amostra: Int) -> Double { Double(amostra) / Double(Self.sr) }

    private func alimentar(_ x: [Float]) {
        audio += x
        total += x.count
        // volume de cada quadro novo
        let novos = x.count / Self.quadro
        for q in 0..<novos {
            var s: Float = 0
            for k in 0..<Self.quadro { let v = x[q * Self.quadro + k]; s += v * v }
            niveis.append(10 * log10(s / Float(Self.quadro) + 1e-12))
        }
        if niveis.count > 4000 { niveis.removeFirst(niveis.count - 4000) } // 2 min
        while total >= proximaJanela + Self.tamJanela {
            analisar(ate: proximaJanela + Self.tamJanela)
            proximaJanela += Self.passo
        }
        // guarda só os últimos 4 s
        let sobra = audio.count - 4 * Self.sr
        if sobra > 0 {
            audio.removeFirst(sobra)
            inicioDoAudio += sobra
        }
        atualizarPergunta()
    }

    private func analisar(ate fim: Int) {
        let ini = fim - Self.tamJanela
        let a = ini - inicioDoAudio, z = fim - inicioDoAudio
        guard a >= 0, z <= audio.count else { return }
        // fala em pelo menos 60% da janela (pelo volume, acima do piso de ruído dos últimos 2 min)
        let ordenados = niveis.sorted()
        let piso = ordenados.isEmpty ? -100 : ordenados[ordenados.count / 10]
        let limiar = max(-50, piso + 12)
        var ativos = 0, quadros = 0
        var k = a
        while k + Self.quadro <= z {
            var s: Float = 0
            for i in k..<(k + Self.quadro) { s += audio[i] * audio[i] }
            if 10 * log10(s / Float(Self.quadro) + 1e-12) > limiar { ativos += 1 }
            quadros += 1
            k += Self.quadro
        }
        guard quadros > 0, Double(ativos) / Double(quadros) >= 0.6 else { return }
        if modelo == nil { modelo = impressao() }
        let t0 = Date()
        guard let m = modelo, let v = try? m.vetor(audio[a..<z]) else { return }
        tempoDeImpressao += Date().timeIntervalSince(t0)

        // grupo mais parecido, ou um novo
        var melhor: (i: Int, s: Float)?
        for (i, g) in grupos.enumerated() where g.janelas > 0 {
            let s = Vozes.semelhanca(v, g.centro)
            if melhor == nil || s > melhor!.s { melhor = (i, s) }
        }
        let g: Int
        if let b = melhor, b.s >= Self.limiarGrupo {
            g = b.i
            for k in grupos[g].soma.indices { grupos[g].soma[k] += v[k] }
            grupos[g].janelas += 1
        } else {
            grupos.append(Grupo(soma: v, janelas: 1))
            g = grupos.count - 1
        }
        janelas.append(Janela(inicio: segundos(ini), fim: segundos(fim), grupo: g))
        // pedaços da mesma pessoa que nasceram separados: junta quando os centros ficam parecidos
        for (i, h) in grupos.enumerated() where i != g && h.janelas > 0 && Vozes.semelhanca(h.centro, grupos[g].centro) >= Self.limiarJuntar {
            if grupos[g].nome != nil && h.nome != nil && grupos[g].nome != h.nome { continue }
            let (fica, sai) = grupos[g].janelas >= h.janelas || grupos[g].nome != nil ? (g, i) : (i, g)
            juntar(sai, em: fica)
            break
        }
    }

    private func juntar(_ sai: Int, em fica: Int) {
        for k in grupos[fica].soma.indices { grupos[fica].soma[k] += grupos[sai].soma[k] }
        grupos[fica].janelas += grupos[sai].janelas
        if grupos[fica].nome == nil { grupos[fica].nome = grupos[sai].nome }
        grupos[fica].recusados.formUnion(grupos[sai].recusados)
        grupos[sai].janelas = 0
        grupos[sai].soma = grupos[sai].soma.map { _ in 0 }
        for i in janelas.indices where janelas[i].grupo == sai { janelas[i].grupo = fica }
        trava.lock()
        if atual?.grupo == sai { atual = nil }
        trava.unlock()
    }

    /// Abre, mantém ou fecha a pergunta conforme quem está falando.
    private func atualizarPergunta() {
        let agora = segundos(total)
        // quem fala agora: a última janela, se for recente
        guard let ultima = janelas.last, agora - ultima.fim < 2 else {
            // silêncio longo: a pergunta aberta continua (dá tempo de responder), até 25 s
            if let p = pergunta, agora - grupos[p.grupo].perguntadoEm > 25 { fechar(p.grupo) }
            return
        }
        let g = ultima.grupo
        if let p = pergunta {
            // a pessoa perguntada parou e outra já falou por um tempo: a pergunta perdeu o sentido
            let depois = janelas.reversed().prefix { $0.grupo != p.grupo }
            if depois.count >= 3 || agora - grupos[p.grupo].perguntadoEm > 25 { fechar(p.grupo) }
            return
        }
        let gr = grupos[g]
        guard gr.nome == nil, gr.janelas >= Self.janelasParaPerguntar, gr.perguntas < 2,
              agora - gr.perguntadoEm > 60, agora >= proximaEm, feitas < maximoDePerguntas else { return }
        // as últimas janelas precisam ser da mesma voz (não pergunta no meio de uma troca)
        guard janelas.suffix(2).allSatisfy({ $0.grupo == g }) else { return }
        feitas += 1
        perguntar(g, agora: agora)
    }

    private func perguntar(_ g: Int, agora: Double) {
        if grupos[g].palpite == nil, grupos[g].janelas >= Self.janelasParaPalpite,
           let r = livro.reconhecer(grupos[g].centro, limiar: Self.limiarPalpite),
           !grupos[g].recusados.contains(r.nome),
           !grupos.contains(where: { $0.nome == r.nome }) {
            grupos[g].palpite = r.nome
        }
        // parecida com alguém que você já nomeou nesta chamada: provavelmente a mesma pessoa, que o detector
        // ainda não juntou (mudou de microfone, falou mais alto)
        if grupos[g].palpite == nil {
            let centro = grupos[g].centro
            if let (nome, s) = grupos.enumerated().compactMap({ i, h -> (String, Float)? in
                guard i != g, h.janelas > 0, let n = h.nome, !grupos[g].recusados.contains(n) else { return nil }
                return (n, Vozes.semelhanca(centro, h.centro))
            }).max(by: { $0.1 < $1.1 }), s >= Self.limiarPalpiteNaChamada {
                grupos[g].palpite = nome
            }
        }
        let usados = Set(grupos.compactMap { $0.nome.map(Chamados.normalizar) })
        let livres = convidados.filter { c in !usados.contains(Chamados.normalizar(c)) && !grupos[g].recusados.contains(c) }
        grupos[g].perguntas += 1
        grupos[g].perguntadoEm = agora
        contador += 1
        let p = Pergunta(id: contador, grupo: g, palpite: grupos[g].palpite, sugestoes: Array(livres.prefix(4)))
        trava.lock()
        atual = p
        trava.unlock()
    }

    private func fechar(_ g: Int) {
        trava.lock()
        let era = atual?.grupo == g
        if era { atual = nil }
        trava.unlock()
        if era { proximaEm = segundos(total) + Self.intervalo }
    }
}
