# Reading Atlas — micro-módulos de leitura para o KOReader

**Data:** 2026-09-20
**Status:** desenho aprovado, pendente de plano de implementação

## Objetivo

Um conjunto de micro-módulos que mostram a leitura da pessoa dentro da UI do
`bookshelf.koplugin`: primeiro o eixo do tempo (quando e quanto se lê), depois o
eixo do conteúdo (o que se lê) — o "mapa de leitura".

O projeto **não** constrói uma UI nova. Ele se hospeda na do bookshelf.

## Por que micro-módulos e não um plugin próprio

O bookshelf expõe uma API documentada de módulos drop-in
(`micromodules/README.md`). Um arquivo `.lua` colocado em
`<koreader settings>/bookshelf/micromodules/` é descoberto no primeiro acesso ao
registry, carregado por `dofile`, e aparece no picker. Não há registry para
editar, não é preciso fork, e a pasta fica **fora** do plugin, de modo que os
módulos sobrevivem a atualizações do bookshelf.

Em troca, herda-se de graça: estantes, capas, busca, OPDS, o grid da home, a
superfície full-screen (que é a "tela de insights") e o start menu.

**Custo aceito:** acoplamento ao bookshelf. Os módulos fazem
`require("lib/bookshelf_module_kit")`, um caminho dele. Se o contrato mudar, os
módulos sentem. Decisão consciente: a velocidade de iteração compensa.

## Contrato do host (o que não se discute)

> "The host owns SIZE. You own CONTENT."

O bookshelf renderiza o módulo numa célula e re-renderiza em `scale_pct`
diferentes até caber. Consequências que valem como regra do projeto:

- Nunca escrever loop próprio de fonte — briga com o do host.
- Toda fonte dimensionada via `Kit.sc` / `Kit.face`.
- Cards de estatística usam `Kit.valueCard{...}`, o mesmo que `reading_goal` e
  `reading_stats` usam, para que os módulos pareçam nativos.
- Cores pelos papéis compartilhados: `Kit.COLOR_PRIMARY`, `Kit.COLOR_MUTED`,
  `Kit.CARD_BG`.

O spec de cada módulo declara `key`, `title`, `summary`, `render(ctx)` e, quando
fizer sentido, `on_tap`, `show_settings`, `aspect`.

### Chaves

`key` é "a stable id stored in user menus (never change)". Todos os módulos
deste pack usam o prefixo `atlas_` (`atlas_heatmap`, `atlas_clock`) para nunca
colidir com um módulo futuro do próprio bookshelf.

Consequência: **o nome do pack é barato de trocar agora e caro depois.** Se
"Reading Atlas" não agradar, trocar antes do primeiro release.

## Fonte de dados

| Dado | Origem | Disponibilidade |
|---|---|---|
| Tempo, páginas, timestamp por sessão | `statistics.sqlite3` | sempre, offline |
| Título, autor, série, idioma | `statistics.sqlite3` (tabela `book`) | sempre |
| Gênero | tags do Calibre ou keywords embutidas do EPUB, via bookshelf | só se o acervo tiver |
| País, nacionalidade, ano de publicação | não existe localmente | exige rede |

Esquema relevante do KOReader:

- `book(id, title, authors, notes, last_open, highlights, pages, series,
  language, md5, total_read_time, total_read_pages)`
- `page_stat_data(id_book, page, start_time, duration, total_pages)` — uma linha
  por página lida por sessão, com timestamp. É daqui que sai tudo da fase 1.

### Acesso

```lua
local path = require("datastorage"):getSettingsDir() .. "/statistics.sqlite3"
local conn = require("lua-ljsqlite3/init").open(path, "ro")
conn:exec("PRAGMA busy_timeout=200;")
```

Sempre somente-leitura. O banco é do plugin de estatísticas do KOReader; este
projeto é um consumidor, nunca um escritor.

### Desempenho (restrição dura)

