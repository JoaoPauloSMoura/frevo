// Ponte em C para o processamento de áudio do WebRTC (webrtc-audio-processing 2.1, BSD).
// Só o cancelador de eco (AEC3) e o filtro de graves ficam ligados: o ruído é com o DeepFilterNet, e o
// ganho automático fica com o app da chamada.
#include "eco.h"

#include <modules/audio_processing/include/audio_processing.h>

struct Eco {
    rtc::scoped_refptr<webrtc::AudioProcessing> apm;
    int taxa;
};

extern "C" Eco *eco_criar(int taxa) {
    auto apm = webrtc::AudioProcessingBuilder().Create();
    if (!apm) return nullptr;
    webrtc::AudioProcessing::Config c;
    c.pipeline.maximum_internal_processing_rate = 48000; // sem isso ele trabalharia a 32 kHz e cortaria os agudos
    c.echo_canceller.enabled = true;
    c.echo_canceller.mobile_mode = false;
    c.high_pass_filter.enabled = true;
    c.noise_suppression.enabled = false;
    c.gain_controller1.enabled = false;
    c.gain_controller2.enabled = false;
    apm->ApplyConfig(c);
    return new Eco{apm, taxa};
}

extern "C" void eco_destruir(Eco *e) { delete e; }

extern "C" void eco_referencia(Eco *e, const float *ref, int taxa) {
    webrtc::StreamConfig sc(taxa, 1);
    const float *canais[1] = {ref};
    e->apm->AnalyzeReverseStream(canais, sc);
}

extern "C" int eco_limpar(Eco *e, const float *mic, float *saida, int atraso_ms) {
    webrtc::StreamConfig sc(e->taxa, 1);
    const float *entrada[1] = {mic};
    float *sai[1] = {saida};
    e->apm->set_stream_delay_ms(atraso_ms);
    return e->apm->ProcessStream(entrada, sc, sc, sai);
}

extern "C" EcoMedidas eco_medidas(Eco *e) {
    auto s = e->apm->GetStatistics();
    EcoMedidas m{-1, -1, -1};
    if (s.echo_return_loss_enhancement) m.erle_db = static_cast<float>(*s.echo_return_loss_enhancement);
    if (s.echo_return_loss) m.erl_db = static_cast<float>(*s.echo_return_loss);
    if (s.delay_ms) m.atraso_ms = *s.delay_ms;
    return m;
}
