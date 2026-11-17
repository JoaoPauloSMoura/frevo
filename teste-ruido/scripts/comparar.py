"""Compara modelos open source de supressão de ruído no mesmo áudio.

Uso:
    .venv/bin/python -I scripts/comparar.py <arquivo de áudio> [nome-do-teste]

Gera resultados/<nome>/ com um .wav por modelo, espectrogramas, dados.json
e index.html (player A/B). Tudo roda offline, na CPU, 1 thread.
"""

from __future__ import annotations

import json
import platform
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf

RAIZ = Path(__file__).resolve().parent.parent
MODELOS = RAIZ / "modelos"
SR = 48000
CADASTRO: Path | None = None  # --cadastro <arquivo>: 3+ s só da sua voz, de outra gravação


# ---------------------------------------------------------------- modelos

def rodar_rnnoise(x: np.ndarray) -> tuple[np.ndarray, float]:
    from pyrnnoise.rnnoise import FRAME_SIZE, create, destroy, process_mono_frame

    estado = create()
    pcm = np.clip(x * 32767, -32768, 32767).astype(np.int16)
    saida = np.zeros_like(pcm)
    t0 = time.perf_counter()
    for i in range(0, len(pcm), FRAME_SIZE):
        quadro, _ = process_mono_frame(estado, pcm[i : i + FRAME_SIZE])
        saida[i : i + len(quadro)] = quadro
    dt = time.perf_counter() - t0
    destroy(estado)
    return saida.astype(np.float32) / 32767, dt


def rodar_deepfilternet(entrada_wav: Path, limite_db: float | None) -> tuple[np.ndarray, float]:
    with tempfile.TemporaryDirectory() as tmp:
        cmd = [str(MODELOS / "deep-filter"), "-v", "-D", "-o", tmp]
        if limite_db is not None:
            cmd += ["-a", str(limite_db)]
        log = subprocess.run(cmd + [str(entrada_wav)], capture_output=True, text=True, check=True)
        rtf = float(re.search(r"RTF: ([0-9.]+)", log.stderr + log.stdout).group(1))
        y, sr = sf.read(Path(tmp) / entrada_wav.name, dtype="float32")
    assert sr == SR
    return y, rtf * len(y) / SR


def rodar_dpdfnet(x: np.ndarray, modelo: str) -> tuple[np.ndarray, float]:
    import dpdfnet

    dpdfnet.download(modelo)  # baixa antes, fora da medição
    t0 = time.perf_counter()
    y = dpdfnet.enhance(x, SR, model=modelo)
    return y, time.perf_counter() - t0


def rodar_gtcrn(x: np.ndarray) -> tuple[np.ndarray, float]:
    import librosa
    import sherpa_onnx as so

    cfg = so.OnlineSpeechDenoiserConfig(
        model=so.OfflineSpeechDenoiserModelConfig(
            gtcrn=so.OfflineSpeechDenoiserGtcrnModelConfig(model=str(MODELOS / "gtcrn_simple.onnx")),
            num_threads=1,
        )
    )
    den = so.OnlineSpeechDenoiser(cfg)
    x16 = librosa.resample(x, orig_sr=SR, target_sr=16000)
    partes = []
    passo = 160  # 10 ms, como num app de verdade
    t0 = time.perf_counter()
    for i in range(0, len(x16), passo):
        partes.append(np.asarray(den(x16[i : i + passo].tolist(), 16000).samples, dtype=np.float32))
    partes.append(np.asarray(den.flush().samples, dtype=np.float32))
    dt = time.perf_counter() - t0
    y16 = np.concatenate(partes)
    y = librosa.resample(y16, orig_sr=16000, target_sr=SR)
    return y, dt


