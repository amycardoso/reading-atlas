# Reading Atlas

Reading insights for [KOReader](https://koreader.rocks), as drop-in
micro-modules for [`bookshelf.koplugin`](https://github.com/AndyHazz/bookshelf.koplugin).

Bookshelf already gives you a home screen worth looking at. Reading Atlas adds
panels to it that show *your reading*: when you read, how much, and — later —
what you read.

> **Status: phase 1 works on a real device.** Both modules install, load, and
> draw inside KOReader on a Kindle. Install with
> `sh tools/install.sh <koreader-settings-dir>`, restart KOReader, then add
> **Atlas year** and **Atlas hours** from bookshelf's module picker.

## What it will have

**Phase 1 — local, offline, no network**

- **Atlas year** (`atlas_heatmap`) — a year of reading as a grid of days.
  Intensity is time read, bucketed into five steps by quartile of your own
  history, so a twenty-minute-a-day reader and a three-hour-a-day reader each
  see the shape of their own year.
- **Atlas hours** (`atlas_clock`) — an hour × weekday grid. Answers "when do I
  actually read?"

**Later** — the reading map: your library as territory (language, author,
series), then as geography (country, genre), each in its own design document.

Everything in phase 1 reads KOReader's own `statistics.sqlite3`, read-only.
Nothing is written back, and nothing leaves the device.

## Why micro-modules instead of a plugin

Bookshelf documents a drop-in module API: a `.lua` file placed in
`<koreader settings>/bookshelf/micromodules/` is discovered automatically, with
no registry to edit and no fork required. The folder lives outside the plugin,
so modules survive bookshelf updates.

That buys the whole surrounding UI — shelves, covers, search, the home grid,
the full-screen module dashboard — for free, and leaves this project to write
only the part that does not exist yet.

The trade-off is coupling: these modules `require` bookshelf's module kit, so a
change to its contract is felt here. That is a deliberate choice in favour of
iteration speed.

## Where this is going

Phase 1 covers the axis of *when* you read: a year of days, and an hour ×
weekday grid. Phase 2 turns to the axis of *what* — the reading map: your
library as territory, by language, author and series, and later by geography.

That second axis is the reason this project exists. It needs metadata the
statistics database does not carry, so it gets its own design document rather
than being bolted onto phase 1.

## License

AGPL-3.0, matching bookshelf, whose module kit these modules build against.
