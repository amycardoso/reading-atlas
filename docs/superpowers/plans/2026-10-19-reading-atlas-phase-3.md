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
  adiante com pelo menos metade das páginas lidas numa janela de
  max(5, 2% do livro) terminando nela. Uma olhada no sumário ou numa nota no
  fim não conta; pular um apêndice e ler o final conta. (Revisão do PR #5: com
  `reach`, uma olhada na última página marcava o livro como terminado.)
- `rereads(rows, n)`: processa por dia, em ordem. Um balde é relido no dia `d`
  se já tinha sido lido num dia anterior **e**, antes de `d`, o leitor já tinha
  chegado a `REREAD_LEAD` (5%) além da página. Intervalos a até
  `REREAD_BRIDGE` (1%) um do outro se juntam.
- `slowest(rows, pages)`: janela de `max(10, ceil(2% de pages))` páginas com
  mais tempo, só sobre o que foi lido. Empate fica com a primeira.
- `status(progress, last_open, now)`: terminado a 97% de `progress`; senão
  "paused" depois de 30 dias sem abrir, "reading" antes.
- `prepare(data, now)`: agrupa linhas por livro, ordena por `last_open`, corta
  em `MAX_BOOKS` (6). Livro sem `pages` usa o layout da linha mais recente.
- `layout(prep, n, Scale)`: degrau por balde com **um** conjunto de quartis
  para todos os livros do card; folhear (< 5 s/página) é o degrau 0; não lido é
  `nil`. Releituras em baldes (para a barra) e em páginas (para a nota).

Teste: `tests/_test_fingerprint.lua`.

### 2. `atlas/db.lua` — `fingerprintRows(limit)`

Duas consultas na mesma conexão `ro`: os livros com `total_read_time >= 600`
por `last_open DESC LIMIT n`, e as linhas desses livros agregadas por
`(id_book, page, total_pages, dia)`. Todo valor passa por `tonumber`/`tostring`
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
livro título + meta, faixa e nota, e a legenda. `prepare` é memoizado por
resultado de consulta e `layout` por largura, porque o host renderiza o mesmo
card várias vezes ao ajustar a escala. Quantos livros cabem sai de
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

## Resultado

14 suítes, 191 testes, 0 falhas. Falta o checklist do aparelho em
`CARRY-FORWARD.md`.