def rodar_voxlock(x: np.ndarray, com_cadastro: bool) -> tuple[np.ndarray, float]:
    import soxr
    import voxlock
    from voxlock.core import loud_sample

    vl = voxlock.VoxLock(threads=1)  # int8; baixa o modelo na 1ª vez
    x16 = soxr.resample(x, SR, 16000).astype(np.float32)
    # "cadastro": 3 s da sua voz. Aqui sai do começo do próprio áudio; no app seria gravado uma vez.
    if com_cadastro:
        from voxlock.core import load_audio

        amostra = load_audio(str(CADASTRO)) if CADASTRO else loud_sample(x16)
        fluxo = vl.stream(amostra)
    else:
        fluxo = vl.live()
    partes = []
    t0 = time.perf_counter()
    for i in range(0, len(x16), 320):  # 20 ms por vez, como num app
        partes.append(fluxo.push(x16[i : i + 320]))
    partes.append(fluxo.flush())
    dt = time.perf_counter() - t0
    return soxr.resample(np.concatenate(partes), 16000, SR).astype(np.float32), dt


_cache: dict = {}


def memo(chave: str, fn):
    """Evita rodar o mesmo modelo duas vezes quando ele entra numa combinação."""
    if chave not in _cache:
        _cache[chave] = fn()
    return _cache[chave]


def rodar_apple(wav: Path, tipo: int = 0) -> tuple[np.ndarray, float]:
    """Isolamento de voz da Apple (AUSoundIsolation). tipo 0 = voz alta qualidade."""
    binario = RAIZ / "bin" / "apple_isolamento"
    if not binario.exists():
        binario.parent.mkdir(exist_ok=True)
        subprocess.run(
            ["swiftc", "-O", "-o", str(binario), str(RAIZ / "scripts" / "apple_isolamento.swift")],
            check=True, capture_output=True,
        )
    with tempfile.TemporaryDirectory() as tmp:
        saida = Path(tmp) / "apple.wav"
        r = subprocess.run([str(binario), str(wav), str(saida), str(tipo), "100"], capture_output=True, text=True, check=True)
        segundos = float(re.search(r"segundos=([0-9.]+)", r.stdout).group(1))
        y, _ = sf.read(saida, dtype="float32")
    return (y[:, 0] if y.ndim > 1 else y), segundos


def porteiro(base: np.ndarray, x: np.ndarray, y_vox: np.ndarray, decidido: bool) -> np.ndarray:
    """Aplica em `base` a decisão do VoxLock, a cada 10 ms: a voz é sua (passa) ou de outra pessoa (abaixa).

    decidido=False: versão anterior, ganho proporcional ao que o VoxLock manteve, piso de -30 dB.
    decidido=True: abre por inteiro quando o VoxLock manteve quase tudo (sua voz fica intacta),
    fecha de vez (-50 dB) quando ele cortou, segura aberto 60 ms para não comer fim de palavra
    e fecha 40 ms antes, aproveitando o atraso que o isolamento da Apple já tem.
    """
    import soxr

    ref = soxr.resample(soxr.resample(x, SR, 16000), 16000, SR)  # mesma banda do VoxLock
    q = 480  # 10 ms
    n = min(len(ref), len(y_vox), len(base)) // q
    e_in = np.mean(ref[: n * q].reshape(n, q) ** 2, axis=1) + 1e-10
    e_vox = np.mean(y_vox[: n * q].reshape(n, q) ** 2, axis=1) + 1e-12
    if not decidido:
        g = np.sqrt(np.clip(e_vox / e_in, 0, 1))
        suave, a = np.empty_like(g), 0.0
        for i, gi in enumerate(g):  # abre na hora, fecha em ~30 ms
            a = gi if gi > a else 0.7 * a + 0.3 * gi
            suave[i] = a
        ganho_db = 20 * np.log10(np.maximum(suave, 10 ** (-30 / 20)))
    else:
        manteve_db = 10 * np.log10(e_vox / e_in)
        piso = -50.0
        alvo = np.interp(manteve_db, [-20, -8], [piso, 0])  # >= -8 dB: sua voz, passa inteira
        alvo = np.array([alvo[i : i + 5].min() for i in range(n)])  # olha 40 ms à frente
        ganho_db, a, segura = np.empty(n), piso, 0
        for i, t in enumerate(alvo):
            if t >= a:
                a, segura = t, 6  # abre na hora e segura 60 ms
            elif segura > 0:
                segura -= 1
            else:
                a = max(t, a - 6.0)  # fecha descendo 6 dB a cada 10 ms
            ganho_db[i] = a
    ganho = np.interp(np.arange(len(base)), np.arange(n) * q + q / 2, 10 ** (ganho_db / 20))
    return (base * ganho).astype(np.float32)


