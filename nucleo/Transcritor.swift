#if canImport(AVFoundation)
import AVFoundation
#endif
import Foundation

/// Lê um arquivo de áudio e devolve mono 16 kHz (o que o Whisper e a impressão de voz esperam).
enum Audio16k {
    static func ler(_ url: URL) throws -> [Float] {
        #if canImport(AVFoundation)
        let arquivo = try AVAudioFile(forReading: url)
        let fmt = arquivo.processingFormat
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(arquivo.length, 1)))!
        try arquivo.read(into: buf)
        if fmt.sampleRate == 16000 && fmt.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        }
        let alvo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let conv = AVAudioConverter(from: fmt, to: alvo)!
        conv.downmix = true
        let cap = AVAudioFrameCount(Double(buf.frameLength) * 16000 / fmt.sampleRate) + 4096
        let saida = AVAudioPCMBuffer(pcmFormat: alvo, frameCapacity: cap)!
        var entregue = false
        var erro: NSError?
        conv.convert(to: saida, error: &erro) { _, status in
            if entregue {
                status.pointee = .endOfStream
                return nil
            }
            entregue = true
            status.pointee = .haveData
            return buf
        }
        if let erro { throw erro }
        return Array(UnsafeBufferPointer(start: saida.floatChannelData![0], count: Int(saida.frameLength)))
        #else
        return try Wav.ler16k(url) // Windows: sem AVFoundation, só WAV
        #endif
    }
}

/// Acha os trechos com fala pelo volume, e junta em blocos de até 28 s para o Whisper.
enum Trechos {
    /// Volume (dB) de cada quadro de 30 ms.
    static func niveis(_ x: [Float], sr: Int = 16000) -> [Float] {
        let q = sr * 3 / 100
        return (0..<(x.count / q)).map { i in
            var s: Float = 0
            for j in 0..<q { s += x[i * q + j] * x[i * q + j] }
            return 10 * log10(s / Float(q) + 1e-12)
        }
    }

    /// Quadros de 30 ms com fala (pelo volume, acima do piso de ruído da própria trilha).
    static func ativos(_ x: [Float], sr: Int = 16000) -> [Bool] {
        let db = niveis(x, sr: sr)
        let n = db.count
        guard n > 0 else { return [] }
        let piso = db.sorted()[n / 10]
        let limiar = max(-50, piso + 12)
        return db.map { $0 > limiar }
    }

    /// Se a trilha tem pelo menos `minimo` segundos de fala no total.
    static func houveFala(_ x: [Float], sr: Int = 16000, minimo: Double) -> Bool {
        Double(ativos(x, sr: sr).lazy.filter { $0 }.count) * 0.03 >= minimo
    }

    /// Fração de quadros com fala num intervalo de amostras.
    static func fracaoAtiva(_ ativos: [Bool], _ r: Range<Int>, sr: Int = 16000) -> Double {
        let q = sr * 3 / 100
        let a = r.lowerBound / q, z = min(ativos.count, r.upperBound / q)
        guard z > a else { return 0 }
        return Double(ativos[a..<z].filter { $0 }.count) / Double(z - a)
    }

    /// Trechos com fala, juntados em blocos: pausas menores que `juntarAte` segundos não quebram o bloco,
    /// e nenhum bloco passa de `maxBloco` segundos (o Whisper trabalha em janelas de 30 s).
    static func deFala(_ x: [Float], sr: Int = 16000, juntarAte: Double = 1.5, maxBloco: Double = 28) -> [Range<Int>] {
        let q = sr * 3 / 100 // 30 ms
        let fala = ativos(x, sr: sr)
        let n = fala.count
        guard n > 0 else { return [] }
        // regiões de fala, tolerando pausas curtas
        var regioes: [Range<Int>] = []
        var ini: Int?
        var silencio = 0
        for i in 0..<n {
            if fala[i] {
                if ini == nil { ini = i }
                silencio = 0
            } else if let a = ini {
                silencio += 1
                if silencio > 17 { // 0,5 s sem fala fecha a região
                    regioes.append(a..<(i - silencio + 1))
                    ini = nil
                    silencio = 0
                }
            }
        }
        if let a = ini { regioes.append(a..<n) }
        let folga = 7 // 0,2 s antes e depois
        let falas = regioes.filter { $0.count >= 10 }.map { max(0, $0.lowerBound - folga) * q..<min(n, $0.upperBound + folga) * q }
        // junta regiões próximas em blocos
        var blocos: [Range<Int>] = []
        for r in falas {
            if let ultimo = blocos.last, r.lowerBound - ultimo.upperBound < Int(juntarAte * Double(sr)),
               r.upperBound - ultimo.lowerBound <= Int(maxBloco * Double(sr)) {
                blocos[blocos.count - 1] = ultimo.lowerBound..<r.upperBound
            } else {
                blocos.append(r)
            }
        }
        return blocos
    }
}

/// whisper.cpp (MIT) com o modelo large-v3-turbo, rodando na GPU do Mac.
final class Whisper {
    private let ctx: OpaquePointer

    struct Palavra {
        var texto: String
        var inicio: Double
        var fim: Double
    }

    struct Segmento {
        var inicio: Double
        var fim: Double
        var texto: String
        var confianca: Float = 1
        /// Pedaços de texto (tokens) com horário, para saber quem falou cada palavra.
        var palavras: [Palavra] = []
    }

    struct Falha: Error, CustomStringConvertible { let description: String }

    /// Horário de cada palavra pelo alinhamento DTW (atenção cruzada do modelo), mais preciso que o padrão: a palavra
    /// cai do lado certo da troca de pessoa mais vezes. Não funciona junto com o flash attention (o tempo quase não muda).
    static var usarDTW = true

    init(modelo: String) throws {
        guard FileManager.default.fileExists(atPath: modelo) else { throw Falha(description: "modelo do Whisper não encontrado em \(modelo)") }
        whisper_log_set({ _, _, _ in }, nil)
        Self.carregarBackends
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = !Self.usarDTW
        if Self.usarDTW {
            cp.dtw_token_timestamps = true
            cp.dtw_aheads_preset = WHISPER_AHEADS_LARGE_V3_TURBO
        }
        guard let c = whisper_init_from_file_with_params(modelo, cp) else { throw Falha(description: "não consegui abrir o Whisper") }
        ctx = c
    }

    deinit { whisper_free(ctx) }

    /// O ggml do Homebrew carrega Metal e CPU como plugins; precisa pedir uma vez por processo.
    private static let carregarBackends: Void = {
        ggml_log_set({ _, _, _ in }, nil)
        ggml_backend_load_all()
    }()

