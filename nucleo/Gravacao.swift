import AVFoundation
import CoreAudio
import Foundation
import Synchronization

/// Uma trilha gravada em WAV mono 16 kHz/16 bits (115 MB por hora com as duas trilhas).
/// As amostras chegam de threads de áudio pelo Anel; um timer comum converte e escreve no disco.
/// Sem arquivo (`url` nil), guarda só na memória os últimos 15 min, até `abrirArquivo` (você ligou a transcrição
/// no meio da chamada e o começo entra junto).
final class Trilha: @unchecked Sendable {
    private(set) var url: URL?
    private let anel: Anel
    private let formatoEntrada: AVAudioFormat
    private var arquivo: AVAudioFile?
    /// Sem arquivo ainda: pedaços em 16 kHz, os mais velhos saem primeiro quando passa do limite. Só a thread comum mexe.
    private var memoria: [[Int16]] = []
    private var naMemoria = 0
    /// Amostras de 16 kHz que não couberam na memória e saíram (o começo que se perdeu).
    private(set) var descartadas = 0
    /// Amostras de 16 kHz já no arquivo (contando as que vieram da memória).
    private(set) var noArquivo = 0
    static var limiteNaMemoria = 16000 * 60 * 15
    private let conversor: AVAudioConverter
    private let bloco: AVAudioPCMBuffer
    private let saida: AVAudioPCMBuffer
    /// mach_absolute_time da primeira amostra (0 = ainda não chegou nada)
    let primeiraAmostra = Atomic<UInt64>(0)
    private let taxa: Double
    private var escritas = 0 // amostras (na taxa de entrada) já gravadas; só a thread comum mexe
    /// Recebe cada pedaço gravado (16 kHz, com o silêncio que completa os buracos), na thread comum.
    var ouvinte: ((UnsafeBufferPointer<Float>) -> Void)?
    private let segundosPorTick: Double = {
        var b = mach_timebase_info_data_t()
        mach_timebase_info(&b)
        return Double(b.numer) / Double(b.denom) / 1e9
    }()