def rodar_combo(x: np.ndarray, wav: Path, base: str, decidido: bool) -> tuple[np.ndarray, float]:
    if base == "dfn3":
        y_base, t1 = memo("dfn3", lambda: rodar_deepfilternet(wav, None))
    else:
        y_base, t1 = memo("apple", lambda: rodar_apple(wav))
    y_vox, t2 = memo("voxlock_cadastro", lambda: rodar_voxlock(x, com_cadastro=True))
    t0 = time.perf_counter()
    y = porteiro(y_base, x, y_vox, decidido)
    return y, t1 + t2 + time.perf_counter() - t0


VERSOES = [
    {
        "id": "original",
        "nome": "Original",
        "desc": "Seu áudio, sem nenhum tratamento.",
        "licenca": "",
        "latencia": "",
        "banda": "48 kHz",
    },
    {
        "id": "rnnoise",
        "nome": "RNNoise",
        "desc": "Clássico, levíssimo. Usado pelo Frisp e por muitos plugins.",
        "licenca": "BSD",
        "latencia": "~10 ms",
        "banda": "48 kHz",
        "rodar": lambda x, wav: rodar_rnnoise(x),
    },
    {
        "id": "dfn3",
        "nome": "DeepFilterNet3",
        "desc": "Supressão máxima. Usado pelo NoNoise-Mac, MetalVoice e sotto.",
        "licenca": "MIT/Apache",
        "latencia": "~40 ms",
        "banda": "48 kHz",
        "rodar": lambda x, wav: memo("dfn3", lambda: rodar_deepfilternet(wav, None)),
    },
    {
        "id": "dpdfnet2",
        "nome": "DPDFNet-2 48k",
        "desc": "Evolução do DeepFilterNet (Ceva, 2025), versão leve. Usado pelo Krasp.",
        "licenca": "Apache-2.0",
        "latencia": "~20 ms",
        "banda": "48 kHz",
        "rodar": lambda x, wav: rodar_dpdfnet(x, "dpdfnet2_48khz_hr"),
    },
    {
        "id": "apple",
        "nome": "Isolamento de voz da Apple",
        "desc": "O modelo que vem no macOS (o mesmo tipo do FaceTime e do Final Cut). Soa natural e quase não pesa, mas mantém qualquer voz.",
        "licenca": "Grátis no macOS 13+",
        "latencia": "~90 ms",
        "banda": "48 kHz",
        "rodar": lambda x, wav: memo("apple", lambda: rodar_apple(wav)),
    },
    {
        "id": "voxlock_cadastro",
        "nome": "VoxLock · com cadastro da voz",
        "desc": "Mantém só a voz cadastrada e corta as outras (3 s da sua voz tirados do começo deste áudio; no app seria um cadastro único).",
        "licenca": "Apache-2.0",
        "latencia": "~45 ms",
        "banda": "16 kHz",
        "rodar": lambda x, wav: memo("voxlock_cadastro", lambda: rodar_voxlock(x, com_cadastro=True)),
    },
    {
        "id": "dfn3_porteiro",
        "nome": "DeepFilterNet3 + porteiro (anterior)",
        "desc": "A combinação que você já ouviu: o VoxLock abaixa a voz dos outros, mas de forma proporcional e no máximo 30 dB.",
        "licenca": "MIT + Apache-2.0",
        "latencia": "~45 ms",
        "banda": "48 kHz",
        "rodar": lambda x, wav: rodar_combo(x, wav, "dfn3", decidido=False),
    },
    {
        "id": "dfn3_porteiro2",
        "nome": "DeepFilterNet3 + porteiro decidido",
        "desc": "Porteiro novo: deixa sua voz passar inteira, fecha de vez (−50 dB) quando é outra pessoa e segura o fim das palavras.",
        "licenca": "MIT + Apache-2.0",
        "latencia": "~45 ms",
        "banda": "48 kHz",
        "rodar": lambda x, wav: rodar_combo(x, wav, "dfn3", decidido=True),
    },
    {
        "id": "apple_porteiro2",
        "nome": "Apple + porteiro decidido",
        "desc": "Isolamento da Apple para o ruído (voz mais natural) e o porteiro novo do VoxLock para cortar as outras vozes.",
        "licenca": "macOS + Apache-2.0",
        "latencia": "~90 ms",
        "banda": "48 kHz",
        "rodar": lambda x, wav: rodar_combo(x, wav, "apple", decidido=True),
    },
]