    /// Frases que o Whisper inventa em trechos sem fala (vícios do treino com legendas da internet).
    private static let alucinacoes = ["amara.org", "obrigado por assistir", "inscreva-se", "legendas pela comunidade",
                                      "legenda adriana", "sous-titres", "subtítulos realizados", "castingwords",
                                      "transcription by", "subtitles by", "thanks for watching", "thank you for watching",
                                      "legendas por", "legenda por", "legendado por", "legendagem", "transcrição e legendas",
                                      "transcrição por", "sous-titrage", "www."]

    /// Língua de um trecho longo: "en" se o Whisper achar inglês, "pt" para qualquer outra coisa.
    func idioma(_ x: ArraySlice<Float>) -> String {
        guard rodar(Array(x), idioma: "auto", contexto: nil) else { return "pt" }
        return String(cString: whisper_lang_str(whisper_full_lang_id(ctx))) == "en" ? "en" : "pt"
    }

    /// Transcreve um bloco (até 28 s) na língua da reunião, usando o final do bloco anterior como contexto.
    /// Um bloco longo em que o Whisper tem pouca certeza é refeito na outra língua (alguém falando inglês
    /// numa reunião em português, ou o contrário), e fica a versão mais confiável.
    func transcrever(_ x: ArraySlice<Float>, inicio: Double, idioma: String, contexto: String?) -> [Segmento] {
        let amostras = Array(x)
        var brutos = ler(amostras, idioma: idioma, contexto: contexto)
        let media = Self.confiancaPonderada(brutos)
        if amostras.count >= 16000 * 5 && media < 0.55 {
            let alternativa = ler(amostras, idioma: idioma == "pt" ? "en" : "pt", contexto: nil)
            if Self.confiancaPonderada(alternativa) > media + 0.15 { brutos = alternativa }
        }
        var segs: [Segmento] = []
        for b in brutos {
            let texto = Texto.semRepeticao(b.texto.trimmingCharacters(in: .whitespacesAndNewlines))
            let minusc = texto.lowercased()
            // sem nenhuma letra ("."), frase-vício do Whisper ou frase toda em MAIÚSCULAS ("A CIDADE NO BRASIL",
            // que ele solta em cima de música e ruído): fora
            if !texto.contains(where: { $0.isLetter }) || Self.alucinacoes.contains(where: { minusc.contains($0) })
                || Texto.gritada(texto) { continue }
            // frases que o modelo "chutou" (confiança média baixa) costumam ser invenção em cima de ruído
            if b.confianca < 0.35 || (b.confianca < 0.5 && b.fim - b.inicio < 1.5) { continue }
            let palavras = b.palavras.map { Palavra(texto: $0.texto, inicio: inicio + $0.inicio, fim: inicio + $0.fim) }
            segs.append(Segmento(inicio: inicio + b.inicio, fim: inicio + b.fim, texto: texto, confianca: b.confianca, palavras: palavras))
        }
        return segs
    }

    /// Sinais de pontuação por palavra num bloco.
    static func pontuacao(_ segs: [Segmento]) -> Double {
        let texto = segs.map(\.texto).joined(separator: " ")
        let palavras = texto.split(separator: " ").count
        guard palavras > 0 else { return 0 }
        return Double(texto.filter { ".,?!;:".contains($0) }.count) / Double(palavras)
    }

    /// Bloco com 25+ palavras e quase nenhuma pontuação (menos de 1 sinal a cada 25 palavras).
    static func semPontuacao(_ segs: [Segmento]) -> Bool {
        let palavras = segs.reduce(0) { $0 + $1.texto.split(separator: " ").count }
        return palavras >= 25 && pontuacao(segs) < 1.0 / 25
    }

    /// Quantas palavras de um bloco estão em laço ("de todas as reuniões de todas as reuniões…").
    static func palavrasEmLaco(_ segs: [Segmento]) -> Int {
        Texto.lacos(segs.flatMap { Texto.palavrasInteiras($0.palavras).map(\.chave) }).filter { $0 }.count
    }

    /// Tira laços que atravessam frases: uma sequência de palavras repetida 3+ vezes seguidas fica uma vez só.
    /// Mantém o horário de cada palavra que sobra.
    static func semLacos(_ segs: [Segmento]) -> [Segmento] {
        let porSegmento = segs.map { Texto.palavrasInteiras($0.palavras) }
        let remover = Texto.lacos(porSegmento.flatMap { $0.map(\.chave) })
        guard remover.contains(true) else { return segs }
        var k = 0
        var saida: [Segmento] = []
        for (i, s) in segs.enumerated() {
            var tokens: [Palavra] = []
            for w in porSegmento[i] {
                if !remover[k] { tokens += w.tokens }
                k += 1
            }
            let texto = tokens.map(\.texto).joined().trimmingCharacters(in: .whitespaces)
            guard texto.contains(where: { $0.isLetter }), let a = tokens.first, let z = tokens.last else { continue }
            var novo = s
            novo.texto = texto
            novo.palavras = tokens
            novo.inicio = a.inicio
            novo.fim = z.fim
            saida.append(novo)
        }
        return saida
    }

    private static func confiancaPonderada(_ s: [Segmento]) -> Float {
        let peso = s.reduce(0.0) { $0 + max(0.1, $1.fim - $1.inicio) }
        guard peso > 0 else { return 0 }
        return Float(s.reduce(0.0) { $0 + Double($1.confianca) * max(0.1, $1.fim - $1.inicio) } / peso)
    }

    /// Roda o Whisper e devolve os segmentos com horário relativo ao bloco.
    private func ler(_ amostras: [Float], idioma: String, contexto: String?) -> [Segmento] {
        guard rodar(amostras, idioma: idioma, contexto: contexto) else { return [] }
        var segs: [Segmento] = []
        let fimTexto = whisper_token_eot(ctx)
        for i in 0..<whisper_full_n_segments(ctx) {
            if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.6 { continue }
            let t0 = Double(whisper_full_get_segment_t0(ctx, i)) / 100
            let t1 = Double(whisper_full_get_segment_t1(ctx, i)) / 100
            var palavras: [Palavra] = []
            let n = whisper_full_n_tokens(ctx, i)
            for j in 0..<n {
                let d = whisper_full_get_token_data(ctx, i, j)
                guard d.id < fimTexto, let t = whisper_full_get_token_text(ctx, i, j) else { continue }
                // sem horário calculado, o token herda o do segmento
                var a = d.t0 >= 0 ? Double(d.t0) / 100 : t0, z = d.t1 >= 0 ? Double(d.t1) / 100 : t1
                if Self.usarDTW && d.t_dtw >= 0 {
                    // DTW dá o instante de cada token; o fim é o começo do próximo
                    a = Double(d.t_dtw) / 100
                    z = a + 0.1
                    for k in (j + 1)..<max(j + 1, n) {
                        let p = whisper_full_get_token_data(ctx, i, k)
                        if p.id < fimTexto && p.t_dtw >= 0 { z = max(a, Double(p.t_dtw) / 100); break }
                    }
                }
                palavras.append(Palavra(texto: String(cString: t), inicio: max(t0, a), fim: min(t1, max(a, z))))
            }
            segs.append(Segmento(inicio: t0, fim: t1, texto: String(cString: whisper_full_get_segment_text(ctx, i)),
                                 confianca: confiancaMedia(i), palavras: palavras))
        }
        return segs
    }

