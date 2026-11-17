// Frevo: driver de áudio virtual (AudioServerPlugIn) feito com libASPL.
//
// Cria dois dispositivos que compartilham um buffer circular:
//   - "Frevo" (entrada, visível): o microfone que Zoom, Meet e Teams enxergam.
//   - "Frevo Feed" (saída, oculta): o app Frevo escreve aqui a voz já limpa.
// Tudo o que o app escreve no Feed sai no Frevo, como um cabo virtual de um sentido só.
//
// Os dois dispositivos usam o mesmo relógio (mesma âncora de tempo), então a amostra
// escrita para o instante T no Feed é lida no instante T no Mic. É o mesmo truque do
// BlackHole, só que separado em dois dispositivos para o Feed não aparecer como alto-falante.

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include <atomic>
#include <cstring>

namespace {

constexpr UInt32 kTaxa = 48000;          // DeepFilterNet3 trabalha em 48 kHz
constexpr UInt32 kCanais = 1;            // voz mono
constexpr UInt32 kPeriodo = 16384;       // quadros entre carimbos do relógio (igual ao BlackHole; não muda a latência)
constexpr UInt64 kAnelQuadros = 1 << 18; // ~5,4 s de áudio em 48 kHz
constexpr UInt64 kMascara = kAnelQuadros - 1;

// Estado compartilhado entre os dois dispositivos (mesmo processo: coreaudiod).
float gAnel[kAnelQuadros] = {};
std::atomic<Float64> gFimEscrito{-1.0}; // instante logo depois da última amostra escrita
const UInt64 gAncora = mach_absolute_time();

AudioStreamBasicDescription FormatoFloatMono()
{
    AudioStreamBasicDescription f = {};
    f.mSampleRate = kTaxa;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                     kAudioFormatFlagIsPacked;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = kCanais;
    f.mBytesPerFrame = 4 * kCanais;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 4 * kCanais;
    return f;
}

// Dispositivo cujo relógio parte de uma âncora comum aos dois, em vez de reiniciar
// a cada StartIO. Assim o "instante T" significa a mesma coisa no Feed e no Mic.
class DispositivoRelogioComum : public aspl::Device
{
public:
    using aspl::Device::Device;

protected:
    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override
    {
        static const Float64 ticksPorQuadro = [] {
            mach_timebase_info_data_t base;
            mach_timebase_info(&base);
            return (Float64(base.denom) / base.numer) * 1e9 / kTaxa;
        }();
        const Float64 ticksPorPeriodo = ticksPorQuadro * kPeriodo;
        const UInt64 agora = mach_absolute_time();
        const UInt64 periodo = UInt64(Float64(agora - gAncora) / ticksPorPeriodo);

        *outSampleTime = Float64(periodo * kPeriodo);
        *outHostTime = gAncora + UInt64(Float64(periodo) * ticksPorPeriodo);
        *outSeed = 1;
        return kAudioHardwareNoError;
    }
};

// Feed: recebe a voz limpa do app e guarda no anel, na posição do instante dela.
class ManipuladorFeed : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64 instante,
        const void* bytes,
        UInt32 nBytes) override
    {
        const auto* amostras = static_cast<const float*>(bytes);
        const UInt64 quadros = nBytes / sizeof(float) / kCanais;
        const auto t0 = UInt64(instante);
        for (UInt64 i = 0; i < quadros; i++) {
            gAnel[(t0 + i) & kMascara] = amostras[i * kCanais];
        }
        gFimEscrito.store(instante + Float64(quadros), std::memory_order_release);
    }
};

// Mic: entrega aos apps de chamada o que o Feed escreveu para aquele instante.
// Se o app Frevo não estiver rodando (nada novo no anel), entrega silêncio,
// para nunca repetir áudio velho.
class ManipuladorMic : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    void OnReadClientInput(const std::shared_ptr<aspl::Client>&,
        const std::shared_ptr<aspl::Stream>&,
        Float64,
        Float64 instante,
        void* bytes,
        UInt32 nBytes) override
    {
        auto* amostras = static_cast<float*>(bytes);
        const UInt64 quadros = nBytes / sizeof(float) / kCanais;
        const Float64 fim = gFimEscrito.load(std::memory_order_acquire);
        // só vale o trecho já escrito e que ainda não foi sobrescrito por uma volta do anel
        const Float64 inicioValido = fim - Float64(kAnelQuadros) + kTaxa; // folga de 1 s

        for (UInt64 i = 0; i < quadros; i++) {
            const Float64 t = instante + Float64(i);
            const float v = (fim > 0 && t < fim && t >= inicioValido)
                                ? gAnel[UInt64(t) & kMascara]
                                : 0.0f;
            for (UInt32 c = 0; c < kCanais; c++) {
                amostras[i * kCanais + c] = v;
            }
        }
    }
};

std::shared_ptr<aspl::Driver> CriarDriver()
{
    auto contexto = std::make_shared<aspl::Context>();

    aspl::StreamParameters fluxo;
    fluxo.Format = FormatoFloatMono();

    // Microfone visível
    aspl::DeviceParameters pMic;
    pMic.Name = "Frevo";
    pMic.Manufacturer = "Frevo";
    pMic.DeviceUID = "io.github.joaopaulosmoura.frevo.input";
    pMic.ModelUID = "io.github.joaopaulosmoura.frevo";
    pMic.SampleRate = kTaxa;
    pMic.ChannelCount = kCanais;
    pMic.ZeroTimeStampPeriod = kPeriodo;
    pMic.CanBeDefaultForSystemSounds = false;
    auto mic = std::make_shared<DispositivoRelogioComum>(contexto, pMic);
    fluxo.Direction = aspl::Direction::Input;
    mic->AddStreamWithControlsAsync(fluxo);
    auto mMic = std::make_shared<ManipuladorMic>();
    mic->SetControlHandler(mMic);
    mic->SetIOHandler(mMic);

    // Entrada oculta para o app escrever a voz limpa
    aspl::DeviceParameters pFeed;
    pFeed.Name = "Frevo Feed";
    pFeed.Manufacturer = "Frevo";
    pFeed.DeviceUID = "io.github.joaopaulosmoura.frevo.feed";
    pFeed.ModelUID = "io.github.joaopaulosmoura.frevo";
    pFeed.SampleRate = kTaxa;
    pFeed.ChannelCount = kCanais;
    pFeed.ZeroTimeStampPeriod = kPeriodo;
    pFeed.CanBeDefault = false;
    pFeed.CanBeDefaultForSystemSounds = false;
    auto feed = std::make_shared<DispositivoRelogioComum>(contexto, pFeed);
    fluxo.Direction = aspl::Direction::Output;
    feed->AddStreamAsync(fluxo); // sem volume/mudo: o app controla o nível
    feed->SetIsHidden(true);
    auto mFeed = std::make_shared<ManipuladorFeed>();
    feed->SetControlHandler(mFeed);
    feed->SetIOHandler(mFeed);

    auto plugin = std::make_shared<aspl::Plugin>(contexto);
    plugin->AddDevice(mic);
    plugin->AddDevice(feed);

    return std::make_shared<aspl::Driver>(contexto, plugin);
}

} // namespace

extern "C" void* FrevoEntryPoint(CFAllocatorRef, CFUUIDRef tipo)
{
    if (!CFEqual(tipo, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }
    static std::shared_ptr<aspl::Driver> driver = CriarDriver();
    return driver->GetReference();
}
