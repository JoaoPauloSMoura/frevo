import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Fila de amostras com um produtor e um consumidor, sem trava.
/// O produtor é a thread de áudio do microfone; o consumidor, a do Frevo Feed.
final class Anel: @unchecked Sendable {
    let capacidade: Int
    private let buf: UnsafeMutablePointer<Float>
    private let escritas = Atomic<Int>(0)
    private let lidas = Atomic<Int>(0)

    init(capacidade: Int) {
        self.capacidade = capacidade
        buf = .allocate(capacity: capacidade)
        buf.initialize(repeating: 0, count: capacidade)
    }

    deinit { buf.deallocate() }

    var disponivel: Int { escritas.load(ordering: .acquiring) - lidas.load(ordering: .acquiring) }

    /// Só o produtor chama. Se a fila estiver cheia, o excesso é descartado.
    @discardableResult
    func escrever(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
        let e = escritas.load(ordering: .relaxed)
        let l = lidas.load(ordering: .acquiring)
        let k = min(n, capacidade - (e - l))
        for i in 0..<k { buf[(e + i) % capacidade] = p[i] }
        escritas.store(e + k, ordering: .releasing)
        return k
    }

    /// Só o consumidor chama.
    func ler(_ p: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        let l = lidas.load(ordering: .relaxed)
        let e = escritas.load(ordering: .acquiring)
        let k = min(n, e - l)
        for i in 0..<k { p[i] = buf[(l + i) % capacidade] }
        lidas.store(l + k, ordering: .releasing)
        return k
    }

    /// Só o consumidor chama: pula amostras para reduzir a latência.
    func descartar(_ n: Int) {
        let l = lidas.load(ordering: .relaxed)
        let e = escritas.load(ordering: .acquiring)
        lidas.store(l + min(n, e - l), ordering: .releasing)
    }
}

/// Microfone físico → DeepFilterNet3 → Frevo Feed (que o driver entrega como "Frevo").
///
/// Duas AudioUnits HAL: uma lê o microfone, outra escreve no Feed. Entre elas, o Anel.
/// O filtro roda na thread de áudio do microfone, em quadros de 10 ms.
final class Pipeline: @unchecked Sendable {
    let motor: Motor
    let micID: AudioObjectID
    let feedID: AudioObjectID
    static let taxa: Double = 48000

    private var entrada: AudioUnit?
    private var saida: AudioUnit?
    private let anel = Anel(capacidade: 48000) // 1 s de folga

    // thread do microfone
    private let maxIO = 8192
    private let bufIO: UnsafeMutablePointer<Float>
    private let acumulado: UnsafeMutablePointer<Float>
    private let limpo: UnsafeMutablePointer<Float>
    private var nAcumulado = 0

    // thread do Feed
    private var aquecendo = true

    let filtroLigado = Atomic<Bool>(true)
    /// Volume antes e depois do filtro, para a onda do painel.
    let medidor = Medidor()

    // Cancelador de eco (WebRTC AEC3): tira da sua voz o som que o Mac está tocando, antes do filtro de ruído.
    // A referência (o som do Mac) chega de uma captura do sistema, noutra thread, por este anel.
    let ecoLigado = Atomic<Bool>(true)
    private let eco: OpaquePointer?
    private let referencia = Anel(capacidade: 96000)
    /// Taxa da referência em Hz; 0 = ainda não há referência (o cancelador fica de fora).
    private let taxaReferencia = Atomic<Int>(0)
    private let bufReferencia: UnsafeMutablePointer<Float>
    private let semEco: UnsafeMutablePointer<Float>
    /// Palpite do atraso do eco para o cancelador (ele acha o certo sozinho): alto-falante + ar + microfone.
    private static let atrasoDoEcoMs: Int32 = 40

    // estatísticas (escritas por uma thread só, lidas pelo relatório)
    let quadros = Atomic<Int>(0)
    let nanos = Atomic<Int>(0)
    let piorNanos = Atomic<Int>(0)
    let faltas = Atomic<Int>(0)
    let descartes = Atomic<Int>(0)
    /// Cresce a cada bloco que chega do microfone. Se parar, o áudio do Mac caiu (ex.: driver reinstalado).
    let blocosRecebidos = Atomic<Int>(0)
    private var inicioJanela = DispatchTime.now()

