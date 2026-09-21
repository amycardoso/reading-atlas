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

## Still unverified

Nothing in this repository has ever executed inside KOReader. `db.lua`,
`gridwidget.lua`'s `paintTo`, and both module files have no unit tests and
cannot have them off-device. The on-device checklist in
`docs/superpowers/plans/2026-09-20-reading-atlas-phase-1.md` (Task 9, Step 3)
has **not** been run.
