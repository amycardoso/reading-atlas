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

## What device testing actually caught

Phase 1 passed 51 unit tests, a per-task review each, and a whole-branch review
on the most capable model available. Then it crashed a Kindle to the launcher
the first time a module was tapped, because the painted object was a bare table
rather than a `Widget` — see the section above.

Every layer of review had verified `paintTo`'s arithmetic cell by cell and
found it correct. It was correct. Nobody asked whether the thing doing the
painting was a widget at all, because the plan asserted it was and the reviews
checked the code against the plan.

Two smaller things only the hardware showed: macOS AppleDouble sidecars landing
in the scanner's path, and module titles that are indistinguishable from
bookshelf's own in a crowded picker (issue #1).

The lesson is not "test more". It is that a premise stated confidently in a
plan propagates through every review that trusts it, and the only thing that
does not trust it is the device.

## Verified on device

Both modules install, load, appear in bookshelf's picker, and draw their full
cards -- heading, column labels, grid and context line -- inside KOReader on a
Kindle Paperwhite 3. All twelve month labels fit at that card width, and the
five grey steps are clearly distinguishable on the panel.

Three rounds of photographs found three things no test could: the crash, a
context line clipped off the bottom because the label strip was not taken out
of the height budget, and month labels dropped irregularly. Each was invisible
locally and obvious on screen. The pipeline was also run end to end against a
real `statistics.sqlite3` (10 books, 696 page-session rows): all five intensity
levels used, quartiles evenly distributed.

## Phase 2: verify on the device before calling it done

`atlas_map` passed every off-device suite. That is exactly where phase 1 stood
before a Kindle crashed. Nothing below has been seen on a screen yet:

1. The card appears in the picker, and **tapping it does not take KOReader
   down**.
2. The four greys are distinguishable, especially on hold (`0xB0`) against
   unread (`0xE0`).
3. The blank column reads as a border between territories.
4. Truncated labels ("Portu…") are legible, and TextWidget really does add the
   ellipsis at `max_width`.
5. The first build of bookshelf's groups on a real library does not freeze the
   menu.
6. Changing the axis in *Module settings* redraws the card.

And one design consequence to look at with a real library: one cell per book
means a library of many one-book authors cannot name them at card size. On the
author axis such a library draws mostly "Others". That is the rule working,
not a bug in `territory.lua` — but whether it is the right rule is a question
for the device.

## bookshelf's group API is not a documented contract

`atlas/library.lua` depends on `Repo.getGroupFilepaths`, `Repo.readProgress`
and `Repo.getAllFilepaths`, checked against bookshelf commit `cbce46e`. They
are public functions but not part of the micro-module README. If a bookshelf
update renames one, the card shows "Unavailable" rather than crashing — that
is what the `pcall`s are for, and `tests/_test_library.lua` holds them to it.

## The library is read once per KOReader session

Like phase 1's statistics, each axis is cached for the life of the process.
A book finished or added after the first render shows up after a restart.
