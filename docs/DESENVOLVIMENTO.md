# Desenvolvimento

Como o Frevo está organizado, como compilar cada parte, as ferramentas de teste e as medições que guiaram as escolhas. Para instalar e usar, veja o [README](../README.md). Para soltar uma versão, veja [VERSOES.md](VERSOES.md).

O código está em português, nomes e comentários. Os comentários explicam o porquê de cada escolha, quase sempre com a medição que levou a ela.

## Peças

| Pasta | O que é |
|---|---|
| `driver/` | Driver de áudio virtual (AudioServerPlugIn) feito com a [libASPL](https://github.com/gavv/libASPL). Cria o "Frevo" (entrada, que os apps de chamada leem) e o "Frevo Feed" (saída oculta, onde o app escreve), ligados por um buffer circular. |
| `motor/` | Interface C da libDF (DeepFilterNet) e a ponte em C (`eco.h`/`eco.cpp`) para o cancelador de eco do webrtc-audio-processing. `ponte.h` junta tudo para o Swift. |
| `nucleo/` | O que o app faz, em Swift e sem interface. `Pipeline` (microfone → eco → filtro → Feed), `Dispositivos`, `Motor`, `Gravacao` (trilhas e captura do som do sistema), `Transcritor` (Whisper + quem falou), `SeparadorDeVozes`, `ImpressaoDeVoz`, `DetectorDeFala`, `QuemFala` (pergunta ao vivo), `Chamados` (sugestões de nome), `Modelos`. |
| `barra/` | App da barra de menu (`Frevo.app`). `Controlador` liga tudo; `Painel` e `Ilha` são as telas; `VigiaDoMudo` lê o botão de mudo pela Acessibilidade; `Agenda` e `LinkDaChamada` acham o evento da reunião; `Escrivao` transcreve depois da chamada; `JanelaNomes` é o "Quem falou?"; `Atualizador` procura versões novas. |
| `cli/` | Versão de terminal (`build/frevo`): o mesmo filtro sem interface, bom para medir e depurar. |
| `ferramentas/` | Ferramentas de teste (abaixo). |
| `scripts/` | Instalar, atualizar, desinstalar e compilar cada parte. |
| `teste-ruido/` | Bancada que comparou os modelos de cancelamento de ruído (RNNoise, DeepFilterNet3, DPDFNet, Apple, VoxLock) e levou à escolha do DeepFilterNet3. |

## Compilar à mão

O `scripts/instalar.sh` faz tudo isto em ordem. Cada script pode rodar sozinho:

```bash
scripts/baixar-dependencias.sh   # DeepFilterNet, libASPL e sherpa-onnx em third_party/, e os modelos em third_party/modelos/
scripts/compilar-motor.sh        # libDF em Rust → build/libdf.a (alguns minutos na primeira vez)
scripts/compilar-eco.sh          # cancelador de eco do WebRTC → build/libeco.a (baixa e compila uma vez)
scripts/criar-certificado.sh     # certificado de assinatura local (uma vez por Mac)
scripts/compilar-driver.sh       # build/Frevo.driver
scripts/compilar-app.sh          # build/Frevo.app e as ferramentas
scripts/instalar-driver.sh       # copia o driver para /Library/Audio/Plug-Ins/HAL (pede a senha)
scripts/instalar-app.sh          # copia o app para Aplicativos e abre
```

Precisa das ferramentas de linha de comando da Apple e de `brew install rust whisper-cpp meson ninja`.

`compilar-app.sh` grava no `Info.plist` do app a versão (`git describe`) e a pasta do código. É assim que o app sabe se há versão nova e onde rodar o atualizador.

**Assinatura.** O app é assinado com um certificado "Apple Development", se houver no Chaveiro. Senão, usa o "Frevo (assinatura local)" criado por `criar-certificado.sh`. Sem nenhum dos dois, usa a assinatura improvisada (ad hoc). O macOS guarda as permissões presas à identidade da assinatura (`codesign -dr- /Applications/Frevo.app` mostra qual). Com um certificado fixo, essa identidade não muda entre compilações. Com a ad hoc, muda sempre, e as permissões zeram. O driver não precisa de certificado: o serviço de áudio carrega o driver com assinatura ad hoc.

## Onde as coisas ficam no Mac

| Caminho | O que é |
|---|---|
| `/Applications/Frevo.app` | O app |
| `/Library/Audio/Plug-Ins/HAL/Frevo.driver` | O driver do microfone virtual |
| `~/Library/Application Support/Frevo/` | `modelos/` (Whisper), `vozes.json` (memória de vozes), `sessoes/` (áudio e dados das chamadas com vozes ainda sem nome) |
| `~/Documents/Ligações/` | As transcrições em Markdown |
| `~/Library/Logs/Frevo/atualizacao.log` | Registro das atualizações |
| Preferências `io.github.joaopaulosmoura.frevo` | Ajustes do app (`defaults read io.github.joaopaulosmoura.frevo`) |

Os registros do app vão para o log do sistema, nas categorias `chamada`, `audio`, `mudo` e `atualizacao`:

```bash
log stream --predicate 'subsystem == "io.github.joaopaulosmoura.frevo"'
```

## Ferramentas de teste

```bash
build/frevo --listar                 # microfones disponíveis
build/frevo --mic "HyperX"           # liga o filtro no terminal; Enter liga/desliga, Ctrl+C sai
build/frevo --em-uso                 # sai com 0 se algum app está usando o Frevo (chamada em andamento)
scripts/testar-som.sh 5              # grava 5 s do "Frevo" como um app de chamada faria e toca de volta

build/motor-teste entrada-48k.wav saida.wav       # passa um arquivo pelo filtro, quadro a quadro, e mede o tempo
build/eco-teste sua-voz.wav voz-do-outro.wav      # simula o eco do alto-falante e mede o cancelador (ECO_DB, RUIDO_DB)
build/gravar-outros outros.wav 600                # grava o som do app que está usando o Frevo

build/transcrever --voce voce.wav --outros outros.wav --falas falas.json   # transcreve duas trilhas
build/transcrever --sessao <pasta da chamada> --sem-salvar                 # refaz uma chamada gravada, só para ver
build/transcrever --sessao <pasta da chamada> --herdar-nomes               # refaz mantendo os nomes já dados
build/transcrever --sugerir <pasta da chamada>                             # testa as sugestões de nome contra os nomes dados
build/transcrever --ao-vivo <pasta da chamada> [--sem-memoria]             # simula as perguntas da ilha com o áudio gravado
build/transcrever --separar outros.wav turnos.json [--passo 0.25]          # só o separador de vozes
```

Não rode `build/frevo` com o app aberto: os dois escreveriam no Frevo e a voz sairia dobrada.

As imagens do README (`docs/imagens`) saem das próprias telas do app, com dados inventados. Depois de mudar o painel, a ilha ou a janela "Quem falou?", rode `scripts/gerar-imagens-da-doc.sh`:
- `ferramentas/telas-da-doc` desenha as telas numa janela fora da tela;
- `ferramentas/foto-html` monta as composições de `docs/imagens/fonte/*.html` e fotografa cada uma.

A bancada de ruído (`teste-ruido/comparar.sh audio.m4a`) roda cada modelo num áudio e abre uma página para comparar ouvindo. Ela tem um ambiente Python próprio (`teste-ruido/.venv`) e baixa os modelos que compara.

## Como funciona, com as medições

### Filtro de ruído

O `Pipeline` lê o microfone a 48 kHz e passa a voz pelo DeepFilterNet3 (libDF), em quadros de 10 ms. Depois escreve no "Frevo Feed". O driver copia do Feed para o "Frevo".

- Com headset, o filtro sozinho tira a voz de quem está do lado, nas pausas: 56 dB de corte, contra 4 dB no microfone do MacBook. A sua voz perde só 0,5 dB.
- Gasta cerca de 3% de um núcleo de um M4 Pro.
- Com o microfone do notebook, o filtro não separa vozes. Para isso seria preciso o VoxLock, por volta de 50% de um núcleo.
- Quando o microfone e o Mac andam em relógios um pouco diferentes, o `Pipeline` pula ou completa alguns milissegundos e registra isso na categoria `audio`.

### Cancelamento de eco

Com o som saindo do alto-falante, a voz dos outros volta pelo microfone. O DeepFilterNet3 trata essa voz como fala e deixa passar quando ela chega alta. Por isso o AEC3 do WebRTC roda antes do filtro, comparando o microfone com o som que o Mac está tocando. Essa referência vem de um *process tap* global do sistema, que fica só na memória.

- **Simulado** (`eco-teste`):
  - Eco a −35 dBFS: o filtro sozinho deixava em −40; com o cancelador, caiu para −100.
  - Eco fraco (−55): os dois deixam igual.
  - Voz sozinha: perde 0,6 dB. Com os dois falando ao mesmo tempo: 2 dB.
  - Gasta cerca de 1,2% de um núcleo.
- **Com fone:** não há eco, e a voz passa igual (−0,6 dB).
- A captura do sistema leva uns 2 s para começar a entregar áudio.

### Transcrição

O `Escrivao` transcreve depois da chamada, num processo de fundo de baixa prioridade.

1. O detector de sons (CED) tira da trilha dos outros o que não é fala: música de outra aba, o sino de entrada.
2. As duas trilhas são misturadas, e o Whisper transcreve a **conversa** em blocos de até 28 s, com o fim do bloco anterior como contexto. Transcrever cada trilha separada, em falas curtas, dava frases sem sentido.
3. O separador (pyannote segmentação 3.0 + ERes2NetV2, pelo sherpa-onnx) marca quem fala quando na trilha dos outros.
4. Cada palavra vai para você ou para alguém dos outros, conforme a trilha que tem voz naquele instante. A frase é cortada onde a pessoa muda.

Medições:
- **Separador:** o limiar de 0,75 achou as 4 pessoas de uma reunião semanal de 21 min e acertou 97% do tempo de fala.
- **Horário das palavras:** vem do alinhamento DTW do Whisper, e o separador anda de 2,5 em 2,5 s. Numa conversa montada com 90 trocas de pessoa conhecidas em 5,5 min, a pessoa certa passou de 79% para 86% das palavras, com 1,4 vez o tempo de transcrição.
  - O passo de 1 s daria 87%, com 2,3 vezes o tempo.
  - Comparando com a transcrição do Google Meet numa reunião real de 46 min, 92,7% das palavras saíram com a pessoa certa.
  - O que sobra de erro são falas curtas inteiras (1 a 3 s) que o separador junta com o vizinho.
- **Uma pessoa, uma voz:** o separador às vezes parte a mesma pessoa em duas ou três. Pedaços da mesma pessoa deram 0,86 a 0,97 de semelhança, e pessoas diferentes nunca passaram de 0,72. Por isso, vozes acima de 0,8 viram uma só. Com o convite da agenda, se houver mais vozes que convidados, junta também até 0,7.
- **Memória de vozes:**
  - A mesma pessoa em outra reunião deu 0,93 a 0,95. Duas pessoas diferentes de voz parecida chegaram a 0,72.
  - Reconhecer exige 0,8 (0,75 se o nome é de um convidado). Aprender sozinho exige 0,88.
  - No começo, ERes2NetV2 contra CAM++, com janelas de 3 s: erro igual de 2,8% contra 10,8%.

### Quem está falando, ao vivo

O `QuemFala` ouve a trilha dos outros enquanto ela é gravada.
- A cada 1,5 s de fala, tira uma impressão de voz dos últimos 3 s e agrupa as parecidas.
- Um grupo novo com uns 6 s de fala vira pergunta na ilha.
- A resposta marca os trechos daquela voz (`Sessao.marcas`). No fim, a transcrição dá a cada voz o nome que cobre a maior parte dos trechos marcados dela.

Medições, tocando reuniões gravadas como se fossem ao vivo (`transcrever --ao-vivo`):
- **Reunião de 21 min:** 4 perguntas, uma por pessoa, com 97% dos trechos marcados com o nome certo.
- **Chamada de 4 h com áudio embaralhado:** sem limite, perguntava a cada poucos segundos. Por isso há pelo menos 30 s entre perguntas e no máximo 2 por convidado (mínimo de 6 por chamada).
- **Custo:** cerca de 3% de um núcleo enquanto alguém fala.

### Sugestões de nome

O `Chamados` procura falas que terminam chamando alguém ("…, Marina?") seguidas de outra voz. Cada caso é um voto. Vale o nome com mais votos em cada voz, e um nome que o app não conhece precisa de 2 votos.

- Numa reunião de 46 min, uns 2 de cada 3 chamados foram atendidos pela pessoa chamada.
- Nas chamadas guardadas, 4 sugestões certas e 1 errada.

### Gravação desde o começo

Sem transcrição, a `Gravacao` guarda as duas trilhas só na memória: os últimos 15 min, em 16 kHz e 16 bits, uns 60 MB. Ligando a transcrição, `passarParaDisco` escreve esse começo nos arquivos e segue gravando. A distância entre as trilhas desconta o que saiu da memória.

### Atualizador

O `Atualizador` roda `git fetch --tags` na pasta do código ao abrir o app e a cada 6 horas. Ele compara a marca mais nova (`vX.Y.Z`) com a versão compilada.

O botão "Atualizar" roda `scripts/atualizar.sh <marca>`, que:
1. faz o checkout da marca;
2. recompila só o que mudou entre as duas versões;
3. espera a chamada acabar (`build/frevo --em-uso`);
4. reinstala o driver, se ele mudou, com a janela de senha do macOS;
5. reinstala o app, que fecha e abre na versão nova.

O script inteiro fica dentro de uma função, porque o checkout pode trocar o próprio arquivo no meio da execução. A saída vai para o registro: quando o app fecha, ninguém mais lê a saída do script.

## Ainda falta

- Conversão de taxa para microfones que não aceitam 48 kHz.
- Correção fina da deriva de relógio entre o microfone e o Mac (hoje pula ou completa alguns milissegundos quando acumula).
- Resumo da reunião (decisões e próximos passos) com um modelo de linguagem rodando no Mac.
- Ler o mudo do WhatsApp para Mac.
- Windows.
