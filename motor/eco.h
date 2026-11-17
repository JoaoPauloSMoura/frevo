// Cancelador de eco do WebRTC (AEC3, o mesmo do Chrome e do Meet), numa ponte em C para o Swift.
// Tira da voz do microfone o som que o Mac está tocando (a voz dos outros saindo do alto-falante).
// Implementação em motor/eco.cpp; biblioteca montada por scripts/compilar-eco.sh.
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

typedef struct Eco Eco;

/// Cria o cancelador para um microfone mono em `taxa` Hz (quadros de 10 ms).
Eco *eco_criar(int taxa);
void eco_destruir(Eco *e);

/// O som que o Mac tocou: 10 ms em mono (taxa / 100 amostras), em qualquer taxa.
void eco_referencia(Eco *e, const float *ref, int taxa);

/// Limpa 10 ms do microfone (taxa / 100 amostras). `atraso_ms`: palpite de quanto o eco chega depois da
/// referência (o cancelador acha o atraso certo sozinho). Pode escrever em cima da entrada (mic == saida).
/// Devolve 0 se deu certo.
int eco_limpar(Eco *e, const float *mic, float *saida, int atraso_ms);

typedef struct {
    float erle_db;  ///< quanto o eco foi reduzido (dB); < 0 se ainda não há medida
    float erl_db;   ///< quanto o eco já chega mais baixo que a referência (dB); < 0 se não há medida
    int atraso_ms;  ///< atraso do eco que o cancelador encontrou; -1 se não há medida
} EcoMedidas;

EcoMedidas eco_medidas(Eco *e);

#ifdef __cplusplus
}
#endif
