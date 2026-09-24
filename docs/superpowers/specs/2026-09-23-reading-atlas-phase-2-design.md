# Reading Atlas — fase 2: o mapa territorial

**Data:** 2026-09-23
**Status:** desenho aprovado, pendente de plano de implementação
**Spec anterior:** [`2026-09-20-reading-atlas-micromodules-design.md`](2026-09-20-reading-atlas-micromodules-design.md)

## Objetivo

Um módulo novo, `atlas_map`, que mostra a **biblioteca inteira** do aparelho
como território: cada livro é um quadrado, os livros se agrupam em regiões por
idioma, autor, série ou gênero, e o tom de cada quadrado é o **status** de
leitura do livro.

A pergunta que o card responde é "qual é a forma da minha biblioteca, e quanto
dela eu já explorei?".

## O que mudou em relação ao spec original

O spec de 2026-09-20 previa a fase 2 sobre a tabela `book` do
`statistics.sqlite3`, com os livros já abertos. Duas descobertas mudaram isso:

1. **Pouca estatística é o caso normal.** O banco real verificado na fase 1
   tinha 10 livros. Um mapa só dos livros lidos, com 10 livros, é uma dezena de
   quadrados, não um mapa.
2. **O bookshelf já agrupa a biblioteca inteira.** Investigado no commit
   `cbce46e` do `bookshelf.koplugin`:
   - `Repo.getGroupFilepaths(kind)` devolve `{ [nome do território] = { caminho, … } }`
     para `kind` = `language`, `author`, `series`, `genre`. Lê dos caches que
     alimentam as abas de Séries/Autores/Idiomas/Gêneros; não carrega capas
     nem hidrata registros.
   - A normalização já vem feita: idioma canônico com nome legível ("pt-BR" e
     "por" viram um grupo só), autor unificado ("Assis, Machado de" = "Machado
     de Assis"), gênero com plural colapsado.
   - `Repo.readProgress(fp)` devolve o status por livro a partir do sidecar do
     KOReader, sem estatísticas, já no vocabulário do bookshelf
     (`complete` → `finished`, `abandoned` → `on_hold`).
   - O módulo `shelf_size` do próprio bookshelf chama `Repo` diretamente, então
     isso é uso previsto por um micro-módulo, não um atalho.

Consequências:

- A fase 2 **não lê** o `statistics.sqlite3`.
- **Gênero** sai da fase 3 e entra aqui, para quem tem tags do Calibre ou
  keywords no EPUB. A fase 3 continua dona de **país**, e de gênero só para
  livros que não o tragam localmente.
- A intensidade é **status**, não tempo lido. Os quatro status, mais o
  "sem livro", casam com os cinco degraus de cinza já validados no aparelho.

## Riscos aceitos

- **`getGroupFilepaths` é pública mas não documentada** no README dos
  micro-módulos. Se o bookshelf mudá-la, o módulo sente. Mitigação: toda
  chamada ao `Repo` passa por `pcall` e cai no estado *Indisponível*, nunca
  num crash.
- **A biblioteca nativa do Kindle não entra.** Os grupos do bookshelf cobrem
  só os arquivos da pasta do KOReader (`home_dir`). `countByStatus` soma os
  livros da Amazon à parte, mas sem idioma ou autor. Fica fora da fase 2.
- **A primeira montagem dos grupos percorre a biblioteca.** Roda fora do paint,
  no mesmo padrão de `source.lua` da fase 1 (issue #194 do bookshelf).

## O módulo

| Campo | Valor |
|---|---|
| `key` | `atlas_map` (congelada a partir do primeiro install) |
| `title` | "Atlas map" |
| `summary` | "Your library by language, author, series or genre. Works offline." |
| `show_settings` | escolha de eixo |

Um módulo só; o eixo é **configuração por instância** (`ctx.config`, o mesmo
mecanismo do `countdown` do bookshelf). Quem quiser dois mapas adiciona o
módulo duas vezes. Uma chave congelada só, e eixos novos no futuro não
exigem módulos novos.

Eixos: Idioma (**padrão**), Autor, Série, Gênero.

## Layout

Um mapa só, na linguagem do heatmap:

```
Atlas map · Languages
Portuguese      English Spa…  Others
█ █ █ ▓ ▒ ░ ░   █ ▒ ░   █ ░   ░
█ █ ▓ ▒ ░ ░ ░   █ ░ ░   ░
█ █ ▓ ▒ ░ ░     ▓ ░ ░
68 books · 23 finished · 12 languages
```

- Os livros preenchem colunas **de cima para baixo**. Cada território começa
  numa coluna nova, e entre dois territórios há **uma coluna vazia** (não
  pintada) como fronteira.
- Os rótulos ficam na faixa de rótulos do `gridwidget` (acima da grade),
  alinhados à primeira coluna do território.
- Territórios do **maior para o menor** em número de livros; empate por nome.
  "Others" (Outros) sempre por último.
- Dentro de um território, livros do **mais escuro para o mais claro**:
  terminado, lendo, em pausa, não lido.

### Status → tom

| Status (bookshelf) | Também aceito (KOReader cru) | Degrau | Tom |
|---|---|---|---|
| `finished` | `complete` | 4 | `0x20` |
| `reading` | — | 2 | `0x80` |
| `on_hold` | `abandoned` | 1 | `0xB0` |
| `unread`, `new`, `nil`, qualquer outro | — | 0 | `0xE0` |
| sem livro (fronteira, fim de coluna) | — | `nil` | não pintado |

Quatro dos cinco tons já validados no Paperwhite; o degrau 3 fica sem uso de
propósito, para abrir contraste entre *lendo* e *terminado*. Os dois
vocabulários são aceitos porque o bookshelf já normaliza, mas o módulo não
deve quebrar se um caminho futuro entregar o valor cru.

Só cinza. Os módulos não usam cor: `Blitbuffer.Color8` é luminância, e num
Kindle colorido os cinzas aparecem como cinzas. Cor fica para depois de haver
um aparelho colorido para verificar.

### Quem entra e quem vai para "Others"

O número de territórios mostrados **sai do espaço disponível**, não de um N
fixo. Um território fica no mapa só se a largura das suas colunas comportar um
rótulo mínimo — três letras e reticências, medido com a fonte real. Senão ele
é somado a "Others".

Algoritmo, em `territory.lua`:

1. Ordena os territórios.
2. Para cada número de linhas candidato — de 1 até o número de livros do
   maior território, parando quando a célula cair abaixo de 2 px — calcula colunas por território
   (`ceil(n / linhas)`), a largura total com fronteiras, e o tamanho de célula
   pelo `grid.lua`.
3. Enquanto o território **menor** não comportar o rótulo mínimo, dobra-o em
   "Others" e recalcula.
4. Entre os números de linhas, escolhe o que dá **a maior célula**; empate vai
   para menos linhas.

"Others" também só ganha rótulo se couber; se nem ele couber, é desenhado sem
rótulo. Rótulos que não cabem por inteiro **truncam com reticências**, mas
nenhum território visível fica **sem** rótulo — diferente dos meses do
heatmap, em que pular um mês se deduz e pular um idioma não.

A medida do texto é um parâmetro (`measure(text) -> px`), para o algoritmo ser
testável sem o KOReader.

### Livros sem o atributo

- **Idioma:** o bookshelf já os agrupa em "Unknown"; entram como território.
- **Autor:** idem, se houver.
- **Gênero:** entram num território "No genre". Se **nenhum** livro tiver
  gênero, o card mostra o estado *Nenhum livro com gênero* em vez de um mapa
  de um território só.
- **Série:** os livros sem série **ficam de fora** — esse território seria o
  maior de todos e engoliria o mapa. A linha de contexto avisa:
  `· 41 not in a series`.

### Cabeçalho e linha de contexto

- Cabeçalho: `Atlas map · <eixo>`. O eixo sempre aparece, porque com duas
  instâncias na home é preciso saber qual é qual.
- Contexto: `<livros> books · <terminados> finished · <territórios> <eixo>`.
  A contagem de territórios é a real, incluindo os dobrados em "Others".

Todos os textos passam por `_()` do bookshelf, como na fase 1. Os exemplos
acima são as chaves em inglês.

## Estados

Três, nunca confundidos, como na fase 1:

| Estado | Quando | Card |
|---|---|---|
| ainda não consultado | grupos ainda sendo montados | `valueCard` "Reading…" |
| indisponível | `Repo` ausente, função ausente, ou erro | `valueCard` "Unavailable" / "Update bookshelf" |
| biblioteca vazia | consulta ok, zero livros no eixo | `valueCard` "No books" |

Mais um específico do eixo gênero: *No genres* / "None of your books carry a
genre tag."

O preview do picker (`ctx.preview`) usa os dados em cache se houver, ou
"Reading…". Nunca dados falsos.

## Toque

Nenhuma ação na v1. Abrir a estante do território ao tocar é desejável, mas
mexe na navegação do bookshelf; fica para depois.

## Arquitetura

```
Repo.getGroupFilepaths(axis) ─► atlas/library.lua ─► atlas/territory.lua ─► atlas/gridwidget.lua
Repo.readProgress(fp)            (I/O, pcall)          (lógica pura)           (já existe)
```

### `atlas/library.lua` (novo; só verificável no aparelho)

`library.territories(axis)` → `{ { name = "Portuguese", statuses = { "finished", "reading", … } }, … }`
ou `nil` quando o `Repo` não responde.

- `require("lib/bookshelf_book_repository")` dentro de `pcall`.
- Checa que `Repo.getGroupFilepaths` e `Repo.readProgress` existem.
- Um `readProgress` que falha num arquivo vale "não lido" para aquele livro;
  não derruba a consulta.
- Um livro pode aparecer em mais de um território (vários autores ou gêneros).
  Isso é aceito: o mapa conta presenças em territórios. A contagem de
  **livros** na linha de contexto usa caminhos distintos.

Os valores de retorno são strings Lua comuns — nenhum ponteiro de SQLite
atravessa esta camada (ver `CARRY-FORWARD.md`).

### `atlas/territory.lua` (novo; lógica pura, onde mora o teste)

- `territory.level(status)` → `0 | 1 | 2 | 4`.
- `territory.plan{ territories, width, height, measure, gap_ratio, grid }` →
  `{ rows, cols, cells = { [col] = { [row] = level|nil } }, labels = { { col, text } }, others = n }`.
- `territory.summary(territories, axis)` → contagens para a linha de contexto.

### `atlas/source.lua` (alterado)

Passa a guardar **um cache por chave** (`"hours"` para a fase 1, `"map:<axis>"`
para a fase 2), cada um com os mesmos três estados, a mesma guarda contra
consultas concorrentes e a mesma entrega de `refresh` a todos os chamadores.
Os módulos da fase 1 continuam chamando a mesma função com o mesmo
comportamento.

### `atlas/gridwidget.lua` (alterado)

- `level(col, row)` retornar `nil` passa a significar **não pintar**. Hoje vira
  o degrau 0. O heatmap e o clock nunca retornam `nil` (o heatmap devolve `0`
  explicitamente fora do ano), então nada muda para eles.
- Rótulos ganham um modo `truncate`: em vez de pular rótulos em passo regular,
  cada rótulo é cortado com reticências para caber até o próximo. O modo atual
  continua o padrão, para os meses e as horas.

Continua `Widget:extend{}` e construído com `:new{}` — ver
`CARRY-FORWARD.md`.

### `micromodules/atlas_map.lua` (novo)

Só composição, como os dois módulos da fase 1: estado → `valueCard`, ou
cabeçalho + `gridwidget` + contexto. Fonte via `Kit.face`, espaço via
`Kit.sc`, sem loop próprio de fonte.

## Testes

### No computador (`tests/run.sh`, Lua 5.1)

- `_test_territory.lua` (novo):
  - mapeamento de status, incluindo os dois vocabulários e valores
    desconhecidos → não lido;
  - ordem dos territórios e dos livros dentro deles;
  - dobra em "Others" com um `measure` falso: um território só; 10 livros;
    300 livros; todos os territórios com um livro;
  - escolha do número de linhas;
  - colunas de fronteira não pintadas, fim de coluna não pintado;
  - série exclui "sem série" e conta os excluídos;
  - contagem de livros distintos quando um livro está em dois territórios.
- `_test_gridwidget.lua`: `level() == nil` não pinta; degrau 0 continua
  pintado; modo `truncate` não pula rótulos; o widget continua herdando de
  `Widget`.
- `_test_source.lua`: chaves separadas não compartilham cache; os casos da
  fase 1 continuam passando.
- `_test_library.lua` (novo): `Repo` falso em `package.loaded`. `Repo`
  ausente, função ausente e erro → `nil`; `readProgress` que falha num arquivo
  → aquele livro "não lido", os outros intactos.

### Só no aparelho

Checklist registrado em `CARRY-FORWARD.md`, a rodar com o Kindle em mãos:

1. O card aparece no picker e **tocar nele não derruba o KOReader**.
2. Os quatro tons se distinguem, em especial em pausa (`0xB0`) contra não
   lido (`0xE0`).
3. A coluna vazia lê como fronteira entre territórios.
4. Rótulos truncados são legíveis.
5. A primeira montagem dos grupos numa biblioteca real não congela o menu.
6. Trocar o eixo em *Module settings* redesenha o card.

## Fora de escopo

- Tempo lido como intensidade (exigiria cruzar arquivo e `statistics.sqlite3`
  pelo md5).
- Cor.
- Toque que abre a estante do território.
- Biblioteca nativa do Kindle.
- País — continua na fase 3.