O `reading_streak` do bookshelf carrega a cicatriz de um bug real (#194): uma
consulta síncrona num banco grande congela o menu ao abrir. Portanto:

- A consulta roda **uma vez** por sessão de UI, com guarda de "já consultei".
- Roda **fora do caminho crítico** do primeiro render; o módulo desenha um
  estado de carregando e chama `ctx.refresh` quando os dados chegam.
- Três estados distintos, nunca confundidos: *ainda não consultei*, *consultei e
  não há banco/estatísticas*, *consultei e tenho dados*.

## Desenho em e-ink

Grade de células é widget próprio, no padrão do `analogue_clock`:

```lua
function W:getSize() return Geom:new{ w = ..., h = ... } end
function W:paintTo(bb, x, y) ... end   -- bb:paintRect por célula
```

Sem antialias, sem gradiente: a tela é cinza de poucos níveis. A intensidade de
cada célula é **um de cinco degraus** — vazio mais quatro níveis de cinza, como
o heatmap do GitHub — e não uma rampa contínua. Cinco é o teto do que se
distingue de forma confiável em e-ink a esse tamanho de célula.

Os degraus são **relativos ao próprio histórico** da pessoa, por quartis dos
dias com leitura, nunca por minutos absolutos. Um limiar fixo faria o heatmap de
quem lê vinte minutos por dia parecer vazio e o de quem lê três horas parecer
saturado; por quartil, os dois leem a própria forma. Dias sem leitura são o
degrau vazio e ficam fora do cálculo dos quartis.

**Consequência de projeto:** o mapa geográfico da fase 3 **não** desenha
contornos de países. Não há preenchimento de polígono no KOReader e o
renderizador de SVG do bookshelf é limitado a formas sólidas simples. Em vez
disso, *tile grid map*: cada país é um quadrado numa grade que evoca o formato
do mundo. Mais legível em tela pequena, e reaproveita o mesmo código de grade do
heatmap — os dois módulos viram a mesma linguagem gráfica.

## Escopo por fase

### Fase 1 — o que será construído agora

**`atlas_heatmap`** — grade de dias do ano, estilo GitHub. Cada célula é um dia,
a intensidade é o **tempo lido** naquele dia (não páginas: tempo é comparável
entre livros, páginas não). Navegável por ano.

**`atlas_clock`** — grade hora × dia-da-semana. Responde "a que horas eu leio".

As duas são puramente locais, offline, e exercitam o caminho inteiro: ler o
sqlite, agregar, desenhar uma grade, aparecer no bookshelf. Risco baixo, valor
imediato.

### Fase 2 — mapa territorial (spec própria)

A biblioteca como território, com os dados que já existem: idioma, autor, série.
Mesmo widget de grade, rótulos diferentes.

### Fase 3 — mapa geográfico (spec própria)

País e gênero exigem enriquecimento externo (Hardcover ou OpenLibrary). O
bookshelf já guarda um `book_id` do Hardcover por livro quando o
`hardcoverapp.koplugin` está em uso — é a chave estrangeira que torna o
enriquecimento confiável em vez de casamento por título.

Nota de oportunidade: o bookshelf tem `Repo.setEmbeddedGenres()`, que escreve no
campo Keywords customizado do KOReader. Gênero enriquecido por este projeto
acende as estantes por gênero do bookshelf automaticamente.

### Fora de escopo

- Streaks, recordes e achievements. O eixo temporal já é bem servido no
  ecossistema; este projeto entra por outro lado.
- Dashboard web.
- Escrever no banco de estatísticas.
- Card SVG exportável para README. Ideia viva, fase posterior.

## Estratégia de testes

O harness do bookshelf (`tests/run.sh`) roda em `lua` puro **fora do KOReader**,
stubando os módulos do KOReader via `package.loaded`. Isso define a fronteira:

- **Testável no computador, e por isso onde mora a lógica:** agregação por dia e
  por hora, fronteiras de fuso e de virada de dia, semana começando domingo ou
  segunda, escolha dos degraus de intensidade, geometria da grade (quantas
  colunas cabem em N pixels), ano sem dados, banco ausente.
- **Verificável só no aparelho:** a pintura em si, legibilidade dos degraus de
  cinza, comportamento sob o redimensionamento do host, refresh de e-ink.

A lógica pura fica em arquivos separados do `render`, justamente para poder ser
testada sem stub de widget.

## Licença

O bookshelf é **AGPL-3.0** e os módulos fazem `require` no `Kit` dele. Se este
pack for distribuído, sai sob licença compatível. Resolver antes do primeiro
release público, não depois.

## Relação com upstream

Histórico de PRs do bookshelf: módulos sobre leitura entram (Reading Challenge,
Reading Streak, Reading Stats, On This Day); widgets genéricos não (Jokes,
Useless Facts, Exchange Rates). Os módulos da fase 1 são candidatos naturais a
PR depois de amadurecerem em uso. O mapa enriquecido da fase 3, que precisa de
rede, provavelmente permanece fora do upstream — e tudo bem.

O desenvolvimento acontece na pasta de usuário, sem depender de review para
iterar.
