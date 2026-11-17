// Interface C da libDF (DeepFilterNet, MIT/Apache-2.0), feature "capi".
// Escrita à mão a partir de third_party/DeepFilterNet/libDF/src/capi.rs.
#ifndef DEEP_FILTER_H
#define DEEP_FILTER_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DFState DFState;

/// Carrega o modelo (.tar.gz do DeepFilterNet3) e prepara o estado (STFT, rede, ISTFT).
/// atten_lim: quanto no máximo tirar, em dB (100 = sem limite).
/// log_level: NULL para não registrar nada. Aborta o processo se o modelo não abrir.
DFState *df_create(const char *path, float atten_lim, const char *log_level);

/// Tamanho do quadro em amostras (480 = 10 ms em 48 kHz).
size_t df_get_frame_length(DFState *st);

/// Muda o limite de redução em dB.
void df_set_atten_lim(DFState *st, float lim_db);

/// Pós-filtro (0 = desligado). Valores pequenos (0,02) tiram mais ruído entre palavras.
void df_set_post_filter_beta(DFState *st, float beta);

/// Processa um quadro de df_get_frame_length() amostras. Devolve o SNR local do quadro.
float df_process_frame(DFState *st, float *input, float *output);

void df_free(DFState *st);

#ifdef __cplusplus
}
#endif

#endif