# ---------------------------------------------------------------- medições

def nota_dnsmos(y: np.ndarray) -> dict:
    import librosa
    from speechmos import dnsmos

    y16 = librosa.resample(y, orig_sr=SR, target_sr=16000)
    y16 = np.clip(y16, -1, 1)
    r = dnsmos.run(y16, 16000)
    return {"voz": round(float(r["sig_mos"]), 2), "fundo": round(float(r["bak_mos"]), 2), "geral": round(float(r["ovrl_mos"]), 2)}


def mascaras(x: np.ndarray, quadro: int = 960) -> tuple[np.ndarray, np.ndarray]:
    """Quadros de 20 ms do original: só ruído (pausas) e voz forte."""
    n = len(x) // quadro
    db = 10 * np.log10(np.mean(x[: n * quadro].reshape(n, quadro) ** 2, axis=1) + 1e-12)
    ruido = db <= np.percentile(db, 15)
    # descarta bordas de fala: o quadro e os 2 vizinhos de cada lado precisam ser pausa
    ruido = np.array([ruido[max(0, i - 2) : i + 3].all() for i in range(n)])
    voz = db >= np.percentile(db, 70)
    return ruido, voz


def niveis(y: np.ndarray, ruido: np.ndarray, voz: np.ndarray, quadro: int = 960) -> tuple[float, float]:
    n = len(ruido)
    p = np.mean(y[: n * quadro].reshape(n, quadro) ** 2, axis=1) + 1e-12
    return float(10 * np.log10(p[ruido].mean())), float(10 * np.log10(p[voz].mean()))


def trechos_cortados(x, y_base, y_port, quadro: int = 960) -> list:
    """Onde o porteiro derrubou algo com volume de fala (provável voz de outra pessoa)."""
    if y_base is None or y_port is None:
        return []
    n = len(x) // quadro
    db = lambda y: 10 * np.log10(np.mean(y[: n * quadro].reshape(n, quadro) ** 2, axis=1) + 1e-12)
    l0, lb, lp = db(x), db(y_base), db(y_port)
    cortado = (l0 > np.percentile(l0, 50)) & (lb - lp >= 20)
    trechos, ini, fim = [], None, None
    for i, c in enumerate(cortado):
        t = i * quadro / SR
        if c:
            if ini is None:
                ini = t
            elif t - fim > 0.15:  # junta pedaços a menos de 150 ms
                trechos.append([ini, fim])
                ini = t
            fim = t + quadro / SR
    if ini is not None:
        trechos.append([ini, fim])
    return [[round(a, 2), round(b, 2)] for a, b in trechos if b - a >= 0.15]


def espectrograma(wav: Path, png: Path) -> None:
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-lavfi",
            "showspectrumpic=s=1600x360:legend=0:scale=log:fscale=lin:color=intensity:gain=1.4",
            str(png),
        ],
        check=True,
    )


def cpu_nome() -> str:
    try:
        return subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
    except Exception:
        return platform.processor()


# ---------------------------------------------------------------- principal

