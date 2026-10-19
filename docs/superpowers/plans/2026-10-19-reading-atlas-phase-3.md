# Reading Atlas — fase 3: plano de implementação

**Data:** 2026-10-19
**Spec:** [`../specs/2026-10-15-reading-atlas-phase-3-design.md`](../specs/2026-10-15-reading-atlas-phase-3-design.md)
**Status:** executado

A ordem segue a das fases anteriores: lógica pura com teste primeiro, depois
I/O, widget e composição, e por último o KOReader de verdade.

## Tarefas

### 1. `atlas/fingerprint.lua` — lógica pura

- `buckets(rows, n)`: cada linha vira o intervalo de posição
  `[(page − 1) / total_pages, page / total_pages)` e o tempo é espalhado pelos
  `n` baldes que ela cobre, proporcional à sobreposição. Linha sem
  `total_pages` é ignorada; página além do layout é presa à última.
- `density(rows, n, pages)`: segundos por página **na contagem atual** — o
  tempo do balde dividido pela largura dele em páginas (`pages / n`).
- `reach(rows)`: a posição mais adiante que alguma linha tocou, 0..1. Crua:
  uma olhada na última página conta. Só serve para limitar a busca da janela
  mais lenta.
- `progress(rows, pages)`: até onde o leitor chegou de fato — a página mais
  adiante que foi **lida** (5 s/página ou mais, não folheada) e que fecha uma
  janela de max(5, 2% do livro) com pelo menos metade das páginas lidas,
  vindas de pelo menos **duas** páginas distintas do livro no layout em que
  foram lidas. Uma olhada no sumário, folhear até o fim, ou uma página de um
  layout antigo de fonte menor (que cobre várias páginas atuais) não contam;
  pular um apêndice e ler o final conta.
- `analyze(rows, pages)`: uma passada, por dia local, em ordem, que devolve
  o progresso e as releituras (`rereads(rows, pages)` é atalho). Uma página é
  relida no dia `d` se já tinha sido **lida** (não folheada) num dia anterior,
  se é lida de novo em `d`, e se antes de `d` o leitor tinha chegado **de
  fato** (a fronteira, não o alcance cru) a `REREAD_LEAD` (5%) além dela.
  Intervalos a até `REREAD_BRIDGE` (1%) um do outro se juntam. A fronteira é
  incremental.
- `toBuckets(iv, pages, n)`: intervalo de páginas → baldes da faixa, para a
  barra de releitura.
- `slowest(rows, pages)`: janela de `max(10, ceil(2% de pages))` páginas com
  mais tempo, só sobre o que foi lido. Empate fica com a primeira.
- `status(progress, last_open, now)`: terminado a 97% de `progress`; senão
  "paused" depois de 30 dias sem abrir, "reading" antes. Chamado no render.
- `prepare(data)`: agrupa linhas por livro, ordena por `last_open`, corta
  em `MAX_BOOKS` (6), e calcula uma vez o que não depende da largura nem do
  relógio: progresso, releituras e trecho mais lento. Livro sem `pages` usa o
  layout com o `last_seen` mais recente.
- `layout(prep, n, Scale, count)`: só para os `count` livros que o card mostra.
  Degrau por balde com **um** conjunto de quartis para esses livros; folhear
  (< 5 s/página) é o degrau 0; não lido é `nil`. Converte as releituras de
  páginas para baldes.

Ruído de ponto flutuante: `(page − 1) / total_pages * n` pode cair um fio
além da borda de um balde; sobreposições abaixo de 1e-9 balde são ignoradas,
senão uma página vazava para as vizinhas.

Teste: `tests/_test_fingerprint.lua`.

### 2. `atlas/db.lua` — `fingerprintRows(limit)`

Duas consultas na mesma conexão `ro`: os livros com `total_read_time >= 600`
por `last_open DESC LIMIT n`, e as linhas desses livros agregadas por
`(id_book, page, total_pages, dia local)`, com `MAX(start_time)` como
`last_seen`. O dia local é
`CAST(strftime('%s', start_time, 'unixepoch', 'localtime') AS INTEGER) / 86400`:
o dia em UTC cortaria uma noite de leitura no Brasil às 21h. Todo valor passa por `tonumber`/`tostring`
dentro do `pcall`, antes do `close()`. Falha → `nil`.

Teste: `tests/_test_db.lua`, contra um `lua-ljsqlite3` falso cujos valores
levantam erro se lidos depois do `close()`.

### 3. `atlas/stripwidget.lua`