    struct Falha: Error, CustomStringConvertible {
        let description: String
    }

    /// Trilha que recebe a voz já limpa (para a transcrição da chamada), trocada sem parar o áudio:
    /// a gravação começa alguns instantes depois do filtro, quando o app confirma que é uma chamada.
    /// Guarda o ponteiro (Unmanaged) da trilha; 0 = não grava.
    private let trilhaAtual = Atomic<UInt>(0)
    /// Toda trilha já entregue fica viva até o filtro parar: a thread de áudio pode estar no meio de uma escrita
    /// quando ela é trocada. Escrever numa trilha encerrada é inofensivo (só enche o anel dela).
    private var trilhasRetidas: [Trilha] = []

    init(motor: Motor, mic: AudioObjectID, feed: AudioObjectID, trilhaVoz: Trilha? = nil) {
        self.motor = motor
        micID = mic
        feedID = feed
        bufIO = .allocate(capacity: maxIO)
        acumulado = .allocate(capacity: motor.quadro)
        limpo = .allocate(capacity: motor.quadro)
        limpo.initialize(repeating: 0, count: motor.quadro)
        eco = eco_criar(Int32(Self.taxa))
        bufReferencia = .allocate(capacity: 2048)
        semEco = .allocate(capacity: motor.quadro)
        semEco.initialize(repeating: 0, count: motor.quadro)
        gravarVoz(em: trilhaVoz)
    }

    /// Recebe o som do Mac para o cancelador de eco. Chame com a taxa da captura; devolve onde a captura escreve.
    func receberReferencia(taxa: Double) -> DestinoDeAudio {
        taxaReferencia.store(Int(taxa), ordering: .releasing)
        return DestinoDaReferencia(anel: referencia)
    }

    /// A captura do som do Mac parou: o cancelador sai do caminho até voltar.
    func perderReferencia() {
        taxaReferencia.store(0, ordering: .releasing)
    }

    /// O que o cancelador está conseguindo (nil se ele ainda não está no caminho).
    func medidasDoEco() -> EcoMedidas? {
        guard let eco, ecoLigado.load(ordering: .relaxed), taxaReferencia.load(ordering: .relaxed) > 0 else { return nil }
        return eco_medidas(eco)
    }

    var taxaDaReferencia: Int { taxaReferencia.load(ordering: .relaxed) }

    /// Passa a gravar a voz limpa em `trilha` (nil = para de gravar). Thread principal.
    func gravarVoz(em trilha: Trilha?) {
        if let trilha { trilhasRetidas.append(trilha) }
        let bits = trilha.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        trilhaAtual.store(bits, ordering: .releasing)
    }

    deinit {
        parar()
        bufIO.deallocate()
        acumulado.deallocate()
        limpo.deallocate()
        if let eco { eco_destruir(eco) }
        bufReferencia.deallocate()
        semEco.deallocate()
    }

    // MARK: montagem

    private func checar(_ st: OSStatus, _ oQue: String) throws {
        if st != noErr { throw Falha(description: "\(oQue) falhou (código \(st))") }
    }

    private func novaHAL() throws -> AudioUnit {
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                             componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { throw Falha(description: "AUHAL não encontrada") }
        var u: AudioUnit?
        try checar(AudioComponentInstanceNew(comp, &u), "criar AUHAL")
        return u!
    }

    private func definir<T>(_ u: AudioUnit, _ prop: AudioUnitPropertyID, _ escopo: AudioUnitScope,
                            _ elemento: AudioUnitElement, _ valor: T, _ oQue: String) throws {
        var v = valor
        try checar(AudioUnitSetProperty(u, prop, escopo, elemento, &v, UInt32(MemoryLayout<T>.size)), oQue)
    }