    private func rodar(_ amostras: [Float], idioma: String, contexto: String?) -> Bool {
        let lingua = strdup(idioma)
        let prompt = contexto.flatMap { $0.isEmpty ? nil : strdup($0) }
        defer {
            free(lingua)
            free(prompt)
        }
        // busca em feixe (5 caminhos): mais lenta que a gulosa, mas inventa bem menos
        var p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH)
        p.beam_search.beam_size = 5
        p.language = UnsafePointer(lingua)
        // o contexto é o fim do bloco anterior (a própria conversa), passado à mão; nunca uma frase fixa,
        // que o Whisper chegava a repetir em trechos quase sem fala
        p.initial_prompt = prompt.map { UnsafePointer($0) }
        p.token_timestamps = true // horário de cada palavra, para cortar a frase onde a pessoa muda
        p.n_threads = 8
        p.no_context = true
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.print_special = false
        p.suppress_nst = true
        p.no_speech_thold = 0.6
        return amostras.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) } == 0
    }

    /// Probabilidade média dos tokens de texto de um segmento (0 a 1).
    private func confiancaMedia(_ i: Int32) -> Float {
        let fim = whisper_token_eot(ctx)
        var soma: Float = 0
        var n: Float = 0
        for j in 0..<whisper_full_n_tokens(ctx, i) where whisper_full_get_token_id(ctx, i, j) < fim {
            soma += whisper_full_get_token_p(ctx, i, j)
            n += 1
        }
        return n > 0 ? soma / n : 0
    }
}

/// O que sai de uma chamada: quem falou o quê, e quando.
struct Sessao: Codable {
    struct Fala: Codable {
        var inicio: Double
        var fim: Double
        var texto: String
        var voz: String // "voce" ou o id de uma voz de Outros ("v1", "v2"...)
    }

    struct Voz: Codable {
        var id: String
        var rotulo: String // "Pessoa 1"
        var nome: String? // preenchido pela memória ou por você
        var reconhecida: Bool // true se veio da memória de vozes
        var semelhanca: Float?
        var vetor: [Float]
        var amostraInicio: Double // trecho bom para ouvir a pessoa
        var amostraFim: Double
        var exemplo: String
        /// Quantas janelas de 3 s sustentam esta voz. Com poucas, a impressão é fraca e não vai para a memória.
        var janelas: Int?
        /// Segundos de fala desta pessoa na chamada.
        var segundos: Double?
        /// Nome provável, ainda sem a sua confirmação (quem atendeu quando chamaram, ou o único convidado que faltava).
        var sugestao: String?
        /// Por que o app sugere esse nome, em palavras ("atendeu 4 vezes quando chamaram “Marina”").
        var motivo: String?
        /// O nome veio da sua resposta na ilha, durante a chamada.
        var aoVivo: Bool?
    }

    /// Um trecho da trilha dos outros (segundos desde o começo dela) em que você disse, na ilha, quem falava.
    struct Marca: Codable {
        var inicio: Double
        var fim: Double
        var nome: String
    }

    /// Voz com fala de menos que isto não pede nome: é pouco para ouvir e para a memória aprender.
    static let segundosParaNomear = 15.0

    var id: String
    var titulo: String
    var inicio: Date
    var fim: Date
    var app: String?
    var convidados: [String] = []
    var falas: [Fala] = []
    var vozes: [Voz] = []
    var markdown: String?
    var pasta: String // onde ficam o áudio e este arquivo
    var atrasoOutros: Double = 0 // a trilha dos outros começou este tanto depois da sua (s)
    /// Trechos em que seu microfone estava no mudo no app da chamada, em segundos desde o começo da gravação.
    var mudo: [[Double]]?
    /// Quem você disse que falava, na ilha, durante a chamada.
    var marcas: [Marca]?

    func nome(da voz: String) -> String {
        if voz == "voce" { return "Você" }
        guard let v = vozes.first(where: { $0.id == voz }) else { return "Outros" }
        return v.nome ?? v.sugestao.map { "\($0) (?)" } ?? v.rotulo
    }

    /// Vozes que valem um nome: sem nome e com fala suficiente (as antigas, sem a medida, contam).
    var semNome: [Voz] { vozes.filter { $0.nome == nil && ($0.segundos ?? .infinity) >= Self.segundosParaNomear } }

    // MARK: arquivos

    static func carregar(pasta: URL) -> Sessao? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard var s = (try? Data(contentsOf: pasta.appendingPathComponent("sessao.json"))).flatMap({ try? dec.decode(Sessao.self, from: $0) })
        else { return nil }
        // vale a pasta de onde ela foi lida: a gravada no arquivo pode ser de antes de a pasta do app mudar de nome
        s.pasta = pasta.path
        return s
    }

    func salvar() throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: URL(fileURLWithPath: pasta).appendingPathComponent("sessao.json"), options: .atomic)
    }

    /// Escreve (ou reescreve) o Markdown em Ligações/ano/mês/dia.
    mutating func gravarMarkdown() throws {
        let url = markdown.map { URL(fileURLWithPath: $0) } ?? Ata.caminho(para: self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Ata.markdown(self).write(to: url, atomically: true, encoding: .utf8)
        markdown = url.path
    }

    func apagarAudio() {
        let p = URL(fileURLWithPath: pasta)
        for f in ["voce.wav", "outros.wav"] { try? FileManager.default.removeItem(at: p.appendingPathComponent(f)) }
    }
}

/// Junta Whisper, impressão de voz e memória para transcrever as duas trilhas de uma chamada.
final class Transcritor {
    let whisper: Whisper
    let impressao: ImpressaoDeVoz
    let livro: LivroDeVozes

    let separador: SeparadorDeVozes
    /// Tira do som da chamada o que não é fala (música de outra aba, sino de entrada). nil = não filtra.
    let detector: DetectorDeFala?

