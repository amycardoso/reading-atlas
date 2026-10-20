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
- `analyze(rows, pages)`: a única entrada que `prepare` usa. Uma passada,
  uma contagem, devolvendo progresso, releituras e trecho mais lento.
- Progresso: até onde o leitor chegou de fato — a página mais
  adiante que foi **lida** (no limiar do livro: um quarto da mediana de
  segundos por página, nunca menos que 5 s) e que fecha uma
  janela de max(5, 2% do livro) com pelo menos metade das páginas lidas,
  vindas de pelo menos **duas** páginas distintas do livro no layout em que
  foram lidas. Uma olhada no sumário, folhear até o fim, ou uma página de um
  layout antigo de fonte menor (que cobre várias páginas atuais) não contam;
  pular um apêndice e ler o final conta.
- Releituras: por dia local, em ordem. Uma página é
  relida no dia `d` se já tinha sido **lida** (não folheada) num dia anterior,
  se é lida de novo em `d`, e se antes de `d` o leitor tinha chegado **de
  fato** (a fronteira, não o alcance cru) a `REREAD_LEAD` (5%) além dela.
  Intervalos a até `REREAD_BRIDGE` (1%) um do outro se juntam. A fronteira é
  incremental.
- `toBuckets(iv, pages, n)`: intervalo de páginas → baldes da faixa, para a
  barra de releitura.
- Trecho mais lento: janela de `max(10, ceil(2% de pages))` páginas com mais
  tempo, até a página mais adiante tocada, a partir da mesma contagem.
  Empate fica com a primeira.
- `status(progress, last_open, now)`: terminado a 97% de `progress`; senão
  "paused" depois de 30 dias sem abrir, "reading" antes. Chamado no render.
- `prepare(data, old)`: roda dentro da consulta adiada, fora da pintura.
  Mantém a ordem e o corte que o SQL deu, chama `analyze` só para livros cujo
  carimbo mudou, reusa a análise dos outros e devolve `old` quando nada
  mudou. Livro sem `pages` usa o layout com o
  `last_seen` mais recente; livro sem `last_open` fica com `nil`.
- `layout(prep, n, Scale, count)`: só para os `count` livros que o card mostra.
  Degrau por balde com **um** conjunto de quartis para esses livros; folhear
  (< 5 s/página) é o degrau 0; não lido é `nil`. Converte as releituras de
  páginas para baldes.

Ruído de ponto flutuante: `(page − 1) / total_pages * n` pode cair um fio
além da borda de um balde; sobreposições abaixo de 1e-9 balde são ignoradas,
senão uma página vazava para as vizinhas.

Teste: `tests/_test_fingerprint.lua`.

### 2. `atlas/db.lua` — `fingerprintRows(limit)`

Três consultas na mesma conexão `ro`: os livros com `total_read_time >= 600`
e linhas em `page_stat_data`, por `last_open DESC, id LIMIT n`; um carimbo
por livro (contagem, soma, último início), que com título, páginas e
`last_open` forma a `sig`; e, só para livros cuja `sig` não está em `known`,
as linhas agregadas por
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
livro título + meta, faixa e nota, e a legenda. A consulta lê o banco e roda
`prepare`, com `max_age` de uma hora. O status é calculado no render, e
`layout` é memoizado por resultado, largura e número de livros, porque o host renderiza o mesmo card várias vezes ao
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

A terceira rodada achou mais nove:

1. Um livro sem `last_open` virava "paused since 1970". Agora fica `nil`, e
   `status` nunca chama de pausado um livro sem data.
2. `prepare` (a análise pesada) rodava no render, na thread de pintura, e de
   novo a cada renovação horária. Agora roda dentro da consulta adiada; um
   teste falha se `prepare` for chamado dentro de `render`.
3. Uma renovação que falhava (banco ocupado) adiava a próxima tentativa por
   mais uma hora inteira. Agora tenta de novo em 5 minutos (`deps.retry`).
4. Cada render no caminho "velho" empilhava o mesmo callback de refresh, e o
   card era redesenhado N vezes. Agora cada callback entra uma vez.
5. O trecho mais lento refazia a contagem por página que `analyze` já tinha.
6. `analyze` espalhava cada linha duas vezes; agora uma.
7. `progress`, `rereads`, `slowest` e `reach` eram entradas públicas que a
   produção não usava. Saíram: os testes passam por `analyze`, o que o card
   usa.
8. Uma condição sempre verdadeira (`first_day[p] < d`) foi removida.
9. Dois comentários desatualizados (`install.sh`, `db.lua`).

A quarta rodada achou mais nove; oito corrigidos:

1. Uma série de consultas a notas no fim do livro (páginas vizinhas, 5–10 s
   cada) movia o progresso. "Lida" agora é relativa ao ritmo do leitor naquele
   livro: pelo menos um quarto da mediana de segundos por página
   (`threshold`, `LOOKUP_FRACTION`), nunca menos que 5 s. O limiar é fixo
   para a análise toda, então a fronteira continua monotônica.
