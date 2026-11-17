import CoreAudio
import Foundation

/// Um dispositivo de áudio do Core Audio.
struct Dispositivo {
    let id: AudioObjectID
    let nome: String
    let uid: String
    let canaisEntrada: Int
    let canaisSaida: Int
    let transporte: UInt32

    /// Microfone de verdade: não é virtual (Krisp, BlackHole...), agregado, nem o do iPhone.
    var fisico: Bool {
        ![kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
          kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeContinuityCaptureWired,
          kAudioDeviceTransportTypeContinuityCaptureWireless, kAudioDeviceTransportTypeUnknown].contains(transporte)
    }
}

enum Audio {
    static let uidMic = "io.github.joaopaulosmoura.frevo.input"
    static let uidFeed = "io.github.joaopaulosmoura.frevo.feed"

    private static func endereco(_ sel: AudioObjectPropertySelector,
                                 _ escopo: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: escopo, mElement: kAudioObjectPropertyElementMain)
    }

    static func valor<T: BitwiseCopyable>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                         escopo: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, padrao: T) -> T {
        var end = endereco(sel, escopo)
        var v = padrao
        var tam = UInt32(MemoryLayout<T>.size)
        let st = AudioObjectGetPropertyData(obj, &end, 0, nil, &tam, &v)
        return st == noErr ? v : padrao
    }

    static func texto(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
        var end = endereco(sel)
        var cf: Unmanaged<CFString>?
        var tam = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &end, 0, nil, &tam, &cf) == noErr, let s = cf else { return "" }
        return s.takeRetainedValue() as String
    }

    static func canais(_ id: AudioObjectID, entrada: Bool) -> Int {
        var end = endereco(kAudioDevicePropertyStreamConfiguration,
                           entrada ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput)
        var tam: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &end, 0, nil, &tam) == noErr, tam > 0 else { return 0 }
        let mem = UnsafeMutableRawPointer.allocate(byteCount: Int(tam), alignment: 16)
        defer { mem.deallocate() }
        guard AudioObjectGetPropertyData(id, &end, 0, nil, &tam, mem) == noErr else { return 0 }
        let lista = UnsafeMutableAudioBufferListPointer(mem.assumingMemoryBound(to: AudioBufferList.self))
        return lista.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func dispositivo(_ id: AudioObjectID) -> Dispositivo {
        Dispositivo(id: id, nome: texto(id, kAudioObjectPropertyName), uid: texto(id, kAudioDevicePropertyDeviceUID),
                    canaisEntrada: canais(id, entrada: true), canaisSaida: canais(id, entrada: false),
                    transporte: valor(id, kAudioDevicePropertyTransportType, padrao: UInt32(0)))
    }

    /// Dispositivos visíveis (os ocultos, como o Frevo Feed, não aparecem aqui).
    static func todos() -> [Dispositivo] {
        var end = endereco(kAudioHardwarePropertyDevices)
        var tam: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &end, 0, nil, &tam) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(tam) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &end, 0, nil, &tam, &ids) == noErr else { return [] }
        return ids.map(dispositivo)
    }

    static func porUID(_ uid: String) -> AudioObjectID? {
        var end = endereco(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUid = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var tam = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cfUid) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &end,
                                       UInt32(MemoryLayout<CFString>.size), p, &tam, &id)
        }
        return st == noErr && id != kAudioObjectUnknown ? id : nil
    }

    static func entradaPadrao() -> AudioObjectID {
        valor(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, padrao: AudioObjectID(0))
    }

    /// Microfones físicos: tudo que tem entrada, menos o nosso.
    static func microfones() -> [Dispositivo] {
        todos().filter { $0.canaisEntrada > 0 && $0.uid != uidMic }
    }

    /// Escolha automática: o microfone padrão do Mac, se for físico; senão um headset USB,
    /// depois Bluetooth, depois o do próprio Mac.
    static func microfoneAutomatico(_ lista: [Dispositivo] = microfones()) -> Dispositivo? {
        let fisicos = lista.filter(\.fisico)
        if let padrao = fisicos.first(where: { $0.id == entradaPadrao() }) { return padrao }
        for t in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBuiltIn] {
            if let m = fisicos.first(where: { $0.transporte == t }) { return m }
        }
        return fisicos.first
    }

    /// Algum app (Zoom, Meet, Teams...) está lendo este dispositivo agora?
    static func emUso(_ id: AudioObjectID) -> Bool {
        valor(id, kAudioDevicePropertyDeviceIsRunningSomewhere, padrao: UInt32(0)) != 0
    }

    static func taxa(_ id: AudioObjectID) -> Double {
        valor(id, kAudioDevicePropertyNominalSampleRate, padrao: 0.0)
    }

    /// Tenta pôr o dispositivo em 48 kHz (o DeepFilterNet3 trabalha nessa taxa).
    static func definirTaxa(_ id: AudioObjectID, _ hz: Double) -> Bool {
        if taxa(id) == hz { return true }
        var end = endereco(kAudioDevicePropertyNominalSampleRate)
        var v = hz
        guard AudioObjectSetPropertyData(id, &end, 0, nil, UInt32(MemoryLayout<Double>.size), &v) == noErr else { return false }
        for _ in 0..<50 where taxa(id) != hz { usleep(20_000) } // a troca é assíncrona
        return taxa(id) == hz
    }
}