    /// Distância (cosseno) do separador para juntar dois trechos na mesma pessoa. Calibrado nas suas reuniões
    /// (uma reunião semanal de 21 min com 4 pessoas, nomes conferidos à mão): 0,75 achou as 4 pessoas e acertou 97% do tempo de fala.
    static var limiarSeparacao: Float = 0.75
    /// Quanto a janela de 10 s do separador anda a cada passo (fração dela). Menor marca as trocas de pessoa com
    /// mais precisão e custa mais. Medido numa conversa montada com trocas conhecidas (11/11): quem falou certo
    /// em 79% das palavras com 0,5; 86% com 0,25 e DTW (1,4× o tempo); 87% com 0,1 (2,3× o tempo).
    static var passoSeparador: Float = 0.25
    /// Um falante dos outros reconhecido pela memória (média da pessoa nesta chamada × as guardadas).
    /// Medido: a mesma pessoa em outra reunião deu 0,95; uma pessoa diferente chegou a 0,72 (e virou nome errado).
    static var limiarMemoria: Float = 0.8
    /// O mesmo, quando o nome guardado é de um convidado da reunião (a pessoa provavelmente está ali).
    static var limiarConvidado: Float = 0.75
    /// Dois falantes grandes com vozes parecidas assim são a mesma pessoa partida em dois pelo separador.
    /// Medido nas suas reuniões: pedaços da mesma pessoa deram 0,86 a 0,97; pessoas diferentes, até 0,72.
    static var limiarMesmaPessoa: Float = 0.8
    /// Com a lista de convidados, se ainda houver mais vozes do que convidados, junta também até aqui.
    /// Abaixo disso a voz é de outra pessoa de certeza: fica, e você confirma quem é.
    static var limiarComConvidados: Float = 0.7
    /// Um falante dos outros parecido assim com a sua voz é eco da sua fala (alguém com microfone aberto perto
    /// de você, ou você sem fone): não vira uma "pessoa".
    static var limiarEco: Float = 0.6
    /// Quantas janelas de até 3 s formam a impressão de cada pessoa (as dos trechos mais longos dela).
    static var janelasPorFalante = 24
    /// Falante com menos fala que isto (s) é pedaço de alguém, não uma pessoa.
    static var segundosDePessoa = 15.0
    /// A pessoa só muda no meio de uma frase se o trecho novo tiver pelo menos isto de palavras.
    static var palavrasParaTrocar = 3
    static let janela = 3.0

    init(whisper: Whisper, impressao: ImpressaoDeVoz, separador: SeparadorDeVozes, detector: DetectorDeFala?, livro: LivroDeVozes) {
        self.whisper = whisper
        self.impressao = impressao
        self.separador = separador
        self.detector = detector
        self.livro = livro
    }

    /// Abre os três modelos (Whisper, impressão de voz e separador).
    static func criar(whisper modelo: String, livro: LivroDeVozes) throws -> Transcritor {
        Transcritor(whisper: try Whisper(modelo: modelo),
                    impressao: try ImpressaoDeVoz(modelo: Modelos.voz()),
                    separador: try SeparadorDeVozes(segmentacao: Modelos.segmentacao(), impressao: Modelos.voz(), limiar: limiarSeparacao,
                                                    passo: passoSeparador),
                    detector: try DetectorDeFala(modelo: Modelos.sons(), rotulos: Modelos.rotulosDeSons()),
                    livro: livro)
    }

