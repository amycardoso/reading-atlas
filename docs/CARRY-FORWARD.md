# Carry-forward notes

Things learned while building phase 1 that will cost time — or break on the
device — if they are forgotten. Kept in the repository because the scratch
workspace they were discovered in does not survive.

## Read every column before the connection closes

Phase 1's query selects only integers, and `hourRows` in
`micromodules/atlas/db.lua` builds its rows **after** `conn:close()`.

This note used to say that TEXT columns come back from KOReader's vendored
`lua-ljsqlite3` as pointer wrappers that are not copied. Checked against
KOReader v2026.07 while building phase 3, that is not quite right:
`common/lua-ljsqlite3/init.lua` copies TEXT with `ffi.string`, so a title is a
real Lua string. INTEGER columns come back as `int64` cdata, which is why every
value goes through `tonumber`. The column type that does stay tied to the
statement is **BLOB**.

Phase 3's `fingerprintRows` reads `book.title`, the first TEXT column this
project takes from `statistics.sqlite3`. It still turns every value into a plain
Lua value **inside** the `pcall` and before `conn:close()`, and
`tests/_test_db.lua` fails if a value is read after close. That costs nothing
and holds even if a future KOReader changes how TEXT is returned. On an
e-reader, reading freed memory is a crash, which for the user means a hard
reboot.

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

## Phase 3: verify on the device before calling it done

`atlas_fingerprint` passed every off-device suite. It also ran in KOReader
v2026.07 desktop against a simulated `statistics.sqlite3` (six books, a font
change mid-book, re-reads, a book paused for months) at Paperwhite and basic
Kindle sizes, with no errors in the log. None of that is e-ink or a slow CPU:

1. The card appears in the picker, and **tapping it does not take KOReader
   down**.
2. Titles appear correctly, accents included. This is the first TEXT read from
   the statistics database.
3. The query on a real database with years of reading does not freeze the menu.
4. Strips of real books show structure, not uniform noise. If every strip
   comes out one grey, the shared per-card quartiles are wrong for real data.
5. The re-read bar is visible, and the dotted "not read yet" line reads as
   the rest of the book on the panel, without vanishing or looking like ink.
6. A book read with two different fonts shows no break in its strip.

A known limit, kept on purpose: a book whose back matter (notes, bibliography,
index) is longer than 3% of it never shows as finished from the statistics
alone, because `statistics.sqlite3` does not know where the main text ends.
KOReader's own "complete" status lives in the book's sidecar, which the `book`
table does not link to a file. If real libraries show many such books stuck at
85–95%, reading the sidecar status (through bookshelf's `Repo.progressFor`,
as `atlas_map` does) is the fix.

One behaviour to judge on the device rather than fix: in a cell shared with
other cards, bookshelf picks the largest scale that fits, which can mean one
book at a large size instead of several at a smaller one. Full screen shows
six. The host owns size (above), so this is the rule working.

## bookshelf's group API is not a documented contract

`atlas/library.lua` depends on `Repo.getGroupFilepaths`, `Repo.readProgress`
and `Repo.getAllFilepaths`, checked against bookshelf commit `cbce46e`. They
are public functions but not part of the micro-module README. If a bookshelf
update renames one, the card shows "Unavailable" rather than crashing — that
is what the `pcall`s are for, and `tests/_test_library.lua` holds them to it.

## Every card refreshes on its own

Each card's query has a `max_age` in `source.getKeyed`. Past it, the next
render returns the old result and starts a fresh query off the paint path,
and the card is redrawn only if what it shows changed:

| Card | Key | max_age |
|------|-----|---------|
| Atlas year, Atlas hours | `hours` | 1 h |
| Atlas fingerprint | `fingerprint` | 1 h |
| Atlas map | `map:<axis>` | 6 h: a library changes slowly, and the walk is the most expensive query |

Until phase 3 these were read once per KOReader session, so a KOReader left up
for weeks of suspend and resume kept the first answer. For the fingerprint
that was a bug, not staleness: a book read every day drifted to "paused".

A failed query backs off from 5 minutes, doubling up to the card's `max_age`:
a busy database (the statistics plugin flushing) costs minutes, and a missing
one is asked again only once per `max_age` -- hourly for the statistics cards,
every 6 hours for the map.

## A re-read later the same day is not detected

The fingerprint's page rows are summed per local day: that is what keeps a
long book to a few thousand rows instead of one per page visit. So "re-read"
means on a later day. Reading pages 1–100 in the morning and going back to
10–30 the same evening shows no bar. Telling them apart would need the visits
in order within a day, and so the full page_stat_data rows.