    private var formato: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: Self.taxa, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
                                    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                    mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    }

    func iniciar() throws {
        let eu = Unmanaged.passUnretained(self).toOpaque()

        // Lado do microfone: AUHAL só com entrada
        let e = try novaHAL()
        try definir(e, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, UInt32(1), "ligar entrada")
        try definir(e, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, UInt32(0), "desligar saída")
        try definir(e, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, micID, "escolher microfone")
        try definir(e, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, formato, "formato do microfone")
        try definir(e, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1, Int32(0), "usar o canal 1 do microfone")
        try definir(e, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(maxIO), "tamanho máximo")
        try definir(e, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                    AURenderCallbackStruct(inputProc: aoChegarAudio, inputProcRefCon: eu), "callback do microfone")
        try checar(AudioUnitInitialize(e), "iniciar microfone")
        entrada = e

        // Lado do Feed: AUHAL só com saída
        let s = try novaHAL()
        try definir(s, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, feedID, "escolher Frevo Feed")
        try definir(s, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, formato, "formato do Feed")
        try definir(s, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                    AURenderCallbackStruct(inputProc: aoPedirAudio, inputProcRefCon: eu), "callback do Feed")
        try checar(AudioUnitInitialize(s), "iniciar Feed")
        saida = s

        inicioJanela = .now()
        try checar(AudioOutputUnitStart(s), "ligar Feed")
        try checar(AudioOutputUnitStart(e), "ligar microfone")
    }

    func parar() {
        for u in [entrada, saida].compactMap({ $0 }) {
            AudioOutputUnitStop(u)
            AudioUnitUninitialize(u)
            AudioComponentInstanceDispose(u)
        }
        entrada = nil
        saida = nil
    }

    // MARK: tempo real

    /// Thread do microfone: passa ao cancelador o som que o Mac tocou desde o último quadro e tira o eco de 10 ms
    /// do microfone. Sem referência (ou desligado), devolve o próprio microfone.
    private func tirarEco(_ mic: UnsafeMutablePointer<Float>) -> UnsafeMutablePointer<Float> {
        guard let eco, ecoLigado.load(ordering: .relaxed) else { return mic }
        let taxaRef = taxaReferencia.load(ordering: .acquiring)
        guard taxaRef > 0 else { return mic }
        let qr = taxaRef / 100
        guard qr <= 2048 else { return mic }
        // se a referência acumulou (o microfone ficou parado um tempo), fica só com o mais recente
        let disp = referencia.disponivel
        if disp > 10 * qr { referencia.descartar(disp - 2 * qr) }
        while referencia.disponivel >= qr {
            _ = referencia.ler(bufReferencia, qr)
            eco_referencia(eco, bufReferencia, Int32(taxaRef))
        }
        return eco_limpar(eco, mic, semEco, Self.atrasoDoEcoMs) == 0 ? semEco : mic
    }

    /// Thread do microfone: junta 10 ms, limpa e põe no anel.
    fileprivate func receber(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ n: UInt32) -> OSStatus {
        guard let e = entrada, Int(n) <= maxIO else { return noErr }
        var lista = AudioBufferList(mNumberBuffers: 1,
                                    mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: n * 4,
                                                          mData: UnsafeMutableRawPointer(bufIO)))
        let st = AudioUnitRender(e, flags, ts, bus, n, &lista)
        if st != noErr { return st }
        blocosRecebidos.add(1, ordering: .relaxed)

        let q = motor.quadro
        var i = 0
        while i < Int(n) {
            let k = min(q - nAcumulado, Int(n) - i)
            (acumulado + nAcumulado).update(from: bufIO + i, count: k)
            nAcumulado += k
            i += k
            if nAcumulado == q {
                let t0 = DispatchTime.now().uptimeNanoseconds
                let entradaDoFiltro = tirarEco(acumulado)
                if filtroLigado.load(ordering: .relaxed) {
                    motor.processar(entradaDoFiltro, limpo)
                } else {
                    limpo.update(from: entradaDoFiltro, count: q)
                }
                let dt = Int(DispatchTime.now().uptimeNanoseconds - t0)
                quadros.add(1, ordering: .relaxed)
                nanos.add(dt, ordering: .relaxed)
                if dt > piorNanos.load(ordering: .relaxed) { piorNanos.store(dt, ordering: .relaxed) }
                anel.escrever(limpo, q)
                medidor.registrar(antes: acumulado, depois: limpo, n: q)
                let bits = trilhaAtual.load(ordering: .acquiring)
                if bits != 0, let ptr = UnsafeRawPointer(bitPattern: bits) {
                    Unmanaged<Trilha>.fromOpaque(ptr)._withUnsafeGuaranteedRef { $0.empurrar(limpo, q) }
                }
                nAcumulado = 0
            }
        }
        return noErr
    }

    /// Thread do Feed: entrega o que já foi limpo, mantendo a fila curta (latência baixa).
    fileprivate func entregar(_ n: UInt32, _ io: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let io, let dados = UnsafeMutableAudioBufferListPointer(io)[0].mData?.assumingMemoryBound(to: Float.self)
        else { return noErr }
        let pedido = Int(n)
        let q = motor.quadro
        let disp = anel.disponivel

        if aquecendo {
            guard disp >= pedido + q else {
                dados.update(repeating: 0, count: pedido)
                return noErr
            }
            aquecendo = false
        }
        // O relógio do microfone e o do Mac andam um pouquinho diferente; se acumular
        // mais de 40 ms de sobra, pulamos o excesso para a latência não crescer.
        if disp > pedido + 4 * q {
            anel.descartar(disp - (pedido + q))
            descartes.add(1, ordering: .relaxed)
        }
        let lidos = anel.ler(dados, pedido)
        if lidos < pedido {
            (dados + lidos).update(repeating: 0, count: pedido - lidos)
            faltas.add(1, ordering: .relaxed)
            aquecendo = true
        }
        return noErr
    }

    // MARK: relatório

    struct Medidas {
        var msPorQuadro = 0.0
        var piorMs = 0.0
        var cpu = 0.0 // % do tempo de um núcleo
        var filaMs = 0.0
        var faltas = 0
        var pulos = 0
    }

    /// Medidas desde a última chamada (zera os contadores).
    func medir() -> Medidas {
        let agora = DispatchTime.now()
        let janela = Double(agora.uptimeNanoseconds - inicioJanela.uptimeNanoseconds) / 1e9
        inicioJanela = agora
        let nq = quadros.exchange(0, ordering: .relaxed)
        let ns = nanos.exchange(0, ordering: .relaxed)
        return Medidas(msPorQuadro: nq > 0 ? Double(ns) / Double(nq) / 1e6 : 0,
                       piorMs: Double(piorNanos.exchange(0, ordering: .relaxed)) / 1e6,
                       cpu: janela > 0 ? Double(ns) / 1e9 / janela * 100 : 0,
                       filaMs: Double(anel.disponivel) / Self.taxa * 1000,
                       faltas: faltas.exchange(0, ordering: .relaxed),
                       pulos: descartes.exchange(0, ordering: .relaxed))
    }

    /// Resumo em uma linha para o app de terminal.
    func resumo() -> String {
        let m = medir()
        let ligado = filtroLigado.load(ordering: .relaxed) ? "ligado" : "DESLIGADO"
        return String(format: "filtro %@ · %.2f ms por quadro (pior %.2f) · CPU %.1f%% de um núcleo · fila %.0f ms · faltas %d · pulos %d",
                      ligado, m.msPorQuadro, m.piorMs, m.cpu, m.filaMs, m.faltas, m.pulos)
    }
}

// Callbacks C das AudioUnits: só repassam para o Pipeline.
private func aoChegarAudio(_ refCon: UnsafeMutableRawPointer,
                           _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                           _ ts: UnsafePointer<AudioTimeStamp>,
                           _ bus: UInt32, _ n: UInt32,
                           _: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<Pipeline>.fromOpaque(refCon).takeUnretainedValue().receber(flags, ts, bus, n)
}

private func aoPedirAudio(_ refCon: UnsafeMutableRawPointer,
                          _: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                          _: UnsafePointer<AudioTimeStamp>,
                          _: UInt32, _ n: UInt32,
                          _ io: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<Pipeline>.fromOpaque(refCon).takeUnretainedValue().entregar(n, io)
}