    /// Transcreve a chamada. Os horários saem na linha do tempo da sua trilha (0 = começo da sua gravação).
    /// `atrasoOutros`: quantos segundos a trilha de Outros começou depois da sua.
    ///
    /// Como funciona: as duas trilhas são misturadas e o Whisper transcreve a CONVERSA, em blocos longos e com
    /// o fim do bloco anterior como contexto (transcrever cada trilha em falas soltas de 1–3 s dava texto
    /// sem sentido). Depois, cada frase vai para você ou para os outros conforme qual trilha tem voz naquele
    /// momento, e as frases dos outros ganham uma pessoa pela impressão de voz.
    /// `convidados`: quem estava no convite da agenda (sem você). Limita quantas pessoas diferentes a chamada pode ter
    /// e ajuda a dar nome às vozes.
    func transcrever(voce vozBruta: [Float], outros somDosOutros: [Float], atrasoOutros: Double = 0, mudo: [[Double]] = [],
                     convidados: [String] = [], marcas: [Sessao.Marca] = [],
                     progresso: (Double) -> Void = { _ in }) -> (falas: [Sessao.Fala], vozes: [Sessao.Voz]) {
        let sr = 16000.0
        // no mudo, o que o microfone ouviu não foi para a chamada: some da transcrição
        var voce = vozBruta
        for m in mudo where m.count == 2 {
            let a = max(0, Int(m[0] * sr)), z = min(voce.count, Int(m[1] * sr))
            if z > a { for i in a..<z { voce[i] = 0 } }
        }
        // no som da chamada, só a fala: música de outra aba do navegador, sino de entrada e afins saem antes
        // de tudo (o Whisper inventava letra em cima deles, e o separador transformava em "pessoa")
        var outros = somDosOutros
        if let detector {
            let semFala = detector.semFala(outros) { p in progresso(0.05 * p) }
            for (s, tira) in semFala.enumerated() where tira {
                for i in (s * Int(sr))..<min(outros.count, (s + 1) * Int(sr)) { outros[i] = 0 }
            }
        }
        // linha do tempo da mistura: começa no que vier primeiro (normalmente a sua trilha)
        let desloc = Int((atrasoOutros * sr).rounded()) // outros[j] acontece em voce[j + desloc]
        let base = max(0, -desloc)                       // voce[i] fica em mistura[i + base]
        let total = max(voce.count + base, outros.count + desloc + base)
        var mistura = [Float](repeating: 0, count: max(0, total))
        for i in voce.indices { mistura[i + base] += voce[i] }
        for j in outros.indices {
            let k = j + desloc + base
            if k >= 0 && k < mistura.count { mistura[k] += outros[j] }
        }
        let ativosVoce = Trechos.ativos(voce), ativosOutros = Trechos.ativos(outros)
        // 1) a conversa inteira, em blocos de até 28 s que só quebram em pausas de 3 s ou mais
        let blocos = Trechos.deFala(mistura, juntarAte: 3, maxBloco: 28)
        // a língua da reunião sai dos blocos mais longos (uma fala curta engana a detecção)
        let longos = blocos.sorted { $0.count > $1.count }.prefix(3)
        let emIngles = longos.filter { whisper.idioma(mistura[$0]) == "en" }.count
        let lingua = emIngles * 2 > longos.count ? "en" : "pt"
        var segs: [Whisper.Segmento] = []
        var contexto: String?
        for (k, b) in blocos.enumerated() {
            let ini = Double(b.lowerBound) / sr
            var s = whisper.transcrever(mistura[b], inicio: ini, idioma: lingua, contexto: contexto)
            // laço ("de todas as reuniões de todas as reuniões…"): o contexto costuma alimentar a repetição;
            // refaz sem ele e fica com a versão com menos palavras repetidas
            let emLaco = Whisper.palavrasEmLaco(s)
            if emLaco > 0, contexto != nil {
                let outra = whisper.transcrever(mistura[b], inicio: ini, idioma: lingua, contexto: nil)
                if Whisper.palavrasEmLaco(outra) < emLaco { s = outra }
            }
            // bloco longo escrito sem pontuação nem maiúsculas: o Whisper "pegou o ritmo" de um contexto corrido;
            // refaz sem contexto e fica com a versão mais pontuada
            if contexto != nil, Whisper.semPontuacao(s) {
                let outra = whisper.transcrever(mistura[b], inicio: ini, idioma: lingua, contexto: nil)
                if Whisper.pontuacao(outra) > Whisper.pontuacao(s), Whisper.palavrasEmLaco(outra) <= Whisper.palavrasEmLaco(s) { s = outra }
            }
            s = Whisper.semLacos(s)
            segs += s
            let texto = s.map(\.texto).joined(separator: " ")
            // contexto viciado (laço ou sem pontuação) não passa para o próximo bloco
            let fim = String(texto.suffix(200))
            let fimCorrido = fim.split(separator: " ").count >= 15 && !fim.contains(where: { ".,?!;:".contains($0) })
            contexto = texto.isEmpty || emLaco > 0 || fimCorrido ? nil : fim
            progresso(0.75 * Double(k + 1) / Double(max(1, blocos.count)))
        }

        // 2) quem fala quando na trilha dos outros: o separador (pyannote) marca cada troca de voz e junta os
        // trechos da mesma pessoa. Horários passam para a linha do tempo da mistura.
        let deslocMistura = Double(desloc + base) / sr
        let separados = separador.separar(outros) { p in progresso(0.75 + 0.15 * p) }
        struct Turno {
            var inicio: Double
            var fim: Double
            var falante: Int
        }
        let turnos = separados.map { Turno(inicio: $0.inicio + deslocMistura, fim: $0.fim + deslocMistura, falante: $0.falante) }

        // impressão de cada falante: média de janelas de até 3 s nos trechos mais longos dele
        var duracao: [Int: Double] = [:]
        for t in separados { duracao[t.falante, default: 0] += t.fim - t.inicio }
        var centro: [Int: [Float]] = [:]
        var nJanelas: [Int: Int] = [:]
        for f in duracao.keys.sorted() {
            var vs: [[Float]] = []
            for t in separados.filter({ $0.falante == f }).sorted(by: { $0.fim - $0.inicio > $1.fim - $1.inicio }) {
                guard vs.count < Self.janelasPorFalante, t.fim - t.inicio >= 1.5 else { break }
                var a = Int(t.inicio * sr)
                let z = min(outros.count, Int(t.fim * sr))
                while a + Int(1.5 * sr) <= z && vs.count < Self.janelasPorFalante {
                    let fim = min(z, a + Int(Self.janela * sr))
                    if let v = try? impressao.vetor(outros[a..<fim]) { vs.append(v) }
                    a = fim
                }
            }
            if !vs.isEmpty {
                centro[f] = Vozes.media(vs)
                nJanelas[f] = vs.count
            }
        }
        progresso(0.95)

        // Sua própria voz, tirada da sua trilha: um falante dos outros parecido com ela é eco e não vira "pessoa".
        let suas = janelasDeVoz(voce, Trechos.deFala(voce), maximo: 20)
        let suaVoz: [Float]? = suas.count >= 2 ? Vozes.media(suas) : nil

        // chave de cada falante: eco, um nome da memória ou o próprio falante. Falante sem impressão (só trechos
        // curtos demais para medir a voz) fica sem chave: as palavras dele vão para o falante mais próximo no tempo.
        var chave: [Int: String] = [:]
        var semelhancaDaMemoria: [String: Float] = [:]
        // O separador deixa pedacinhos (uma tosse, um "aham", uma frase com eco) como falantes à parte. Quem tem
        // pouca fala entra na pessoa grande de voz mais parecida; a impressão de poucos segundos é fraca demais
        // para virar alguém.
        let grandes = centro.keys.filter { (duracao[$0] ?? 0) >= Self.segundosDePessoa }
        var absorvido: [Int: Int] = [:]
        if !grandes.isEmpty {
            for (f, c) in centro where (duracao[f] ?? 0) < Self.segundosDePessoa {
                absorvido[f] = grandes.max { Vozes.semelhanca(c, centro[$0]!) < Vozes.semelhanca(c, centro[$1]!) }!
            }
        }
        // falantes grandes que são a mesma pessoa partida em dois viram um grupo só
        let grupos = Self.juntarMesmaPessoa(centro.keys.filter { absorvido[$0] == nil }.sorted(), centro: centro,
                                            maximo: convidados.isEmpty ? nil : convidados.count)
        for g in grupos {
            let c = Vozes.media(g.map { centro[$0]! })
            var k: String
            if let suaVoz, Vozes.semelhanca(c, suaVoz) >= Self.limiarEco {
                k = "eco"
            } else if let r = livro.reconhecer(c, limiar: Self.limiarMemoria)
                        ?? livro.reconhecer(c, limiar: Self.limiarConvidado).flatMap({ Chamados.casar($0.nome, com: convidados) != nil ? $0 : nil }) {
                k = "n:" + r.nome
                semelhancaDaMemoria[r.nome] = max(semelhancaDaMemoria[r.nome] ?? 0, r.semelhanca)
            } else {
                k = "s\(g[0])"
            }
            for f in g { chave[f] = k }
        }
        for (f, g) in absorvido { chave[f] = chave[g] }

        // 3) quem falou cada palavra: você (sua trilha tem voz) ou alguém dos outros (a janela de voz mais
        // próxima diz quem). A frase do Whisper é cortada onde a pessoa muda.
        func ativo(_ at: [Bool], _ t0: Double, _ t1: Double, menos: Int) -> Double {
            let a = max(0, Int((t0 - 0.15) * sr) - menos), z = max(a + 1, Int((t1 + 0.15) * sr) - menos)
            return Trechos.fracaoAtiva(at, a..<z)
        }
        let validos = turnos.filter { chave[$0.falante].map { $0 != "eco" } ?? false }
        /// Quem dos outros fala no instante t: o trecho do separador que cobre t, ou o mais próximo.
        func pessoaDosOutros(_ t: Double) -> String {
            guard !validos.isEmpty else { return "outros" }
            var lo = 0, hi = validos.count
            while lo < hi {
                let m = (lo + hi) / 2
                if validos[m].inicio <= t { lo = m + 1 } else { hi = m }
            }
            var melhor: (d: Double, k: String)?
            for i in max(0, lo - 6)..<min(validos.count, lo + 2) {
                let v = validos[i]
                let d = t < v.inicio ? v.inicio - t : (t > v.fim ? t - v.fim : 0)
                if melhor == nil || d < melhor!.d { melhor = (d, chave[v.falante]!) }
            }
            return melhor?.k ?? "outros"
        }
        // Palavra com som nas duas trilhas vai para a trilha com mais fala em volta dela. Testado em 10/11:
        // decidir pelo volume (absoluto ou relativo ao normal de cada trilha) cortava frases suas ao meio e
        // trocava trechos sem padrão; a fala ao seu redor no mudo se resolve pela leitura do mudo.
        func quem(_ t0: Double, _ t1: Double) -> String? {
            let v = ativo(ativosVoce, t0, t1, menos: base), o = ativo(ativosOutros, t0, t1, menos: base + desloc)
            if v == 0 && o == 0 { return nil }
            return v >= o ? "voce" : pessoaDosOutros((t0 + t1) / 2)
        }
        struct Trecho {
            var inicio: Double
            var fim: Double
            var texto: String
            var quem: String
        }
        var trechos: [Trecho] = []
        for s in segs {
            // tokens viram palavras inteiras (um token que começa com espaço abre palavra nova)
            var palavras: [Whisper.Palavra] = []
            for p in (s.palavras.isEmpty ? [Whisper.Palavra(texto: s.texto, inicio: s.inicio, fim: s.fim)] : s.palavras) {
                if p.texto.hasPrefix(" ") || palavras.isEmpty {
                    palavras.append(p)
                } else {
                    palavras[palavras.count - 1].texto += p.texto
                    palavras[palavras.count - 1].fim = max(palavras[palavras.count - 1].fim, p.fim)
                }
            }
            let padrao = quem(s.inicio, s.fim) ?? "voce"
            var rotulos = palavras.map { quem($0.inicio, $0.fim) ?? padrao }
            // a pessoa só muda se o novo trecho tiver pelo menos `palavrasParaTrocar` palavras: horário de palavra é impreciso
            var mudou = true
            while mudou {
                mudou = false
                var corridas: [(ini: Int, fim: Int)] = []
                for i in rotulos.indices {
                    if let u = corridas.last, rotulos[u.ini] == rotulos[i] { corridas[corridas.count - 1].fim = i } else { corridas.append((i, i)) }
                }
                guard corridas.count > 1 else { break }
                for (k, c) in corridas.enumerated() where c.fim - c.ini + 1 < Self.palavrasParaTrocar {
                    let vizinha = k > 0 ? corridas[k - 1] : corridas[k + 1]
                    for i in c.ini...c.fim { rotulos[i] = rotulos[vizinha.ini] }
                    mudou = true
                    break
                }
            }
            var atual: Trecho?
            for (i, p) in palavras.enumerated() {
                if var a = atual, a.quem == rotulos[i] {
                    a.texto += p.texto
                    a.fim = p.fim
                    atual = a
                } else {
                    if let a = atual { trechos.append(a) }
                    atual = Trecho(inicio: p.inicio, fim: p.fim, texto: p.texto, quem: rotulos[i])
                }
            }
            if let a = atual { trechos.append(a) }
        }
        // texto limpo, sem pedaços sem letras, e horários na linha do tempo da sua trilha
        let paraSessao = Double(base) / sr
        trechos = trechos.compactMap { t in
            let texto = Texto.semRepeticao(t.texto.trimmingCharacters(in: .whitespacesAndNewlines))
            guard texto.contains(where: { $0.isLetter }) else { return nil }
            return Trecho(inicio: t.inicio - paraSessao, fim: t.fim - paraSessao, texto: texto, quem: t.quem)
        }

        // 4) uma voz por pessoa, na ordem em que ela falou (falantes que a memória reconhece como a mesma pessoa viram um só)
        var vozes: [Sessao.Voz] = []
        var idDaChave: [String: String] = [:]
        var desconhecidas = 0
        var ordem: [String] = []
        for t in trechos where t.quem != "voce" && t.quem != "outros" && !ordem.contains(t.quem) { ordem.append(t.quem) }
        for c in ordem {
            let membros = centro.keys.filter { chave[$0] == c }
            guard !membros.isEmpty else { continue }
            // a impressão da pessoa vem só dos falantes grandes (pedacinhos absorvidos têm impressão fraca)
            let principais = membros.filter { absorvido[$0] == nil }
            let centroDaVoz = Vozes.media((principais.isEmpty ? membros : principais).map { centro[$0]! })
            // o trecho mais longo da pessoa serve de amostra para ouvir e nomear
            let seus = trechos.filter { $0.quem == c }
            guard let amostra = seus.max(by: { $0.fim - $0.inicio < $1.fim - $1.inicio }) else { continue }
            // e a fala com mais texto vira o exemplo escrito (ajuda a lembrar quem é)
            var exemplo = seus.map(\.texto).max(by: { $0.count < $1.count }) ?? amostra.texto
            if exemplo.count > 140 { exemplo = String(exemplo.prefix(140)) + "…" }
            let nome: String? = c.hasPrefix("n:") ? String(c.dropFirst(2)) : nil
            if nome == nil { desconhecidas += 1 }
            let id = "v\(vozes.count + 1)"
            idDaChave[c] = id
            vozes.append(.init(id: id, rotulo: nome ?? "Pessoa \(desconhecidas)", nome: nome,
                               reconhecida: nome != nil, semelhanca: nome.flatMap { semelhancaDaMemoria[$0] }, vetor: centroDaVoz,
                               amostraInicio: amostra.inicio, amostraFim: amostra.fim, exemplo: exemplo,
                               janelas: (principais.isEmpty ? membros : principais).reduce(0) { $0 + (nJanelas[$1] ?? 0) },
                               segundos: membros.reduce(0.0) { $0 + (duracao[$1] ?? 0) }))
        }
        let falas: [Sessao.Fala] = trechos.map {
            .init(inicio: $0.inicio, fim: $0.fim, texto: $0.texto, voz: $0.quem == "voce" ? "voce" : (idDaChave[$0.quem] ?? "outros"))
        }.sorted { $0.inicio < $1.inicio }
        Self.aplicarMarcas(&vozes, falas: falas, marcas: marcas, atrasoOutros: atrasoOutros)
        Self.sugerirNomes(&vozes, falas: falas, convidados: convidados, livro: livro)
        return (falas, vozes)
    }