`Widget:extend{}`. Pinta por *runs* de degrau igual (dezenas de retângulos por
faixa, não um por coluna), o não lido como pontos de 1 px a cada 3 no meio da
faixa, e a barra de releitura com largura mínima `min_tick`, presa dentro da
faixa na borda direita.

Teste: `tests/_test_stripwidget.lua`, incluindo a herança de `Widget`.

### 4. `micromodules/atlas_fingerprint.lua`

Composição: estados (Reading…, No statistics, Not enough reading yet), e por
livro título + meta, faixa e nota, e a legenda. A consulta tem `max_age` de
uma hora. `prepare` é memoizado por resultado de consulta, o status é
calculado no render, e `layout` é memoizado por largura e número de livros, porque o host renderiza o mesmo card várias vezes ao
ajustar a escala. "paused since" usa nomes de mês via gettext e inclui o ano
quando não é o ano corrente. Quantos livros cabem sai de
`ctx.height` dividido pela altura fixa de um livro, entre 1 e 6. O preview do
picker usa `peek` e nunca agenda consulta.

Teste: `tests/_test_fingerprint_module.lua`, com stubs do Kit e dos widgets.

### 5. Instalação e documentação

- `tools/install.sh` copia `atlas_fingerprint.lua`.
- README: o card entra em "The modules", com imagem.
- `CARRY-FORWARD.md`: checklist do aparelho da fase 3 e a correção sobre TEXT.

### 6. KOReader desktop

KOReader v2026.07 (Linux), `bookshelf.koplugin` atual, `statistics.sqlite3`
simulado com seis livros: um em andamento, um pausado em junho, uma troca de
fonte no meio de *Cien años de soledad* (448 → 672 páginas), releituras em três
livros. Telas de Paperwhite (1072×1448) e de Kindle básico (600×800).

O que apareceu ali e não nos testes: a releitura de *Cien años*, feita depois
da troca de fonte, saía como barra tracejada e a nota citava só um pedaço. Daí
o `REREAD_BRIDGE`.

### 7. Revisão do PR #5

O CodeRabbit apontou que uma olhada na última página terminava um livro; daí
`progress`. Uma revisão de código em seguida achou mais dez problemas, todos
corrigidos com um teste que falha no código anterior:

1. A regra de releitura usava o alcance cru: uma olhada no fim do livro fazia
   todo início de sessão seguinte virar releitura.
2. `progress` contava páginas folheadas: passar rápido até o fim terminava o
   livro.
3. Ruído de ponto flutuante marcava páginas vizinhas como lidas.
4. Uma página de um layout antigo, de fonte menor, cobria sozinha metade da
   janela de `progress`.
5. O status ficava congelado na hora do primeiro render.
6. O dia era UTC, não local.
7. Releituras e trecho mais lento eram recalculados a cada largura, para os
   seis livros mesmo quando o card mostrava um.
8. Sem `pages`, o layout "mais recente" dependia da ordem das linhas num dia
   com troca de fonte.
9. `toPages` não era usado em produção; virou `toBuckets`, que é.
10. "paused since Mar" não dizia o ano, e o mês vinha do locale C.

Uma segunda rodada da revisão achou mais sete:

1. O resultado da consulta nunca era renovado com o KOReader ligado, então
   um livro lido todo dia virava "paused". `source.getKeyed` ganhou
   `max_age`: depois dele, devolve o resultado antigo enquanto uma consulta
   nova roda fora do paint, e uma renovação que falha mantém o último
   resultado bom. A impressão digital re-lê o banco de hora em hora.
2. Uma página folheada antes e lida de verdade depois contava como relida.
   Agora só leitura de verdade marca o primeiro dia de uma página.
3. A fonte de uma linha era identificada pela página crua, não pela presa ao
   layout: página 301 de 300 contava como uma segunda fonte.
4. `prepare` era refeito a cada hora só por causa do status. Agora `prepare`
   não lê o relógio, e o status é calculado no render.
5. `progress` e as releituras faziam a mesma contagem duas vezes; agora
   `analyze` faz uma e devolve as duas coisas.
6. A fronteira era recalculada do zero a cada dia de leitura, O(dias ×
   páginas). Como toda contagem só cresce, a fronteira só avança: agora ela é
   mantida de forma incremental, re-checando só as páginas cuja janela tocou o
   que mudou. Um teste confere contra a definição, dia a dia, em livros
   aleatórios — e foi esse teste que achou que `spill` precisava contar
   fontes, não só marcar que havia uma.
7. A abertura e o fechamento da conexão estavam duplicados em `db.lua`;
   agora `withConnection` serve às duas consultas.

## Resultado

14 suítes, 213 testes, 0 falhas. Falta o checklist do aparelho em
`CARRY-FORWARD.md`.
