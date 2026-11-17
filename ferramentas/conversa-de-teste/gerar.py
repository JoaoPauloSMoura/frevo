"""Gera uma reunião inventada, com vozes sintéticas, para testar a transcrição sem gravar ninguém de verdade.

Lê o roteiro.txt, fala cada linha com uma voz do Piper (pip install piper-tts==1.8.0) e monta duas gravações
de 16 kHz, como o app grava numa chamada: voce.wav (o seu microfone) e outros.wav (o som da chamada). Também
grava gabarito.json, com quem disse o quê e quando, para medir o resultado.

    python gerar.py --saida conversa [--vozes pasta-das-vozes]
"""

import argparse
import json
import random
import wave
from pathlib import Path

import numpy as np
from piper import PiperVoice, SynthesisConfig
from piper.download_voices import download_voice

# quem fala → (gravação, voz do Piper). Uma voz diferente para cada pessoa, todas do português do Brasil.
VOZES = {
    "Você": ("voce", "pt_BR-faber-medium"),
    "Bruno": ("outros", "pt_BR-cadu-medium"),
    "Paulo": ("outros", "pt_BR-jeff-medium"),
    "Pedro": ("outros", "pt_BR-edresson-low"),
}
TAXA = 16000


def reamostrar(x: np.ndarray, de: int, para: int) -> np.ndarray:
    """Troca a taxa de amostragem pelo espectro (sem dependências além do numpy)."""
    if de == para:
        return x
    n = int(round(len(x) * para / de))
    espectro = np.fft.rfft(x)
    novo = np.zeros(n // 2 + 1, dtype=complex)
    k = min(len(espectro), len(novo))
    novo[:k] = espectro[:k]
    return np.fft.irfft(novo, n) * (n / len(x))


def falar(voz: PiperVoice, texto: str) -> np.ndarray:
    partes, taxa = [], voz.config.sample_rate
    for pedaco in voz.synthesize(texto, syn_config=SynthesisConfig(length_scale=1.0)):
        partes.append(pedaco.audio_float_array)
        taxa = pedaco.sample_rate
    return reamostrar(np.concatenate(partes), taxa, TAXA).astype(np.float32)


def gravar(caminho: Path, x: np.ndarray) -> None:
    with wave.open(str(caminho), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(TAXA)
        w.writeframes((np.clip(x, -1, 1) * 32767).astype("<i2").tobytes())


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--saida", default="conversa")
    p.add_argument("--vozes", default="vozes-piper", help="pasta onde as vozes do Piper ficam (baixadas uma vez)")
    p.add_argument("--roteiro", default=str(Path(__file__).with_name("roteiro.txt")))
    a = p.parse_args()

    pasta_vozes, saida = Path(a.vozes), Path(a.saida)
    pasta_vozes.mkdir(parents=True, exist_ok=True)
    saida.mkdir(parents=True, exist_ok=True)
    vozes = {}
    for quem, (_, nome) in VOZES.items():
        if not (pasta_vozes / f"{nome}.onnx").exists():
            download_voice(nome, pasta_vozes)
        vozes[quem] = PiperVoice.load(pasta_vozes / f"{nome}.onnx")

    linhas = []
    for linha in Path(a.roteiro).read_text(encoding="utf-8").splitlines():
        if linha.strip() and not linha.startswith("#"):
            quem, texto = (s.strip() for s in linha.split("|", 1))
            linhas.append((quem, texto))

    sorteio = random.Random(7)  # pausas entre falas variadas, mas sempre as mesmas
    t = 1.0
    trechos, gabarito = [], []
    for quem, texto in linhas:
        x = falar(vozes[quem], texto)
        trechos.append((VOZES[quem][0], int(t * TAXA), x))
        gabarito.append({"inicio": round(t, 2), "fim": round(t + len(x) / TAXA, 2), "quem": quem, "texto": texto})
        t += len(x) / TAXA + sorteio.uniform(0.35, 0.9)

    total = int((t + 1.0) * TAXA)
    faixas = {"voce": np.zeros(total, np.float32), "outros": np.zeros(total, np.float32)}
    for faixa, ini, x in trechos:
        faixas[faixa][ini:ini + len(x)] += x
    for faixa, x in faixas.items():
        gravar(saida / f"{faixa}.wav", x * 0.7)
    (saida / "gabarito.json").write_text(json.dumps(gabarito, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"{len(linhas)} falas, {t:.0f} s, em {saida}/")


if __name__ == "__main__":
    main()