    /// Os nomes que você deu na ilha durante a chamada: cada voz fica com o nome que cobre a maior parte dos
    /// trechos marcados dela (60%+ e 6 s+). Vale mais que a memória: foi você quem disse.
    static func aplicarMarcas(_ vozes: inout [Sessao.Voz], falas: [Sessao.Fala], marcas: [Sessao.Marca], atrasoOutros: Double) {
        guard !marcas.isEmpty else { return }
        for i in vozes.indices {
            var porNome: [String: Double] = [:]
            for f in falas where f.voz == vozes[i].id {
                for m in marcas {
                    let s = min(f.fim, m.fim + atrasoOutros) - max(f.inicio, m.inicio + atrasoOutros)
                    if s > 0 { porNome[m.nome, default: 0] += s }
                }
            }
            let total = porNome.values.reduce(0, +)
            guard let (nome, d) = porNome.max(by: { $0.value < $1.value }), d >= 6, d / total >= 0.6 else { continue }
            if vozes[i].nome != nome { vozes[i].reconhecida = false }
            vozes[i].nome = nome
            vozes[i].aoVivo = true
        }
    }

    /// Junta falantes que são a mesma pessoa. Dois grupos só se juntam se TODOS os pares entre eles forem parecidos
    /// (o par menos parecido decide), para um grupo grande não ir puxando vozes diferentes aos poucos.
    /// `maximo`: quantos convidados a reunião tem; enquanto houver mais grupos que isso, junta também na faixa de dúvida.
    static func juntarMesmaPessoa(_ falantes: [Int], centro: [Int: [Float]], maximo: Int?) -> [[Int]] {
        var grupos = falantes.map { [$0] }
        func ligacao(_ a: [Int], _ b: [Int]) -> Float {
            var m: Float = 1
            for i in a { for j in b { m = min(m, Vozes.semelhanca(centro[i]!, centro[j]!)) } }
            return m
        }
        func juntar(ate limiar: Float, enquanto: () -> Bool) {
            while grupos.count > 1 && enquanto() {
                var melhor: (s: Float, i: Int, j: Int)?
                for i in grupos.indices {
                    for j in (i + 1)..<grupos.count {
                        let s = ligacao(grupos[i], grupos[j])
                        if melhor == nil || s > melhor!.s { melhor = (s, i, j) }
                    }
                }
                guard let m = melhor, m.s >= limiar else { return }
                grupos[m.i] += grupos[m.j]
                grupos.remove(at: m.j)
            }
        }
        juntar(ate: limiarMesmaPessoa) { true }
        if let maximo { juntar(ate: limiarComConvidados) { grupos.count > maximo } }
        return grupos
    }

