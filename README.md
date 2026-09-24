# Reading Atlas

Reading insights for [KOReader](https://koreader.rocks), as drop-in
micro-modules for [`bookshelf.koplugin`](https://github.com/AndyHazz/bookshelf.koplugin).

Bookshelf already gives you a home screen worth looking at. Reading Atlas adds
panels to it that show *your reading* — drawn from KOReader's own statistics,
on the device, with nothing sent anywhere.

---

## What works today

Three modules. The first two run on a real Kindle; the third is waiting for one.

**Atlas year** (`atlas_heatmap`) — a year of reading as a grid of days, with
month labels and your totals for the year. Intensity is **time read**, bucketed
into five steps by **quartile of your own history**, so a twenty-minute-a-day
reader and a three-hour-a-day reader each see the shape of their own year
rather than an empty grid or a saturated one.

**Atlas hours** (`atlas_clock`) — an hour × weekday grid answering "when do I
actually read?", with the hour you read most called out underneath.

Atlas year and Atlas hours read KOReader's `statistics.sqlite3` **read-only**.
Nothing is written back, nothing needs a network, and nothing leaves the
device.

**Atlas map** (`atlas_map`) — your whole library as territory: one square
per book, grouped by language, author, series or genre, shaded by how far you
got (unread, on hold, reading, finished). Pick the grouping from the card's
*Module settings*; add the card twice to see two at once. It reads bookshelf's
own library, not the statistics database, so it is full even if you have
barely opened a book in KOReader. **Not yet verified on a device.**

### Install

```sh
sh tools/install.sh <koreader-settings-dir>
```

| Device | Settings directory |
|--------|--------------------|
| Kindle | `/mnt/us/koreader/settings` |
| Kobo | `/mnt/onboard/.adds/koreader/settings` |
| Android | `<koreader-dir>/settings` |

Restart KOReader, then add **Atlas year**, **Atlas hours** and **Atlas map**
from bookshelf's module picker: open the module grid, long-press a module, and
tap **+**.

The installer copies into `<settings>/bookshelf/micromodules/`, which lives
outside the plugin — so the modules survive bookshelf updates.

---

## Planned

**Phase 3 — the reading map, enriched.** Country — and genre for books that
carry none — which the statistics database does not carry and which have to
come from elsewhere. Bookshelf's own Hardcover integration already stores a
per-book id, and that id is what would make enrichment reliable rather than a
guess at matching titles.

The geographic map will be drawn as a **tile grid** — one square per country in
a layout that evokes the world — rather than real country outlines. There is no
polygon fill in KOReader, and at e-ink sizes a tile grid reads better anyway,
reusing the same drawing code as the heatmap.

The *what* axis is the reason this project exists; the *when* axis of phase 1
is the groundwork. Each phase gets its own design document under
[`docs/`](docs/) before any code is written.

### Not planned

Writing to the statistics database. Anything requiring a network in phase 1 or
2. Replacing bookshelf, which this project is built to live inside.

---

## Why micro-modules instead of a plugin

Bookshelf documents a drop-in module API: a `.lua` file placed in
`<koreader settings>/bookshelf/micromodules/` is discovered automatically, with
no registry to edit and no fork required.

That buys the whole surrounding UI — shelves, covers, search, the home grid,
the full-screen module dashboard — for free, and leaves this project to write
only the part that does not exist yet.

The trade-off is coupling: these modules `require` bookshelf's module kit, so a
change to its contract is felt here. That is a deliberate choice in favour of
iteration speed.

---

## Development

```sh
sh tests/run.sh          # 10 suites, 126 tests
LUA=luajit sh tests/run.sh
```

The suites run under a standalone Lua interpreter, **not** inside KOReader, by
stubbing the KOReader modules a unit reaches for. Write **Lua 5.1**-compatible
code — KOReader runs LuaJIT, so `//`, `goto` and bitwise operators load fine on
a laptop and then fail on the device.

All the logic worth asserting — bucketing, the quartile scale, the calendar
mapping, grid geometry, the three-state cache — is pure and tested here. The
SQLite access, the blitbuffer painting and the atlas_heatmap/atlas_clock
module files cannot be tested off-device and are verified on real hardware
instead. atlas_map.lua is exercised off-device against stubs too, and its
bookshelf repository access against a fake repository, but the map's painting
and the real repository still need the device — see
[`docs/CARRY-FORWARD.md`](docs/CARRY-FORWARD.md) for what's left to verify.

[`docs/CARRY-FORWARD.md`](docs/CARRY-FORWARD.md) collects what the device
taught that no test could, including the one that crashed a Kindle.

## License

AGPL-3.0, matching bookshelf, whose module kit these modules build against.
