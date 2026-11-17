"""Mede uma ou mais transcrições da conversa de teste contra o gabarito, e entre si.

    python comparar.py conversa/gabarito.json mac=falas-mac.json windows=falas-windows.json

Para cada transcrição (o --falas do transcrever): quantas palavras saíram erradas, quantas vozes apareceram
e quanto da fala ficou com a pessoa certa. Com duas ou mais, diz também o quanto elas concordam entre si.
"""

import json
import re
import sys
import unicodedata
from difflib import SequenceMatcher


def palavras(texto: str) -> list[str]:
    t = unicodedata.normalize("NFKD", texto.lower())
    t = "".join(c for c in t if not unicodedata.combining(c))
    return re.findall(r"[a-z0-9]+", t)


def erro_de_palavras(certo: list[str], obtido: list[str]) -> float:
    """Distância de edição entre as listas de palavras, sobre o total certo (o "WER")."""
    anterior = list(range(len(obtido) + 1))
    for i, a in enumerate(certo, 1):
        atual = [i]
        for j, b in enumerate(obtido, 1):
            atual.append(min(anterior[j] + 1, atual[j - 1] + 1, anterior[j - 1] + (a != b)))
        anterior = atual
    return anterior[-1] / max(1, len(certo))


def sobreposicao(a, b) -> float:
    return max(0.0, min(a["fim"], b["fim"]) - max(a["inicio"], b["inicio"]))


def medir(gabarito, falas):
    texto_certo = [p for g in gabarito for p in palavras(g["texto"])]
    texto_obtido = [p for f in sorted(falas, key=lambda f: f["inicio"]) for p in palavras(f["texto"])]
    # cada rótulo (Pessoa 1, Você…) vira a pessoa com quem mais coincide no tempo
    tempo = {}
    for f in falas:
        for g in gabarito:
            s = sobreposicao(f, g)
            if s > 0:
                tempo.setdefault(f["quem"], {}).setdefault(g["quem"], 0.0)
                tempo[f["quem"]][g["quem"]] += s
    mapa = {rotulo: max(d, key=d.get) for rotulo, d in tempo.items()}
    certo = sum(d.get(mapa[r], 0) for r, d in tempo.items())
    total = sum(sum(d.values()) for d in tempo.values())
    outros = {g["quem"] for g in gabarito if g["quem"] != "Você"}
    vozes = {f["quem"] for f in falas if f["quem"] != "Você"}
    return {
        "erro_palavras": erro_de_palavras(texto_certo, texto_obtido),
        "vozes": len(vozes),
        "pessoas": len(outros),
        "fala_certa": certo / total if total else 0.0,
        "mapa": mapa,
        "texto": " ".join(texto_obtido),
    }


def main() -> None:
    sys.stdout.reconfigure(encoding="utf-8")  # o terminal do Windows não é UTF-8 por padrão
    gabarito = json.load(open(sys.argv[1], encoding="utf-8"))
    resultados = {}
    for arg in sys.argv[2:]:
        nome, caminho = arg.split("=", 1)
        resultados[nome] = medir(gabarito, json.load(open(caminho, encoding="utf-8")))
    for nome, r in resultados.items():
        print(f"{nome}: {100 * r['erro_palavras']:.1f}% de palavras erradas · {r['vozes']} vozes para {r['pessoas']} pessoas"
              f" · {100 * r['fala_certa']:.0f}% da fala com a pessoa certa")
        print("   " + ", ".join(f"{k} → {v}" for k, v in sorted(r["mapa"].items())))
    nomes = list(resultados)
    for i, a in enumerate(nomes):
        for b in nomes[i + 1:]:
            igual = SequenceMatcher(None, resultados[a]["texto"].split(), resultados[b]["texto"].split()).ratio()
            print(f"{a} × {b}: textos {100 * igual:.1f}% iguais")


if __name__ == "__main__":
    main()