def main() -> None:
    abrir = "--abrir" in sys.argv
    trecho = None  # --trecho 17-18: janela (s) com voz de outra pessoa, para medir o corte
    args = []
    resto = iter(sys.argv[1:])
    for a in resto:
        if a == "--abrir":
            continue
        if a == "--cadastro":
            global CADASTRO
            CADASTRO = Path(next(resto)).expanduser().resolve()
            continue
        if a == "--trecho":
            ini, fim = next(resto).split("-")
            trecho = (float(ini), float(fim))
            continue
        args.append(a)
    if not args:
        sys.exit(__doc__)
    origem = Path(args[0]).expanduser().resolve()
    nome = args[1] if len(args) > 1 else re.sub(r"[^a-z0-9]+", "-", origem.stem.lower()).strip("-")
    pasta = RAIZ / "resultados" / nome
    pasta.mkdir(parents=True, exist_ok=True)

    wav_original = pasta / "original.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-loglevel", "error", "-i", str(origem), "-ac", "1", "-ar", str(SR), "-c:a", "pcm_s16le", str(wav_original)],
        check=True,
    )
    x, _ = sf.read(wav_original, dtype="float32")
    duracao = len(x) / SR
    m_ruido, m_voz = mascaras(x)
    ruido_orig, voz_orig = niveis(x, m_ruido, m_voz)

    resultados = []
    saidas = {}
    for v in VERSOES:
        print(f"→ {v['nome']}…", flush=True)
        wav = pasta / f"{v['id']}.wav"
        item = {k: val for k, val in v.items() if k != "rodar"}
        if "rodar" in v:
            y, segundos = v["rodar"](x, wav_original)
            y = np.asarray(y, dtype=np.float32)
            y = np.pad(y, (0, max(0, len(x) - len(y))))[: len(x)]
            sf.write(wav, y, SR, subtype="PCM_16")
            item["cpu"] = round(100 * segundos / duracao, 2)  # % de 1 núcleo
        else:
            y = x
        saidas[v['id']] = y
        espectrograma(wav, pasta / f"{v['id']}.png")
        item["nota"] = nota_dnsmos(y)
        r_db, v_db = niveis(y, m_ruido, m_voz)
        item["ruido_removido_db"] = round(ruido_orig - r_db, 1)  # quanto o chiado das pausas caiu
        item["voz_db"] = round(v_db - voz_orig, 1)  # quanto o volume da voz mudou
        if trecho:
            a, b = int(trecho[0] * SR), int(trecho[1] * SR)
            nivel = lambda s: 10 * np.log10(np.mean(s[a:b] ** 2) + 1e-12)
            item["corte_trecho_db"] = round(float(nivel(x) - nivel(y)), 1)
        print(
            f"   cpu={item.get('cpu', '-')}%  nota={item['nota']}  "
            f"ruído -{item['ruido_removido_db']} dB  voz {item['voz_db']:+} dB",
            flush=True,
        )
        if CADASTRO and v['id'] == 'voxlock_cadastro':
            item['desc'] = 'Mantém só a voz cadastrada e corta as outras. O cadastro são 3 s da sua voz tirados de outra gravação, como seria no app.'
        resultados.append(item)

    dados = {
        "arquivo": origem.name,
        "duracao": round(duracao, 1),
        "maquina": f"{cpu_nome()} · macOS {platform.mac_ver()[0]}",
        "data": time.strftime("%d/%m/%Y"),
        "trecho": trecho,
        "cortes": trechos_cortados(x, saidas.get("dfn3"), saidas.get("dfn3_porteiro2")),
        "versoes": resultados,
    }
    (pasta / "dados.json").write_text(json.dumps(dados, ensure_ascii=False, indent=2))

    sys.path.insert(0, str(Path(__file__).parent))
    from pagina import gerar

    pagina = gerar(pasta, dados)
    print(f"\nPronto: {pagina}")
    if abrir:
        subprocess.run(["open", str(pagina)])


if __name__ == "__main__":
    main()
