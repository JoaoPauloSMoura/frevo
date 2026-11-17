# Soltar uma versão

Quem instalou o Frevo recebe uma versão nova quando aparece uma **marca** (`tag`) `vX.Y.Z` no GitHub. O que está só na `main`, sem marca, não chega a ninguém. Dá para trabalhar à vontade e publicar quando estiver pronto.

## Passo a passo

1. Teste a versão no seu Mac: `scripts/compilar-app.sh && scripts/instalar-app.sh`. Se mexeu no driver, rode também `scripts/compilar-driver.sh && scripts/instalar-driver.sh`.
2. Faça o commit e envie a `main`.
3. Crie a marca **anotada**, com as novidades na mensagem. A primeira linha vira o resumo da notificação. O texto todo aparece no painel do Frevo, até 5 linhas.

   ```bash
   git tag -a v0.3.0 -m "Pergunta na ilha quem está falando" -m "- A ilha pergunta o nome de cada voz nova durante a chamada.
   - A transcrição sai com os nomes, sem a janela do fim.
   - Correção: vozes da mesma pessoa não se dividem mais."
   git push origin v0.3.0
   ```

4. Pronto. Em até 6 horas, cada Frevo instalado avisa. Quem quiser antes usa Ajustes → Procurar atualizações.

Opcional: crie também um *release* no GitHub a partir da marca, para as novidades ficarem na página do projeto. O app não depende dele.

## Números de versão

- `v0.3.0` → `v0.3.1`: correção.
- `v0.3.0` → `v0.4.0`: função nova.
- `v1.0.0`: quando estiver estável para qualquer pessoa.

Use só números (`v1.2.3`): o app compara as marcas como números e ignora o que não começar com `v` e um dígito.

## O que pesa numa atualização

O `scripts/atualizar.sh` recompila só o que mudou entre a versão instalada e a nova:

| Se mudou… | Na atualização |
|---|---|
| Só Swift (`barra/`, `nucleo/`, `cli/`, `ferramentas/`) | Recompila o app, 1 a 2 minutos |
| `driver/` ou `scripts/compilar-driver.sh` | O macOS pede a senha de administrador e o som corta por 1 ou 2 segundos |
| `motor/eco.*` ou `scripts/compilar-eco.sh` | Recompila o cancelador de eco |
| `scripts/compilar-motor.sh` | Recompila o DeepFilterNet (alguns minutos) |
| `scripts/baixar-dependencias.sh` | Baixa as bibliotecas e os modelos novos |

Mudar o driver pede senha a todo mundo, então vale juntar mudanças de driver numa versão só.

## Cuidados

- **Não mude o identificador** (`io.github.joaopaulosmoura.frevo`) nem os UIDs dos dispositivos no `driver/Driver.cpp`. Mudar o identificador zera as permissões de todo mundo. Mudar os UIDs faz os apps de chamada perderem o "Frevo" escolhido.
- **Não apague nem mova marcas já publicadas.** Quem estiver nelas pode ficar sem caminho de atualização.
- **Atualizar não pode quebrar:** o atualizador roda sozinho, sem ninguém olhando o terminal. Teste `scripts/atualizar.sh` num clone limpo antes de soltar uma versão que mexe nos scripts.