    init(url: URL?, taxa: Double) throws {
        self.url = url
        self.taxa = taxa
        anel = Anel(capacidade: Int(taxa) * 10)
        formatoEntrada = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: taxa, channels: 1, interleaved: false)!
        let alvo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        if let url { arquivo = try Self.criarArquivo(url) }
        conversor = AVAudioConverter(from: formatoEntrada, to: alvo)!
        bloco = AVAudioPCMBuffer(pcmFormat: formatoEntrada, frameCapacity: AVAudioFrameCount(taxa))!
        saida = AVAudioPCMBuffer(pcmFormat: alvo, frameCapacity: 20000)!
    }

    private static func criarArquivo(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    var temArquivo: Bool { arquivo != nil }

    /// Passa a gravar em disco: o que estava na memória vai primeiro para o arquivo. Na thread comum.
    func abrirArquivo(_ url: URL) throws {
        guard arquivo == nil else { return }
        let a = try Self.criarArquivo(url)
        for pedaco in memoria where !pedaco.isEmpty {
            let b = AVAudioPCMBuffer(pcmFormat: saida.format, frameCapacity: AVAudioFrameCount(pedaco.count))!
            let p = b.floatChannelData![0]
            for i in pedaco.indices { p[i] = Float(pedaco[i]) / 32767 }
            b.frameLength = AVAudioFrameCount(pedaco.count)
            try? a.write(from: b)
            noArquivo += pedaco.count
        }
        memoria = []
        naMemoria = 0
        arquivo = a
        self.url = url
    }

    /// Guarda um pedaço convertido na memória (sem arquivo ainda), soltando o mais velho se passar do limite.
    private func guardar(_ p: UnsafePointer<Float>, _ n: Int) {
        memoria.append((0..<n).map { Int16(max(-32767, min(32767, p[$0] * 32767))) })
        naMemoria += n
        while naMemoria > Self.limiteNaMemoria, let velho = memoria.first {
            memoria.removeFirst()
            naMemoria -= velho.count
            descartadas += velho.count
        }
    }

    /// Thread de áudio.
    func empurrar(_ p: UnsafePointer<Float>, _ n: Int) {
        if primeiraAmostra.load(ordering: .relaxed) == 0 { primeiraAmostra.store(mach_absolute_time(), ordering: .relaxed) }
        anel.escrever(p, n)
    }

    /// Thread comum: esvazia o anel no arquivo.
    func drenar() {
        while anel.disponivel > 0 {
            let lidos = anel.ler(bloco.floatChannelData![0], Int(bloco.frameCapacity))
            guard lidos > 0 else { break }
            gravarBloco(lidos)
        }
        // A captura do som do sistema para de entregar áudio quando o app fica em silêncio.
        // Completa o buraco com silêncio pelo relógio, para os horários das falas não andarem.
        let inicio = primeiraAmostra.load(ordering: .relaxed)
        guard inicio > 0 else { return }
        let esperado = Int(Double(mach_absolute_time() - inicio) * segundosPorTick * taxa)
        var falta = esperado - escritas - Int(taxa * 0.2) // 200 ms de folga para o que ainda está a caminho
        guard esperado - escritas > Int(taxa * 0.5), anel.disponivel == 0 else { return }
        let z = bloco.floatChannelData![0]
        while falta > 0 {
            let k = min(falta, Int(bloco.frameCapacity))
            z.update(repeating: 0, count: k)
            gravarBloco(k)
            falta -= k
        }
    }

    private func gravarBloco(_ lidos: Int) {
        escritas += lidos
        do {
            bloco.frameLength = AVAudioFrameCount(lidos)
            var entregue = false
            while true {
                saida.frameLength = 0
                var erro: NSError?
                let st = conversor.convert(to: saida, error: &erro) { _, status in
                    if entregue {
                        status.pointee = .noDataNow
                        return nil
                    }
                    entregue = true
                    status.pointee = .haveData
                    return self.bloco
                }
                if saida.frameLength > 0 {
                    if let arquivo {
                        try? arquivo.write(from: saida)
                        noArquivo += Int(saida.frameLength)
                    } else {
                        guardar(saida.floatChannelData![0], Int(saida.frameLength))
                    }
                    ouvinte?(UnsafeBufferPointer(start: saida.floatChannelData![0], count: Int(saida.frameLength)))
                }
                if st != .haveData { break }
            }
        }
    }

    /// Momento (relógio de parede) da primeira amostra, para alinhar gravações feitas por fora.
    var inicioReal: Date? {
        let t = primeiraAmostra.load(ordering: .relaxed)
        guard t > 0 else { return nil }
        return Date().addingTimeInterval(-Double(mach_absolute_time() - t) * segundosPorTick)
    }

    /// Momento (relógio de parede) da primeira amostra que ficou (sem o começo que não coube na memória).
    var inicioDoArquivo: Date? { inicioReal.map { $0.addingTimeInterval(Double(descartadas) / 16000) } }

    /// O mesmo, no relógio do sistema (segundos), para medir a distância entre duas trilhas.
    var inicioEmSegundos: Double? {
        let t = primeiraAmostra.load(ordering: .relaxed)
        guard t > 0 else { return nil }
        return Double(t) * segundosPorTick + Double(descartadas) / 16000
    }

    func fechar() {
        drenar()
        arquivo?.close()
    }
}

/// Grava uma chamada: sua voz (já limpa pelo filtro) e a dos outros (som do app da chamada).
final class Gravacao: @unchecked Sendable {
    let pasta: URL
    let inicio = Date()
    let voce: Trilha
    private(set) var outros: Trilha?
    private var captura: CapturaDoSistema?
    private let fila = DispatchQueue(label: "io.github.joaopaulosmoura.frevo.gravacao", qos: .utility)
    private var timer: DispatchSourceTimer?
    private(set) var problemaCaptura: String?
    /// Sem arquivos: a chamada fica só na memória (os últimos 15 min) até você ligar a transcrição. Protegido pela `fila`.
    private var memoria: Bool
    /// Quem recebe a trilha dos outros enquanto é gravada (o detector de quem fala). Protegido pela `fila`.
    private var ouvinteDosOutros: ((UnsafeBufferPointer<Float>) -> Void)?

