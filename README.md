# Reading Atlas

Reading insights for [KOReader](https://koreader.rocks), as drop-in
micro-modules for [`bookshelf.koplugin`](https://github.com/AndyHazz/bookshelf.koplugin).

Bookshelf already gives you a home screen worth looking at. Reading Atlas adds
panels to it that show *your reading*: when you read, how much, and — later —
what you read.

> **Status: phase 1 works on a real device.** `atlas_heatmap` and `atlas_clock`
> install, load, and draw inside KOReader on a Kindle. Install with
> `sh tools/install.sh <koreader-settings-dir>`, restart KOReader, then add them
> from bookshelf's module picker.

## What it will have

**Phase 1 — local, offline, no network**

- **`atlas_heatmap`** — a year of reading as a grid of days, GitHub-style.
  Intensity is time read, bucketed into five steps by quartile of your own
  history, so a twenty-minute-a-day reader and a three-hour-a-day reader each
  see the shape of their own year.
- **`atlas_clock`** — an hour × weekday grid. Answers "when do I actually read?"

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

## Prior art

This project stands next to, not against, work that already exists and is good:

- [`readinginsights.koplugin`](https://github.com/peterboda236/readinginsights.koplugin)
  — streaks, records, achievements, heatmap, on-device.
- [KoInsight](https://github.com/Ko-Insight/KoInsight) — self-hosted web
  dashboard for KOReader stats.
- [KoShelf](https://github.com/paviro/KoShelf) — highlights and notes as a
  reading dashboard.

If you want reading statistics today, install those. Phase 1 of Reading Atlas
covers the same axis they do — *when* you read — and covers it well. Where
this project is going is the axis they leave open: the reading map — language,
author, series, and later geography — the *what*, not the *when*.

## License

AGPL-3.0, matching bookshelf, whose module kit these modules build against.