    /// Nomes prováveis para as vozes sem nome, para você só confirmar:
    /// - quem atendeu quando chamaram alguém pelo nome ("…, Marina?" e logo outra voz responde);
    /// - por eliminação, o único convidado que ainda não tem voz, se só uma voz ficou sem nome.
    static func sugerirNomes(_ vozes: inout [Sessao.Voz], falas: [Sessao.Fala], convidados: [String], livro: LivroDeVozes) {
        var conhecidos: [String] = []
        for n in convidados + vozes.compactMap(\.nome) + livro.vozes.map(\.nome)
        where !conhecidos.contains(where: { Chamados.normalizar($0) == Chamados.normalizar(n) }) { conhecidos.append(n) }
        func jaTem(_ nome: String) -> Bool {
            vozes.contains { v in [v.nome, v.sugestao].compactMap { $0 }.contains { Chamados.casar($0, com: [nome]) != nil || Chamados.casar(nome, com: [$0]) != nil } }
        }
        let porChamado = Chamados.sugerir(falas: falas, conhecidos: conhecidos)
        for i in vozes.indices where vozes[i].nome == nil {
            guard let s = porChamado[vozes[i].id], !jaTem(s.nome) else { continue }
            vozes[i].sugestao = s.nome
            vozes[i].motivo = s.votos == 1 ? "respondeu quando chamaram “\(s.nome)”"
                                            : "respondeu \(s.votos) vezes quando chamaram “\(s.nome)”"
        }
        // por eliminação: um convidado sem voz e uma voz (com fala suficiente) sem nome
        let semVoz = convidados.filter { !jaTem($0) }
        let semNome = vozes.indices.filter { vozes[$0].nome == nil && vozes[$0].sugestao == nil && (vozes[$0].segundos ?? 0) >= Sessao.segundosParaNomear }
        if semVoz.count == 1, semNome.count == 1 {
            vozes[semNome[0]].sugestao = semVoz[0]
            vozes[semNome[0]].motivo = "é o único convidado que ainda não tinha voz"
        }
    }

    /// Impressões de voz em janelas de 3 s com fala em pelo menos 60% delas; no máximo `maximo`, espalhadas
    /// pela chamada inteira.
    private func janelasDeVoz(_ x: [Float], _ blocos: [Range<Int>], maximo: Int) -> [[Float]] {
        let sr = 16000.0
        let ativos = Trechos.ativos(x)
        let tam = Int(Self.janela * sr)
        var faixas: [Range<Int>] = []
        for b in blocos {
            var a = b.lowerBound
            while a + tam <= b.upperBound {
                let f = a..<(a + tam)
                if Trechos.fracaoAtiva(ativos, f) >= 0.6 { faixas.append(f) }
                a += tam
            }
        }
        guard !faixas.isEmpty else { return [] }
        let passo = max(1, faixas.count / maximo)
        return stride(from: 0, to: faixas.count, by: passo).prefix(maximo).compactMap { try? impressao.vetor(x[faixas[$0]]) }
    }
}

/// Limpezas de texto da transcrição.
enum Texto {
    /// Junta frases do Whisper num parágrafo. Se uma frase termina sem pontuação e a seguinte começa com
    /// maiúscula ("Foi o Pedro" + "É do chat"), entra um ponto entre elas.
    static func juntar(_ frases: [String]) -> String {
        var saida = ""
        for f in frases.map({ $0.trimmingCharacters(in: .whitespaces) }) where !f.isEmpty {
            if let ultimo = saida.last, !".?!…,;:".contains(ultimo), f.first?.isUppercase == true { saida += "." }
            saida += saida.isEmpty ? f : " " + f
        }
        return saida
    }

    /// Frase toda em maiúsculas, com pelo menos duas palavras: o Whisper escreve assim quando inventa em cima de
    /// música ou ruído. Siglas soltas ("PR", "CRM") não contam.
    static func gritada(_ s: String) -> Bool {
        let letras = s.filter(\.isLetter)
        guard letras.count >= 8, s.split(separator: " ").count >= 2 else { return false }
        return Double(letras.filter(\.isUppercase).count) / Double(letras.count) >= 0.85
    }