    /// `naMemoria`: não cria pasta nem arquivos; guarda o começo da chamada até `passarParaDisco`.
    init(pasta: URL, naMemoria: Bool = false) throws {
        self.pasta = pasta
        memoria = naMemoria
        if !naMemoria { try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true) }
        voce = try Trilha(url: naMemoria ? nil : pasta.appendingPathComponent("voce.wav"), taxa: Pipeline.taxa)
        let t = DispatchSource.makeTimerSource(queue: fila)
        t.schedule(deadline: .now() + 0.5, repeating: 0.25)
        t.setEventHandler { [weak self] in
            self?.voce.drenar()
            self?.outros?.drenar()
        }
        t.resume()
        timer = t
    }

    private let filaCaptura = DispatchQueue(label: "io.github.joaopaulosmoura.frevo.captura", qos: .userInitiated)
    private var encerrada = false // protegido pela `fila`

    /// Começa a gravar o som dos apps que estão usando o Frevo (Meet, Zoom, Teams...).
    /// Roda em segundo plano: na primeira vez o macOS segura a criação da captura até você responder
    /// ao pedido de permissão, e o filtro do microfone não pode ficar esperando por isso.
    func gravarOutros(processos: [AudioObjectID]) {
        filaCaptura.async { [self] in
            do {
                let c = try CapturaDoSistema(processos: processos) { [pasta] taxa in
                    try Trilha(url: fila.sync { memoria } ? nil : pasta.appendingPathComponent("outros.wav"), taxa: taxa)
                }
                let tarde = fila.sync { () -> Bool in
                    if encerrada { return true }
                    outros = c.trilha
                    // a transcrição foi ligada enquanto a captura nascia
                    if !memoria, let o = outros, !o.temArquivo { try? o.abrirArquivo(pasta.appendingPathComponent("outros.wav")) }
                    outros?.ouvinte = ouvinteDosOutros
                    captura = c
                    return false
                }
                if tarde { c.parar() } // a chamada acabou antes da captura ficar pronta
            } catch {
                fila.sync { problemaCaptura = "\(error)" }
            }
        }
    }

    /// Ainda só na memória (a transcrição não foi ligada nesta chamada)?
    var estaNaMemoria: Bool { fila.sync { memoria } }

    /// Liga a gravação em disco no meio da chamada: cria a pasta e os arquivos, e o que estava na memória vai
    /// primeiro. Devolve o momento do começo da sua trilha (o começo da sessão).
    func passarParaDisco() throws -> Date {
        try FileManager.default.createDirectory(at: pasta, withIntermediateDirectories: true)
        return try fila.sync {
            memoria = false
            try voce.abrirArquivo(pasta.appendingPathComponent("voce.wav"))
            if let o = outros { try o.abrirArquivo(pasta.appendingPathComponent("outros.wav")) }
            return voce.inicioDoArquivo ?? inicio
        }
    }

    /// Passa a trilha dos outros para `f` daqui em diante (o detector de quem fala). Devolve quantos segundos
    /// do arquivo dos outros já existiam (o que veio da memória), para os horários do detector baterem com o arquivo.
    func ouvirOutros(_ f: @escaping (UnsafeBufferPointer<Float>) -> Void) -> Double {
        fila.sync {
            ouvinteDosOutros = f
            outros?.ouvinte = f
            return Double(outros?.noArquivo ?? 0) / 16000
        }
    }

    /// Para tudo e devolve quanto a trilha dos outros começou depois da sua (s).
    func encerrar() -> Double {
        let c = fila.sync { () -> CapturaDoSistema? in
            encerrada = true
            defer { captura = nil }
            return captura
        }
        c?.parar()
        timer?.cancel()
        fila.sync {
            voce.fechar()
            outros?.fechar()
        }
        // contando o começo que não coube na memória (as duas trilhas podem ter perdido tamanhos diferentes)
        guard let a = voce.inicioEmSegundos, let b = outros?.inicioEmSegundos else { return 0 }
        return b - a
    }
}

/// Para onde vai o som capturado (em mono): uma trilha gravada em disco, ou a referência do cancelador de eco.
/// `empurrar` roda na thread de áudio: não pode travar nem alocar.
protocol DestinoDeAudio: AnyObject {
    func empurrar(_ p: UnsafePointer<Float>, _ n: Int)
}

extension Trilha: DestinoDeAudio {}

/// Leva o som do Mac até o cancelador de eco do Pipeline (só memória, nada é gravado).
final class DestinoDaReferencia: DestinoDeAudio, @unchecked Sendable {
    private let anel: Anel
    init(anel: Anel) { self.anel = anel }
    func empurrar(_ p: UnsafePointer<Float>, _ n: Int) { anel.escrever(p, n) }
}