2. *Não corrigido, de propósito:* um livro cujo fim é 15% de notas e índice
   nunca chega a "terminado" (97%). O `statistics.sqlite3` não sabe onde
   termina o texto principal; baixar o limiar chamaria de terminado quem parou
   em 85%. O status "complete" do KOReader mora no sidecar do livro, que a
   tabela `book` não liga a um arquivo. Registrado em `CARRY-FORWARD.md`.
3. A densidade dividia o tempo pela largura inteira do balde, inclusive
   páginas não lidas, e bordas de trechos lidos saíam pálidas. Agora divide
   pelas páginas lidas no balde (cobertura limitada a 1, para releitura ainda
   escurecer).
4. A fronteira re-checava uma faixa larga com O(janela) por página. Agora só
   as janelas que contêm uma página do dia são re-checadas, cada uma em
   O(log páginas) com duas árvores de Fenwick.
5. Sem banco (cache `false`), cada renovação falha virava nova tentativa em
   5 minutos. Agora espera `max_age`; os 5 minutos são só para quem já tinha
   dado bom.
6. `LIMIT 6` contava livros sem linhas em `page_stat_data`, e o card ficava
   com menos de seis. A consulta agora exige `EXISTS`.
7. "h", "min" e "p." eram fixos em inglês, e "3.5 h" usava ponto decimal.
   Agora o tempo sai em unidades inteiras ("3 h 05 min") e tudo passa pelo
   gettext.
8. Cada renovação horária refazia a análise e repintava o card mesmo sem
   leitura nova. Agora a consulta compara uma assinatura barata do resultado
   e devolve a mesma análise; `source.lua` não dispara refresh quando o
   objeto é o mesmo.
9. Os cinco cinzas estavam copiados em `stripwidget.lua`; agora vêm de
   `atlas/ink.lua`, compartilhado com `gridwidget.lua`.

A quinta rodada achou mais nove, todos corrigidos:

1. Uma primeira consulta que falhava (banco ocupado ao abrir o menu)
   mostrava "No statistics" por uma hora. Agora falhas recuam de forma
   exponencial: 5, 10, 20, 40 minutos, até `max_age`.
2. Uma renovação que falhava mantinha o card mas o repintava. Agora só há
   repintura quando o que o card mostra mudou.
3. A assinatura não incluía o título, e um título corrigido não aparecia.
4. A faixa usava 5 s fixos para "folheado", e o progresso o limiar do livro:
   a faixa podia pintar como lido o que a porcentagem dizia que não. Agora os
   dois usam o limiar do livro.
5. A renovação horária refazia o GROUP BY inteiro só para calcular a
   assinatura. Agora uma consulta barata devolve um carimbo por livro (linhas,
   tempo, último início); só os livros cujo carimbo mudou têm as páginas lidas
   e analisadas de novo, e os outros reusam a análise anterior.
6. Uma página lida em duas sessões curtas nunca ganhava "primeiro dia", e uma
   releitura dela não aparecia. Agora o primeiro dia é quando ela passa a
   contar como lida no total.
7. "p. 12–12" agora sai "p. 12".
8. `prepare` reordenava e cortava o que o SQL já ordenava e cortava. Agora o
   SQL é o único dono (`ORDER BY last_open DESC, id`).
9. `ink.lua` era carregado duas vezes, em duas tabelas. Agora passa pelo
   loader e é uma tabela só.

A sexta rodada achou mais oito, todos corrigidos:

1. A mediana do ritmo contava linhas: num livro lido por 100 páginas e
   folheado por 200, as folheadas ditavam o ritmo (3 s), o limiar caía a 5 s
   e duas folheadas de 3 s somavam "lida". A mediana agora é ponderada pelo
   tempo: o ritmo em que foi gasta metade do tempo de leitura do livro.
2. A ponte de releitura era 0 em livros com menos de 100 páginas; agora é
   pelo menos 1.
3. Um relógio corrigido para trás no meio da sessão congelava as renovações
   até ele alcançar o horário antigo. Agora voltar para antes da última
   consulta conta como vencido.
4. Sem altura para um livro com a legenda, o card passava da altura que
   recebeu. Agora a legenda sai primeiro.
5. Um parâmetro morto (`revalidating`) em `source.lua`.
6. O bit mais baixo da árvore de Fenwick era achado em laço; com o módulo
   `bit` do LuaJIT, é `band(i, -i)`. O laço fica como alternativa para o
   Lua 5.1 dos testes.
7. A spec ainda dizia "< 5 s" para o degrau 0.
8. O caminho até `ink.lua` estava duplicado nos dois widgets. A faixa agora
   recebe os cinzas de quem a cria (`atlas("ink")`).

## Resultado

14 suítes, 241 testes, 0 falhas. Falta o checklist do aparelho em
`CARRY-FORWARD.md`.