    /// Tokens do Whisper juntados em palavras inteiras (token que começa com espaço abre palavra nova),
    /// com uma chave normalizada para comparar ("Reuniões," == "reuniões").
    static func palavrasInteiras(_ tokens: [Whisper.Palavra]) -> [(tokens: [Whisper.Palavra], chave: String)] {
        var saida: [(tokens: [Whisper.Palavra], chave: String)] = []
        for t in tokens {
            if t.texto.hasPrefix(" ") || saida.isEmpty { saida.append(([t], "")) } else { saida[saida.count - 1].tokens.append(t) }
        }
        for i in saida.indices { saida[i].chave = palavras(saida[i].tokens.map(\.texto).joined()).joined(separator: " ") }
        return saida
    }

    /// Marca as repetições de laço: sequência de 2 a 10 palavras repetida 3+ vezes seguidas (ou uma palavra
    /// 4+ vezes) fica só na primeira vez; as demais voltam marcadas como `true`.
    static func lacos(_ chaves: [String]) -> [Bool] {
        var remover = [Bool](repeating: false, count: chaves.count)
        var i = 0
        while i < chaves.count {
            var pulo = 1
            for n in 1...10 where i + n * 3 <= chaves.count {
                let bloco = Array(chaves[i..<(i + n)])
                if bloco.allSatisfy(\.isEmpty) { continue }
                var reps = 1
                while i + (reps + 1) * n <= chaves.count && Array(chaves[(i + reps * n)..<(i + (reps + 1) * n)]) == bloco { reps += 1 }
                if reps >= (n == 1 ? 4 : 3) {
                    for k in (i + n)..<(i + reps * n) { remover[k] = true }
                    pulo = reps * n
                    break
                }
            }
            i += pulo
        }
        return remover
    }

    private static func palavras(_ s: String) -> [String] {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }
    }

    /// Duas falas dizem quase a mesma coisa (metade das palavras em comum, ou mais).
    static func parecidos(_ a: String, _ b: String) -> Bool {
        let pa = Set(palavras(a)), pb = Set(palavras(b))
        guard !pa.isEmpty, !pb.isEmpty else { return false }
        return Double(pa.intersection(pb).count) / Double(min(pa.count, pb.count)) >= 0.5
    }

    /// Corta os laços do Whisper: frases repetidas e sequências de palavras que se repetem 3+ vezes seguidas.
    static func semRepeticao(_ s: String) -> String {
        // frases já ditas no mesmo trecho saem
        var vistas = Set<String>()
        var frases: [String] = []
        var atual = ""
        for ch in s {
            atual.append(ch)
            if ".!?".contains(ch) {
                frases.append(atual)
                atual = ""
            }
        }
        if !atual.trimmingCharacters(in: .whitespaces).isEmpty { frases.append(atual) }
        var saida = ""
        for f in frases {
            let chave = palavras(f).joined(separator: " ")
            if !chave.isEmpty && vistas.contains(chave) { continue }
            vistas.insert(chave)
            saida += f
        }
        // sequência de 2 a 12 palavras repetida 3+ vezes seguidas vira uma só
        var ws = saida.split(separator: " ").map(String.init)
        var mudou = true
        while mudou {
            mudou = false
            busca: for n in 2...12 where ws.count >= n * 3 {
                for i in 0...(ws.count - n * 3) {
                    let bloco = ws[i..<(i + n)].map { $0.lowercased() }
                    var reps = 1
                    while i + (reps + 1) * n <= ws.count && ws[(i + reps * n)..<(i + (reps + 1) * n)].map({ $0.lowercased() }) == bloco { reps += 1 }
                    if reps >= 3 {
                        ws.removeSubrange((i + n)..<(i + reps * n))
                        mudou = true
                        break busca
                    }
                }
            }
        }
        return ws.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// Transforma a sessão em Markdown.
enum Ata {
    static func tempo(_ s: Double) -> String {
        let t = max(0, Int(s.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%02d:%02d", t / 60, t % 60)
    }

    static func markdown(_ s: Sessao) -> String {
        let dia = DateFormatter()
        dia.locale = Locale(identifier: "pt_BR")
        dia.dateFormat = "dd/MM/yyyy"
        let hora = DateFormatter()
        hora.dateFormat = "HH:mm"
        let minutos = max(1, Int((s.fim.timeIntervalSince(s.inicio) / 60).rounded()))

        var participantes = ["Você"]
        for v in s.vozes where !participantes.contains(s.nome(da: v.id)) { participantes.append(s.nome(da: v.id)) }

        var md = "# \(s.titulo)\n\n"
        md += "- **Data:** \(dia.string(from: s.inicio)), das \(hora.string(from: s.inicio)) às \(hora.string(from: s.fim)) (\(minutos) min)\n"
        if let app = s.app { md += "- **App:** \(app)\n" }
        md += "- **Participantes:** \(participantes.joined(separator: ", "))\n"
        if !s.semNome.isEmpty {
            md += "- **Vozes sem nome:** \(s.semNome.map(\.rotulo).joined(separator: ", ")). Dê nome a elas no menu do Frevo e o app reconhece essas pessoas nas próximas reuniões.\n"
        }
        md += "\n---\n"

        // junta frases seguidas da mesma pessoa
        var atual: (voz: String, inicio: Double, fim: Double, texto: [String])?
        func fechar() {
            guard let a = atual else { return }
            md += "\n**\(s.nome(da: a.voz))** · \(tempo(a.inicio))\n\(Texto.juntar(a.texto))\n"
        }
        for f in s.falas {
            if let a = atual, a.voz == f.voz, f.inicio - a.fim < 6 {
                atual!.texto.append(f.texto)
                atual!.fim = f.fim
            } else {
                fechar()
                atual = (f.voz, f.inicio, f.fim, [f.texto])
            }
        }
        fechar()
        if s.falas.isEmpty { md += "\n_Nenhuma fala reconhecida nesta chamada._\n" }
        return md
    }

    /// ~/Documents/Ligações/2026/11/05/Daily frontend.md (sem sobrescrever outra do mesmo nome).
    static func caminho(para s: Sessao) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: s.inicio)
        let pasta = docs.appendingPathComponent("Ligações")
            .appendingPathComponent(String(c.year!))
            .appendingPathComponent(String(format: "%02d", c.month!))
            .appendingPathComponent(String(format: "%02d", c.day!))
        let limpo = s.titulo.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = pasta.appendingPathComponent("\(limpo).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) && url.path != s.markdown {
            url = pasta.appendingPathComponent("\(limpo) (\(n)).md")
            n += 1
        }
        return url
    }
}