/// Captura o som que um app toca (a voz dos outros na chamada) com um "process tap" do macOS 14.2+.
/// Pede a permissão "Gravação de áudio do sistema" na primeira vez.
final class CapturaDoSistema: @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var agregado = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private(set) var destino: DestinoDeAudio!
    /// A trilha em disco, quando o destino é uma (gravação da chamada).
    var trilha: Trilha! { destino as? Trilha }
    private let mono: UnsafeMutablePointer<Float>
    private let maxQuadros = 16384
    /// Diagnóstico: quadros entregues pela captura, formato anunciado e arranjo real (buffers × 100 + canais).
    let quadrosRecebidos = Atomic<Int>(0)
    let layout = Atomic<Int>(0)
    private(set) var formato = AudioStreamBasicDescription()

    struct Falha: Error, CustomStringConvertible { let description: String }

    init(processos: [AudioObjectID], criarTrilha: (Double) throws -> DestinoDeAudio) throws {
        mono = .allocate(capacity: maxQuadros)
        let desc: CATapDescription
        if processos.isEmpty {
            // sem saber qual app é a chamada: grava todo o som do Mac, menos o nosso
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: Audio.processoProprio().map { [$0] } ?? [])
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processos)
        }
        desc.uuid = UUID()
        desc.name = "Frevo"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else { throw Falha(description: "não consegui criar a captura do som da chamada (\(st))") }

        var fmt = AudioStreamBasicDescription()
        var tam = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var end = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tap, &end, 0, nil, &tam, &fmt)
        guard st == noErr, fmt.mSampleRate > 0 else { throw Falha(description: "formato da captura indisponível (\(st))") }
        destino = try criarTrilha(fmt.mSampleRate)

        let saidaUID = Audio.texto(Audio.saidaPadrao(), kAudioDevicePropertyDeviceUID)
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Frevo Captura",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: saidaUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: saidaUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        st = AudioHardwareCreateAggregateDevice(config as CFDictionary, &agregado)
        guard st == noErr else { throw Falha(description: "não consegui montar o dispositivo de captura (\(st))") }

        formato = fmt
        let destino = self.destino!
        let mono = self.mono
        let maxQ = maxQuadros
        // O agregado entrega primeiro as entradas do dispositivo de saída que serve de relógio (num headset
        // USB, o MICROFONE dele) e só depois a captura. Esses canais iniciais precisam ser pulados, senão a
        // sua voz entra na trilha dos outros e o som da chamada é lido no lugar errado.
        let canaisParaPular = Audio.canais(Audio.saidaPadrao(), entrada: true)
        // a captura é destruída (parar) antes deste objeto, então dá para referenciá-lo sem reter
        let eu = Unmanaged.passUnretained(self)
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, agregado, nil) { _, entrada, _, _, _ in
            let recebidos = eu.takeUnretainedValue()
            let lista = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: entrada))

            // separa os buffers da captura (depois dos canais do dispositivo de saída)
            var pulados = 0
            var n = Int.max
            var totalCanais = 0
            var arranjo = 0
            for b in lista {
                let canais = Int(max(b.mNumberChannels, 1))
                if pulados < canaisParaPular {
                    pulados += canais
                    continue
                }
                n = min(n, Int(b.mDataByteSize) / 4 / canais)
                totalCanais += canais
                arranjo = arranjo * 10 + canais
            }
            guard totalCanais > 0, n != Int.max else { return }
            n = min(n, maxQ)
            if recebidos.layout.load(ordering: .relaxed) == 0 { recebidos.layout.store(lista.count * 100 + arranjo, ordering: .relaxed) }
            recebidos.quadrosRecebidos.add(n, ordering: .relaxed)

            // mistura todos os canais da captura em mono, respeitando o arranjo de cada buffer
            for i in 0..<n { mono[i] = 0 }
            pulados = 0
            for b in lista {
                let canais = Int(max(b.mNumberChannels, 1))
                if pulados < canaisParaPular {
                    pulados += canais
                    continue
                }
                guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<canais { s += d[i * canais + c] }
                    mono[i] += s
                }
            }
            let k = 1 / Float(totalCanais)
            for i in 0..<n { mono[i] *= k }
            destino.empurrar(mono, n)
        }
        guard st == noErr else { throw Falha(description: "não consegui ler a captura (\(st))") }
        st = AudioDeviceStart(agregado, proc)
        guard st == noErr else { throw Falha(description: "não consegui ligar a captura (\(st))") }
    }

    /// Dispara o pedido de permissão "Gravação de áudio do sistema" fora de uma chamada:
    /// monta uma captura de tudo (menos este app) e desmonta logo em seguida. Bloqueia até a resposta,
    /// então chame em segundo plano.
    static func pedirPermissao() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("frevo-permissao-\(UUID().uuidString).wav")
        if let c = try? CapturaDoSistema(processos: [], criarTrilha: { try Trilha(url: tmp, taxa: $0) }) {
            c.parar()
            c.trilha.fechar()
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    func parar() {
        if let proc {
            AudioDeviceStop(agregado, proc)
            AudioDeviceDestroyIOProcID(agregado, proc)
        }
        proc = nil
        if agregado != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agregado) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        agregado = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        parar()
        mono.deallocate()
    }
}

