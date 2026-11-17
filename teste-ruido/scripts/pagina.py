"""Gera o index.html (player A/B) a partir de dados.json."""

from __future__ import annotations

import json
import sys
from pathlib import Path

HTML = r"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Teste de ruído</title>
<style>
:root {
  --bg: #f6f5f2; --card: #ffffff; --ink: #1d1d1b; --ink-2: #5d5c57; --ink-3: #8c8a83;
  --line: #e4e2dc; --accent: #e8590c; --accent-soft: #fff1e8; --good: #2b8a3e; --bar: #d9d6cf;
  --spec-bg: #0b0b12;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #131312; --card: #1d1d1b; --ink: #f1efe9; --ink-2: #b4b1a8; --ink-3: #85827a;
    --line: #2f2e2b; --accent: #ff8a3d; --accent-soft: #2e1e12; --good: #69db7c; --bar: #3a3935;
  }
}
:root[data-theme="dark"] {
  --bg: #131312; --card: #1d1d1b; --ink: #f1efe9; --ink-2: #b4b1a8; --ink-3: #85827a;
  --line: #2f2e2b; --accent: #ff8a3d; --accent-soft: #2e1e12; --good: #69db7c; --bar: #3a3935;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--ink);
  font: 15px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif; }
main { max-width: 1040px; margin: 0 auto; padding: 32px 16px 64px; }
h1 { font-size: 26px; line-height: 1.2; margin: 0 0 6px; letter-spacing: -0.01em; }
.meta { color: var(--ink-2); font-size: 13px; }
.card { background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 20px; margin-top: 20px; }
.destaque { display: flex; gap: 14px; align-items: flex-start; background: var(--accent-soft); border-color: transparent; }
.destaque b { color: var(--ink); }
.destaque .icone { font-size: 20px; line-height: 1.2; }

/* player */
.transporte { display: flex; align-items: center; gap: 14px; }
.play { width: 48px; height: 48px; border-radius: 50%; border: 0; background: var(--accent); color: #fff;
  font-size: 18px; cursor: pointer; flex: none; display: grid; place-items: center; }
