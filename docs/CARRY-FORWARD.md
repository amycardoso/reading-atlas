# Carry-forward notes

Things learned while building phase 1 that will cost time — or break on the
device — if they are forgotten. Kept in the repository because the scratch
workspace they were discovered in does not survive.

## Reading TEXT columns after closing the database will bite phase 2

Phase 1's query selects only integers, and `micromodules/atlas/db.lua` builds
its rows **after** `conn:close()`. That is safe *only because the columns are
integers*.

In the `lua-ljsqlite3` that KOReader vendors, `conn:exec()` materialises INTEGER
and FLOAT columns into independent Lua values, but a TEXT or BLOB column comes
back as a pointer wrapper that is **not** copied. Reading one after the
connection closes is undefined behaviour.

Phase 2's territorial map wants `title`, `authors`, `language` and `series` —
all TEXT. Those must be read into Lua strings **before** the connection closes,
or copied explicitly. On an e-reader the failure mode is a crash, which for the
user means a hard reboot.

## The host owns size; do not fight it

`bookshelf` re-renders a module at different `scale_pct` values until the card
fits its cell. Never write a font-fitting loop, and size every font through
`Kit.sc` / `Kit.face`. This is documented in bookshelf's own
`micromodules/README.md` and is the single easiest way to make a module
misbehave.

## Helpers cannot be reached with `require("lib/...")`

Inside KOReader, `package.path` points at bookshelf's plugin root, so
`require("lib/aggregate")` resolves into **bookshelf's** `lib/`, not ours.
`micromodules/atlas/loader.lua` exists solely to avoid this: it resolves from
the calling file's own directory with `dofile` and memoises in `package.loaded`.
Any new helper must be loaded through it.

## Module keys are frozen

`atlas_heatmap` and `atlas_clock` are stored in users' saved menus. Renaming one
silently removes that card from every existing install. New modules get new
keys; existing ones never change.

## A 53-column grid needs 158 px to show separated days

53 cells of 2 px with 1 px gaps is exactly 158 px. Below that, the geometry
prefers larger touching cells over 1 px dots. If a future layout puts the year
card in a narrower slot, it will read as a solid block — that is arithmetic,
not a bug to fix in `grid.lua`.

## Anything painted must extend KOReader's `Widget`

`micromodules/atlas/gridwidget.lua` was once a bare Lua table carrying only
`getSize` and `paintTo`. It painted correctly. Every unit test passed, and
several careful reviews verified its arithmetic cell by cell. On a real Kindle
it crashed KOReader to the launcher the moment a module was tapped, because a
container propagated an event into it and `handleEvent` was nil — an error
inside the UI loop takes the whole application down.

The rule: anything handed to bookshelf as a widget must be
`require("ui/widget/widget"):extend{}` and constructed with `:new{}`. Painting
correctly is not the same as being a widget.

No off-device test can catch this on its own — the suites stub `ui/geometry`
and `ffi/blitbuffer` and never exercise the widget protocol — so
`tests/_test_gridwidget.lua` now asserts the inherited methods exist. That
assertion is the only thing standing between this bug and a user's e-reader.

## Still unverified

Installation on a real Kindle is verified, and every pure helper has been run
against a real `statistics.sqlite3` (10 books, 696 page-session rows) producing
correct heatmap and clock grids — all five intensity levels used, quartiles
evenly distributed.

What remains unverified is anything that only happens *inside* KOReader:
`gridwidget.lua`'s `paintTo` against a real blitbuffer, `db.lua`'s SQLite access
through KOReader's own bindings, and whether the five greys are distinguishable
on the actual panel. Those cannot be tested off-device and have never run.

## macOS writes sidecar files onto e-reader filesystems

Copying to the FAT/exFAT volume a Kindle exposes creates AppleDouble `._name`
files. Two of them end in `.lua` and land exactly where bookshelf's scanner
looks. `tools/install.sh` strips them; anything else that writes modules to a
device from macOS must do the same.