extension Audio {
    static func saidaPadrao() -> AudioObjectID {
        valor(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, padrao: AudioObjectID(0))
    }

    static func processoProprio() -> AudioObjectID? {
        var end = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var obj = AudioObjectID(kAudioObjectUnknown)
        var tam = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &end,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &tam, &obj)
        return st == noErr && obj != kAudioObjectUnknown ? obj : nil
    }

    /// Todos os processos que o Core Audio conhece, menos o próprio Frevo.
    static func processos() -> [AudioObjectID] {
        var end = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var tam: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &end, 0, nil, &tam) == noErr else { return [] }
        var lista = [AudioObjectID](repeating: 0, count: Int(tam) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &end, 0, nil, &tam, &lista) == noErr else { return [] }
        let proprio = processoProprio()
        return lista.filter { $0 != proprio }
    }

    /// Processos (objetos de áudio) que estão lendo um dispositivo de entrada: o app da chamada.
    static func processosUsando(_ dispositivo: AudioObjectID, entre todos: [AudioObjectID]? = nil) -> [AudioObjectID] {
        (todos ?? processos()).filter { p in
            var e = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyDevices, mScope: kAudioObjectPropertyScopeInput,
                                               mElement: kAudioObjectPropertyElementMain)
            var t: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(p, &e, 0, nil, &t) == noErr, t > 0 else { return false }
            var ids = [AudioObjectID](repeating: 0, count: Int(t) / MemoryLayout<AudioObjectID>.size)
            guard AudioObjectGetPropertyData(p, &e, 0, nil, &t, &ids) == noErr else { return false }
            return ids.contains(dispositivo)
        }
    }

    /// App dono de um processo de áudio: o bundle sem o sufixo do processo auxiliar
    /// ("com.google.Chrome.helper" → "com.google.Chrome", "net.whatsapp.WhatsApp.ServiceExtension" → "net.whatsapp.WhatsApp").
    static func familia(_ processo: AudioObjectID) -> String {
        let b = texto(processo, kAudioProcessPropertyBundleID)
        if b.isEmpty { return "pid \(valor(processo, kAudioProcessPropertyPID, padrao: pid_t(0)))" }
        return b.split(separator: ".").prefix(3).joined(separator: ".")
    }

    static func tocandoSom(_ processo: AudioObjectID) -> Bool {
        valor(processo, kAudioProcessPropertyIsRunningOutput, padrao: UInt32(0)) != 0
    }

    /// Processos de uma chamada: quem usa o microfone e, do mesmo app, quem está tocando som (a voz dos outros).
    /// Vazio quando nenhum app que usa o microfone toca som: aí é um áudio de WhatsApp, um ditado,
    /// uma gravação, não uma conversa.
    static func processosDaChamada(_ mic: AudioObjectID) -> (usando: [AudioObjectID], tocando: [AudioObjectID]) {
        let todos = processos()
        let usando = processosUsando(mic, entre: todos)
        let familias = Set(usando.map(familia))
        let tocando = todos.filter { familias.contains(familia($0)) && tocandoSom($0) }
        return (usando, tocando)
    }

    /// Nome amigável do app de um processo de áudio ("Google Chrome", "zoom.us"...).
    static func nomeDoApp(_ processo: AudioObjectID) -> String? {
        let bundle = texto(processo, kAudioProcessPropertyBundleID)
        if bundle.hasPrefix("com.google.Chrome") { return "Google Chrome" }
        if bundle.hasPrefix("us.zoom") { return "Zoom" }
        if bundle.hasPrefix("com.microsoft.teams") { return "Microsoft Teams" }
        if bundle.hasPrefix("com.apple.WebKit") || bundle.hasPrefix("com.apple.Safari") { return "Safari" }
        if bundle.hasPrefix("com.tinyspeck.slackmacgap") { return "Slack" }
        let pid: pid_t = valor(processo, kAudioProcessPropertyPID, padrao: pid_t(0))
        return pid > 0 ? NSRunningApplicationNome(pid) ?? (bundle.isEmpty ? nil : bundle) : nil
    }
}

/// Nome do app pelo PID, sem depender do AppKit no núcleo.
private func NSRunningApplicationNome(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    let caminho = String(cString: buf)
    if let app = caminho.range(of: ".app/") {
        return URL(fileURLWithPath: String(caminho[..<app.lowerBound])).lastPathComponent
    }
    return URL(fileURLWithPath: caminho).lastPathComponent
}