.play:focus-visible { outline: 3px solid var(--ink); outline-offset: 2px; }
.tempo { font-variant-numeric: tabular-nums; color: var(--ink-2); font-size: 13px; min-width: 92px; }
.ativo-nome { font-weight: 600; }
.espectro { position: relative; margin-top: 16px; border-radius: 10px; overflow: hidden; background: var(--spec-bg); cursor: pointer; }
.espectro img { display: block; width: 100%; height: 150px; object-fit: fill; }
.espectro .cabeca { position: absolute; top: 0; bottom: 0; width: 2px; background: #fff; box-shadow: 0 0 6px rgba(255,255,255,.8); left: 0; pointer-events: none; }
.espectro .rotulo { position: absolute; left: 10px; top: 8px; font-size: 11px; color: rgba(255,255,255,.75); }
.espectro .rotulo-b { top: auto; bottom: 8px; }
.dica { color: var(--ink-3); font-size: 12px; margin-top: 10px; }
kbd { font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; border: 1px solid var(--line); border-bottom-width: 2px;
  border-radius: 4px; padding: 0 5px; background: var(--bg); color: var(--ink-2); }

/* lista */
.lista { margin-top: 8px; }
.cab, .linha { display: grid; grid-template-columns: 28px minmax(180px, 2.2fr) 1.3fr 0.9fr 0.9fr 0.9fr 0.8fr; gap: 12px; align-items: center; }
.com-trecho .cab, .com-trecho .linha { grid-template-columns: 28px minmax(180px, 2.2fr) 1.2fr 0.7fr 0.9fr 0.9fr 0.8fr 0.8fr; }
.trecho-faixa { position: absolute; top: 0; bottom: 0; background: rgba(255,255,255,.14); border-left: 1px dashed rgba(255,255,255,.6);
  border-right: 1px dashed rgba(255,255,255,.6); pointer-events: none; }
.trecho-faixa span { position: absolute; top: 6px; left: 6px; font-size: 11px; color: #fff; white-space: nowrap; }
.corte-faixa { position: absolute; bottom: 0; height: 6px; background: var(--accent); border-radius: 2px; pointer-events: none; }
.cortes { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; margin-top: 10px; font-size: 13px; color: var(--ink-2); }
.cortes .chip { border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 999px; padding: 2px 10px;
  font: inherit; font-size: 12px; font-variant-numeric: tabular-nums; cursor: pointer; }
.cortes .chip:hover { border-color: var(--accent); }
.cortes .chip:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.cortes .marca { display: inline-block; width: 14px; height: 6px; border-radius: 2px; background: var(--accent); margin-right: 2px; }
.btn-trecho { margin-left: auto; border: 1px solid var(--line); background: var(--bg); color: var(--ink); border-radius: 999px;
  padding: 7px 14px; font: inherit; font-size: 13px; cursor: pointer; }
.btn-trecho:hover { border-color: var(--accent); }
.btn-trecho:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.cab { font-size: 11px; text-transform: uppercase; letter-spacing: .04em; color: var(--ink-3); padding: 0 12px 8px; }
.linha { width: 100%; text-align: left; border: 1px solid transparent; background: transparent; color: inherit; font: inherit;
  border-radius: 10px; padding: 12px; cursor: pointer; }
.linha:hover { background: var(--bg); }
.linha[aria-pressed="true"] { border-color: var(--accent); background: var(--accent-soft); }
.linha:focus-visible { outline: 2px solid var(--accent); outline-offset: 1px; }
.tecla { font: 12px ui-monospace, Menlo, monospace; color: var(--ink-3); }
.nome { font-weight: 600; }
.desc { color: var(--ink-2); font-size: 12.5px; line-height: 1.35; margin-top: 2px; }
.tags { margin-top: 4px; display: flex; gap: 6px; flex-wrap: wrap; }
.tag { font-size: 11px; color: var(--ink-2); border: 1px solid var(--line); border-radius: 999px; padding: 0 7px; }
.nota { display: flex; align-items: center; gap: 8px; font-variant-numeric: tabular-nums; }
.nota .trilho { flex: 1; height: 6px; background: var(--bar); border-radius: 3px; overflow: hidden; min-width: 40px; }
.nota .enchido { height: 100%; background: var(--ink-2); border-radius: 3px; }
.melhor .enchido { background: var(--good); }
.num { font-variant-numeric: tabular-nums; }
.melhor-txt { color: var(--good); font-weight: 600; }
.rot-m { display: none; }

h2 { font-size: 17px; margin: 0 0 10px; }
.ler ul { margin: 0; padding-left: 18px; color: var(--ink-2); }
.ler li { margin: 6px 0; }
.ler b { color: var(--ink); }

@media (max-width: 760px) {
  .cab { display: none; }
  .linha, .com-trecho .linha { grid-template-columns: 22px 1fr 1fr; row-gap: 6px; }
  .linha .info { grid-column: 2 / 4; }
  .linha .c { grid-column: auto; font-size: 13px; }
  .rot-m { display: inline; color: var(--ink-3); font-size: 11px; margin-right: 4px; }
  .espectro img { height: 110px; }
}
</style>
</head>
<body>
<main>
  <h1>Teste de supressão de ruído</h1>
  <div class="meta" id="meta"></div>

  <div class="card destaque" id="destaque"></div>

  <section class="card" aria-label="Player">
    <div class="transporte">
      <button class="play" id="play" aria-label="Tocar">▶</button>
      <div>
        <div class="ativo-nome" id="ativoNome"></div>
        <div class="tempo" id="tempo">0:00 / 0:00</div>
      </div>
      <button class="btn-trecho" id="btnTrecho" hidden></button>
    </div>
    <div class="espectro" id="espectro" title="Clique para pular para esse ponto">
      <img id="espectroImg" alt="Espectrograma da versão selecionada">
      <span class="rotulo">24 kHz (agudos)</span>
      <span class="rotulo rotulo-b">0 Hz (graves)</span>
      <div class="cabeca" id="cabeca"></div>
    </div>
    <div class="dica">Ouça com fone. Troque de versão com o áudio tocando: ele continua do mesmo ponto.
      <kbd>espaço</kbd> toca/pausa · <kbd>1</kbd>–<kbd id="kbdMax">9</kbd> troca a versão · <kbd>←</kbd> <kbd>→</kbd> volta/avança 5 s</div>

    <div class="cortes" id="cortes" hidden></div>

    <div class="lista" id="lista" role="group" aria-label="Versões">
      <div class="cab" id="cab"></div>
      <div id="linhas"></div>
    </div>
  </section>

  <section class="card ler">
    <h2>Como ler os números</h2>
    <ul>
      <li><b>Nota geral, Voz</b>: DNSMOS, a nota automática da Microsoft que imita a avaliação de ouvintes (1 a 5). "Voz" mede se a fala ficou natural, sem som de robô.</li>
      <li><b>Ruído tirado</b>: quanto o chiado nas pausas da fala caiu em relação ao original. Cada 10 dB soa como metade do volume.</li>
      <li><b>CPU</b>: % de um núcleo deste Mac para processar em tempo real. Abaixo de ~5% não pesa na bateria nem na call. RNNoise foi medido via Python; num app nativo fica ainda mais leve. No isolamento da Apple, o número é o tempo total de processamento.</li>
      <li><b>Latência</b>: atraso que o modelo adiciona na sua voz. Até ~40 ms passa despercebido numa call.</li>
      <li id="liTrecho" hidden></li>
      <li>A nota só enxerga até 8 kHz, então não premia o brilho dos modelos de 48 kHz nem pune GTCRN e VoxLock por cortarem agudos (eles trabalham em 16 kHz, qualidade de "call"). <b>O ouvido decide.</b></li>
    </ul>
  </section>
</main>

<div id="audios" hidden></div>

<script>
const D = __DADOS__;
const $ = (id) => document.getElementById(id);
const fmt = (s) => `${Math.floor(s / 60)}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
const V = D.versoes;

$("meta").textContent = `${D.arquivo} · ${fmt(D.duracao)} · ${D.maquina} · ${D.data}`;

// destaque calculado a partir dos dados
const proc = V.filter((v) => v.cpu != null);
const melhorNota = proc.reduce((a, b) => (b.nota.geral > a.nota.geral ? b : a));
const original = V.find((v) => v.id === "original");
const T = D.trecho;
// trecho com décimos quando não cai em segundo cheio (ex.: 0:08.2–0:08.8)
const fmtD = (s) => (Number.isInteger(s) ? fmt(s) : `${Math.floor(s / 60)}:${(s % 60).toFixed(1).padStart(4, "0")}`);
const fmtT = T ? `${fmtD(T[0])}–${fmtD(T[1])}` : "";
if (T) {
  const melhorCorte = proc.reduce((a, b) => (b.corte_trecho_db > a.corte_trecho_db ? b : a));
  const dfn3 = V.find((v) => v.id === "dfn3");
  const dfn3Basta = dfn3.corte_trecho_db >= 25;  // 25 dB ou mais: o colega já some sem porteiro
  const frase = dfn3Basta
    ? `já cortou <b>${dfn3.corte_trecho_db.toFixed(0)} dB</b>: a voz dele chega baixa e distante, e o filtro trata como ruído de fundo.`
    : `cortou só ${dfn3.corte_trecho_db.toFixed(0)} dB, porque para ele voz é voz, de quem quer que seja.`;
  $("destaque").innerHTML = `<span class="icone">★</span><div>No trecho <b>${fmtT}</b> (voz do colega), o <b>DeepFilterNet3</b> sozinho
    ${frase} <b>${melhorCorte.nome}</b> cortou <b>${melhorCorte.corte_trecho_db.toFixed(0)} dB</b>.
    Clique em "Ouvir o trecho" e alterne entre <kbd>${V.indexOf(dfn3) + 1}</kbd> e <kbd>${V.indexOf(melhorCorte) + 1}</kbd>.</div>`;
} else {
  $("destaque").innerHTML = `<span class="icone">★</span><div><b>${melhorNota.nome}</b> teve a melhor nota geral
    (${melhorNota.nota.geral.toFixed(2)} contra ${original.nota.geral.toFixed(2)} do original), tirou
    ${melhorNota.ruido_removido_db.toFixed(0)} dB de ruído e gastou ${melhorNota.cpu.toFixed(1)}% de um núcleo.
    Mas confie no seu ouvido: compare principalmente nas pausas e no fim das palavras.</div>`;
}
$("kbdMax").textContent = V.length;
$("cab").innerHTML = `<span></span><span>Versão</span><span>Nota geral</span><span>Voz</span><span>Ruído tirado</span>`
  + (T ? `<span>Colega ${fmtT}</span>` : "") + `<span>CPU</span><span>Latência</span>`;
if (T) {
  $("lista").classList.add("com-trecho");
  const faixa = document.createElement("div");
  faixa.className = "trecho-faixa";
  faixa.style.left = `${(T[0] / D.duracao) * 100}%`;
  faixa.style.width = `${((T[1] - T[0]) / D.duracao) * 100}%`;
  faixa.innerHTML = "<span>colega</span>";
  $("espectro").appendChild(faixa);
  $("btnTrecho").hidden = false;
  $("btnTrecho").textContent = `▶ Ouvir o trecho do colega (${fmt(T[0])})`;
  $("liTrecho").hidden = false;
  $("liTrecho").innerHTML = `<b>Colega ${fmtT}</b>: quanto o volume caiu no trecho em que seu colega fala, em relação ao original. Quanto maior, mais da voz dele foi embora.`;
}

const max = (k) => Math.max(...proc.map(k));
const melhor = { geral: max((v) => v.nota.geral), voz: max((v) => v.nota.voz), ruido: max((v) => v.ruido_removido_db),
  trecho: T ? max((v) => v.corte_trecho_db) : null };
const menorCpu = Math.min(...proc.map((v) => v.cpu));

// áudios: todos tocam juntos e só o ativo tem volume, para trocar sem engasgo
const audios = V.map((v) => {
  const a = new Audio();
  a.preload = "auto";
  a.volume = 0;
  $("audios").appendChild(a);
  // baixa o arquivo inteiro antes (pular no tempo funciona em qualquer servidor);
  // aberto direto do disco (file://) o fetch falha e o <audio> lê o arquivo sozinho
  fetch(`${v.id}.wav`)
    .then((r) => (r.ok ? r.blob() : Promise.reject()))
    .then((b) => { const t = audios[0]?.currentTime || 0; a.src = URL.createObjectURL(b); a.currentTime = t; })
    .catch(() => { a.src = `${v.id}.wav`; });
  return a;
});
let ativo = 0;
const principal = () => audios[ativo];

function selecionar(i) {
  const t = principal().currentTime;
  ativo = i;
  audios.forEach((a, j) => {
    if (Math.abs(a.currentTime - t) > 0.03) a.currentTime = t;
    a.volume = j === i ? 1 : 0;
  });
  document.querySelectorAll(".linha").forEach((el, j) => el.setAttribute("aria-pressed", j === i));
  $("ativoNome").textContent = V[i].nome;
  $("espectroImg").src = `${V[i].id}.png`;
}

function tocarPausar() {
  if (principal().paused) {
    const t = principal().currentTime;
    audios.forEach((a) => { a.currentTime = t; a.play().catch(() => {}); });
    $("play").textContent = "❚❚"; $("play").setAttribute("aria-label", "Pausar");
  } else {
    audios.forEach((a) => a.pause());
    $("play").textContent = "▶"; $("play").setAttribute("aria-label", "Tocar");
  }
}

function pular(t) {
  t = Math.max(0, Math.min(D.duracao, t));
  audios.forEach((a) => (a.currentTime = t));
}

function quadro() {
  const a = principal();
  const t = a.currentTime;
  $("tempo").textContent = `${fmt(t)} / ${fmt(D.duracao)}`;
  $("cabeca").style.left = `${(t / D.duracao) * 100}%`;
  if (!a.paused) audios.forEach((b) => { if (b !== a && Math.abs(b.currentTime - t) > 0.04) b.currentTime = t; });
  requestAnimationFrame(quadro);
}
audios[0].addEventListener("ended", () => { audios.forEach((a) => a.pause()); $("play").textContent = "▶"; });

// linhas
const barra = (n, top) => `<div class="nota ${top ? "melhor" : ""}"><span class="num">${n.toFixed(2)}</span>
  <div class="trilho"><div class="enchido" style="width:${((n - 1) / 4) * 100}%"></div></div></div>`;
$("linhas").innerHTML = V.map((v, i) => {
  const ehOrig = v.cpu == null;
  const tags = [v.licenca, v.banda].filter(Boolean).map((t) => `<span class="tag">${t}</span>`).join("");
  return `<button class="linha" data-i="${i}" aria-pressed="false">
    <span class="tecla">${i + 1}</span>
    <span class="info"><div class="nome">${v.nome}</div><div class="desc">${v.desc}</div><div class="tags">${tags}</div></span>
    <span class="c"><span class="rot-m">Nota</span>${barra(v.nota.geral, !ehOrig && v.nota.geral === melhor.geral)}</span>
    <span class="c num ${!ehOrig && v.nota.voz === melhor.voz ? "melhor-txt" : ""}"><span class="rot-m">Voz</span>${v.nota.voz.toFixed(2)}</span>
    <span class="c num ${!ehOrig && v.ruido_removido_db === melhor.ruido ? "melhor-txt" : ""}"><span class="rot-m">Ruído</span>${ehOrig ? "—" : `−${v.ruido_removido_db.toFixed(0)} dB`}</span>
    ${T ? `<span class="c num ${!ehOrig && v.corte_trecho_db === melhor.trecho ? "melhor-txt" : ""}"><span class="rot-m">Colega</span>${ehOrig ? "—" : `−${v.corte_trecho_db.toFixed(0)} dB`}</span>` : ""}
    <span class="c num ${!ehOrig && v.cpu === menorCpu ? "melhor-txt" : ""}"><span class="rot-m">CPU</span>${ehOrig ? "—" : `${v.cpu.toFixed(1)}%`}</span>
    <span class="c num"><span class="rot-m">Latência</span>${v.latencia || "—"}</span>
  </button>`;
}).join("");
document.querySelectorAll(".linha").forEach((el) => el.addEventListener("click", () => selecionar(+el.dataset.i)));

$("play").addEventListener("click", tocarPausar);

// onde o porteiro (versão "DeepFilterNet3 + porteiro decidido") cortou algo com volume de fala
const C = D.cortes || [];
const fmtSeg = (s) => `${Math.floor(s / 60)}:${(s % 60).toFixed(1).padStart(4, "0")}`;
if (C.length) {
  C.forEach(([a, b]) => {
    const f = document.createElement("div");
    f.className = "corte-faixa";
    f.style.left = `${(a / D.duracao) * 100}%`;
    f.style.width = `${Math.max(0.4, ((b - a) / D.duracao) * 100)}%`;
    $("espectro").appendChild(f);
  });
  $("cortes").hidden = false;
  $("cortes").innerHTML = `<span><span class="marca"></span>Onde o porteiro cortou uma voz (confira se era de outra pessoa):</span>`
    + C.map(([a]) => `<button class="chip" data-t="${a}">${fmtSeg(a)}</button>`).join("");
  $("cortes").querySelectorAll(".chip").forEach((b) => b.addEventListener("click", () => {
    pular(Math.max(0, +b.dataset.t - 1));
    if (principal().paused) tocarPausar();
  }));
}
$("btnTrecho").addEventListener("click", () => {
  pular(Math.max(0, T[0] - 1.5));
  if (principal().paused) tocarPausar();
});
$("espectro").addEventListener("click", (e) => {
  const r = e.currentTarget.getBoundingClientRect();
  pular(((e.clientX - r.left) / r.width) * D.duracao);
});
document.addEventListener("keydown", (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (e.code === "Space") { e.preventDefault(); tocarPausar(); }
  else if (e.key === "ArrowRight") pular(principal().currentTime + 5);
  else if (e.key === "ArrowLeft") pular(principal().currentTime - 5);
  else if (/^[1-9]$/.test(e.key) && +e.key <= V.length) selecionar(+e.key - 1);
});

selecionar(0);
requestAnimationFrame(quadro);
</script>
</body>
</html>
"""


def gerar(pasta: Path, dados: dict) -> Path:
    destino = pasta / "index.html"
    destino.write_text(HTML.replace("__DADOS__", json.dumps(dados, ensure_ascii=False)))
    return destino


if __name__ == "__main__":
    p = Path(sys.argv[1])
    print(gerar(p, json.loads((p / "dados.json").read_text())))
