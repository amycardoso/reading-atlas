# Reading Atlas Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `atlas_map`, a drop-in micro-module for `bookshelf.koplugin` that draws the whole on-device library as territory — one grey cell per book, grouped by language, author, series or genre, shaded by reading status.

**Architecture:** `atlas/library.lua` reads bookshelf's cached groups (`Repo.getGroupFilepaths`) and per-book status (`Repo.readProgress`) behind `pcall`. `atlas/territory.lua` is pure logic — status → grey, ordering, counting, folding small territories into "Others", and the cell/label layout. The existing `source.lua` cache gains one slot per key, and `gridwidget.lua` learns blank cells and truncated labels. `atlas_map.lua` only composes.

**Tech Stack:** Lua 5.1 / LuaJIT, KOReader runtime (`ffi/blitbuffer`, `ui/uimanager`, `ui/widget/*`), bookshelf's module kit and book repository.

**Spec:** `docs/superpowers/specs/2026-09-23-reading-atlas-phase-2-design.md`

## Global Constraints

- **Module keys are frozen once released.** New key: `atlas_map`. Never touch `atlas_heatmap` or `atlas_clock`.
- **The host owns size.** Never write a font-fitting loop. Size every font through `Kit.sc(scale_pct)` / `Kit.face(size, scale_pct, opts)`.
- **Anything painted must be `require("ui/widget/widget"):extend{}` and built with `:new{}`** (see `docs/CARRY-FORWARD.md` — a bare table crashed a Kindle).
- **The library read runs once and off the paint thread**, behind the per-key guard in `source.lua` (bookshelf issue #194).
- **Three states, never conflated:** `nil` = not read yet (loading), `false` = bookshelf could not answer (Unavailable), `table` = data — and an empty library is a table, not `false`.
- **Status → grey step:** `finished`/`complete` → 4, `reading` → 2, `on_hold`/`abandoned` → 1, anything else → 0. Blank (no book) → `nil`, which paints nothing.
- **Only grey.** `Blitbuffer.Color8` luminance; no colour.
- **Never write** to bookshelf's repository, sidecars or the statistics database.
- **Helpers are never loaded with `require("lib/...")`** — that resolves into bookshelf's own `lib/`. Use the `atlas()` loader.
- **Write Lua 5.1-compatible code:** no `//`, no `goto`, no bitwise operators. KOReader runs LuaJIT.
- **Commit messages in English, with no AI attribution** — no `Co-Authored-By`, no session links.

## Prerequisites

`lua` on PATH (LuaJIT is installed on this machine). Before Task 1, confirm the baseline:

```bash
sh tests/run.sh
```

Expected: `ran 7 suites, 0 failed`.

## File Structure

Deployed layout under `<koreader settings>/bookshelf/micromodules/`; the repository mirrors it.

```
atlas_map.lua         <- NEW: scanned by bookshelf (spec table)
atlas/
  territory.lua       <- NEW, pure: status -> grey, counts, folding, layout
  library.lua         <- NEW: reads bookshelf's Repo (device-verified)
  source.lua          <- CHANGED: one three-state cache per key
  gridwidget.lua      <- CHANGED: nil = blank cell; truncate label mode
tests/
  _test_territory.lua   <- NEW
  _test_library.lua     <- NEW
  _test_map_module.lua  <- NEW: atlas_map.lua against stubs
  _test_gridwidget.lua  <- CHANGED
  _test_source.lua      <- CHANGED
tools/install.sh      <- CHANGED: copies atlas_map.lua
```

## Where the bookshelf facts come from

Checked against `bookshelf.koplugin` commit `cbce46e` (`lib/bookshelf_book_repository.lua`):

- `Repo.getGroupFilepaths(kind)` → `{ [display name] = { filepath, ... } }` for `kind` in `language`, `author`, `series`, `genre`. Keys are display names (languages already friendly, e.g. "English").
- A book with no author, genre or series is in **no** group. Only languages have an "Unknown" group. Series keeps standalones apart.
- `Repo.getAllFilepaths()` → every walked filepath.
- `Repo.readProgress(fp)` → `pct, status, ...`, with `complete` → `finished` and `abandoned` → `on_hold` already mapped. `nil`/`"new"` mean unread.
- bookshelf's `ngettext` always returns the singular, so plurals are chosen in code.

---

### Task 1: Blank cells and truncated labels in the grid widget

**Files:**
- Modify: `micromodules/atlas/gridwidget.lua` (whole file below)
- Test: `tests/_test_gridwidget.lua`

**Interfaces:**
- Produces:
  - `GW.labelHeight(face) -> px` — the strip height a labelled widget reserves.
  - `GW.new{ ..., label_mode = "truncate" }` — every label drawn, each with `max_width = label.width`.
  - `level(col, row)` returning `nil` → that cell is not painted. `0` still paints `GW.INK[0]`.
  - `col_labels` entries may carry `width` (px); only truncate mode reads it.

- [ ] **Step 1: Record `max_width` in the TextWidget stub**

In `tests/_test_gridwidget.lua`, replace the one-line stub

```lua
        o.paintTo = function(self, _bb, x) painted[#painted + 1] = { text = self.text, x = x } end
```

with

```lua
        o.paintTo = function(self, _bb, x)
            painted[#painted + 1] = { text = self.text, x = x, max_width = self.max_width }
        end
```

- [ ] **Step 2: Write the failing tests**

Replace the final `t.done()` of `tests/_test_gridwidget.lua` with:

```lua
-- Records every rect painted, so a test can see which cells were left blank.
local function paintedRects(w)
    local rects = {}
    w:paintTo({ paintRect = function(_, x, y, cw, ch, color)
        rects[#rects + 1] = { x = x, y = y, v = color.v }
    end }, 0, 0)
    return rects
end

t.test("level() returning nil leaves that cell unpainted", function()
    -- The territory map's blank separator columns depend on this: a blank
    -- must not paint as step 0, or it reads as an unread book.
    local w = GW.new{ width = 400, height = 200, cols = 3, rows = 1, grid = REAL_GRID,
                      level = function(col) if col == 2 then return nil end return 4 end }
    local rects = paintedRects(w)
    eq(#rects, 2, "only the two non-nil cells should paint")
    local step = w.geom.cell + w.geom.gap
    eq(rects[1].x, 0)
    eq(rects[2].x, 2 * step, "column 2 must be skipped, not shifted")
end)

t.test("level 0 still paints, as the lightest grey", function()
    local w = GW.new{ width = 400, height = 200, cols = 2, rows = 1, grid = REAL_GRID,
                      level = function() return 0 end }
    local rects = paintedRects(w)
    eq(#rects, 2, "step 0 is a real cell and must be painted")
    eq(rects[1].v, GW.INK[0])
end)

t.test("truncate mode draws every label, each capped at its own width", function()
    -- The same crowded strip that the default mode thins out: here nothing
    -- may be skipped, because a territory without a name is unreadable.
    local w = GW.new{ width = 120, height = 120, cols = 40, rows = 7,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      label_mode = "truncate",
                      col_labels = { { col = 1, text = "Portuguese", width = 20 },
                                     { col = 5, text = "English", width = 15 },
                                     { col = 9, text = "Spanish", width = 30 } } }
    local got = paintedLabels(w)
    eq(#got, 3, "truncate mode must never skip a label")
    eq(got[1].max_width, 20)
    eq(got[2].max_width, 15)
    eq(got[3].max_width, 30)
    local step = w.geom.cell + w.geom.gap
    eq(got[2].x, 4 * step, "a label sits at its own column")
end)

t.test("the default mode passes no max_width, so month labels are unchanged", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      col_labels = { { col = 1, text = "jan" } } }
    local got = paintedLabels(w)
    eq(#got, 1)
    eq(got[1].max_width, nil)
end)

t.test("GW.labelHeight(face) matches the strip a labelled widget reserves", function()
    -- atlas_map solves its layout against (budget - GW.labelHeight(face)); if
    -- this drifts from what init() takes off, the map's plan and the painted
    -- grid disagree about the cell size.
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      col_labels = { { col = 1, text = "jan" } } }
    eq(GW.labelHeight("FACE"), w:labelHeight())
end)

t.done()
```

- [ ] **Step 3: Run the suite to verify the new tests fail**

Run: `lua tests/_test_gridwidget.lua`
Expected: `PASS 15  FAIL 3` — failing are "level() returning nil leaves that cell unpainted", "truncate mode draws every label…", and "GW.labelHeight(face) matches…". The other two new tests are regression guards and pass already.

- [ ] **Step 4: Implement**

Replace `micromodules/atlas/gridwidget.lua` with:

```lua
-- A cols x rows grid of filled cells, painted straight into the blitbuffer.
--
-- Follows bookshelf's analogue_clock: a plain table with getSize() and
-- paintTo(bb, x, y). There is no polygon fill in KOReader, and none is
-- needed -- every cell is a rectangle.
--
-- The caller supplies level(col, row) -> 0..4 rather than a data table, so
-- this one widget paints the day heatmap, the hour x weekday clock and the
-- territory map. level() returning nil means "no cell here" and paints
-- nothing: the map needs blank columns between territories that must not read
-- as an unread book.
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")
-- MUST extend KOReader's Widget. A bare table with getSize/paintTo looks like
-- it works -- it paints -- but it carries none of the widget protocol, so the
-- first event a container propagates into it (a tap, a refresh, a close) calls
-- a nil handleEvent and the error escapes the UI loop, taking KOReader down to
-- the launcher. Found the hard way on a Kindle; no off-device test can see it,
-- because the suites stub these modules and only ever call getSize().
local Widget = require("ui/widget/widget")

local Grid = nil  -- injected below by the spec files' loader, or dofile'd

local M = {}

-- Luminance per step, light to dark. Five steps is the ceiling for what is
-- reliably distinguishable on e-ink at this cell size; step 0 is a light grey
-- rather than white so a day without reading still reads as a cell.
M.INK = { [0] = 0xE0, [1] = 0xB0, [2] = 0x80, [3] = 0x50, [4] = 0x20 }

-- `grid_mod` lets callers hand in the already-loaded Grid helper. Falls back
-- to a sibling dofile so this file also works standalone in tests.
function M.setGrid(grid_mod) Grid = grid_mod end

local function resolveGrid(opts)
    -- Per-instance resolution: opts.grid takes precedence, then module-level
    -- default (set by setGrid), then sibling dofile fallback.
    if opts.grid then return opts.grid end
    if Grid then return Grid end
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return dofile(dir .. "grid.lua")
end

local GridWidget = Widget:extend{}

-- Height of a label strip set in `face`. A module function as well as a
-- method, so a caller can take the strip out of its height budget BEFORE
-- building the widget -- the territory map has to solve its layout against
-- exactly the grid height the widget will end up with.
function M.labelHeight(face)
    local TextWidget = require("ui/widget/textwidget")
    local probe = TextWidget:new{ text = "M", face = face }
    local h = probe:getSize().h
    probe:free()
    return h + math.max(1, math.floor(h / 4))
end

-- Height the column-label strip occupies, 0 when there are no labels.
-- Deliberately independent of the grid geometry: the strip is measured BEFORE
-- the grid is solved, because it comes out of the same height budget and the
-- grid only gets what is left.
function GridWidget:labelHeight()
    if not (self.col_labels and self.face) then return 0 end
    if not self._label_h then self._label_h = M.labelHeight(self.face) end
    return self._label_h
end

function GridWidget:init()
    -- The label strip is part of what the caller budgeted for, so take it off
    -- the top before solving the grid. Getting this wrong pushes whatever the
    -- caller stacked below the grid off the bottom of the card.
    local label_h = self:labelHeight()
    local grid_h = self.height and math.max(1, self.height - label_h) or nil
    self.geom = self.gridMod.layout{
        width = self.width, height = grid_h,
        cols = self.cols, rows = self.rows,
        gap_ratio = self.gap_ratio,
    }
    self.dimen = Geom:new{ w = self.geom.w, h = self.geom.h + label_h }
end

function GridWidget:getSize()
    return Geom:new{ w = self.geom.w, h = self.geom.h + self:labelHeight() }
end

-- Column labels drawn at the x offset of the column they mark.
--
-- When they do not all fit, drop to a REGULAR subset -- every second label,
-- every third, and so on -- rather than skipping whichever individual ones
-- happen to collide. Irregular gaps read as a bug; "every other month" reads
-- as a choice.
function GridWidget:paintLabels(bb, x, y)
    local TextWidget = require("ui/widget/textwidget")
    local step = self.geom.cell + self.geom.gap
    local n = #self.col_labels

    local widths = {}
    for i = 1, n do
        local tw = TextWidget:new{ text = self.col_labels[i].text, face = self.face }
        widths[i] = tw:getSize().w
        tw:free()
    end
    local pad = math.max(2, math.floor(self:labelHeight() / 3))

    local function fits(stride)
        local prev_end = nil
        for i = 1, n, stride do
            local lx = (self.col_labels[i].col - 1) * step
            if lx + widths[i] > self.geom.w then return false end
            if prev_end and lx < prev_end then return false end
            prev_end = lx + widths[i] + pad
        end
        return true
    end

    local stride = 1
    while stride <= n and not fits(stride) do stride = stride + 1 end
    if stride > n then return end

    for i = 1, n, stride do
        local lb = self.col_labels[i]
        local tw = TextWidget:new{ text = lb.text, face = self.face,
            fgcolor = self.label_color }
        tw:paintTo(bb, x + (lb.col - 1) * step, y)
        tw:free()
    end
end

-- Truncate mode: every label is drawn, each cut with an ellipsis to the
-- `width` the caller gave it. For the territory map, where a skipped label
-- would leave a region with no name -- a missing month can be inferred from
-- its neighbours, a missing language cannot.
function GridWidget:paintTruncatedLabels(bb, x, y)
    local TextWidget = require("ui/widget/textwidget")
    local step = self.geom.cell + self.geom.gap
    for i = 1, #self.col_labels do
        local lb = self.col_labels[i]
        local tw = TextWidget:new{ text = lb.text, face = self.face,
            fgcolor = self.label_color, max_width = lb.width }
        tw:paintTo(bb, x + (lb.col - 1) * step, y)
        tw:free()
    end
end

function GridWidget:paintTo(bb, x, y)
    local g = self.geom
    local lh = self:labelHeight()
    self.dimen = Geom:new{ x = x, y = y, w = g.w, h = g.h + lh }
    if lh > 0 then
        if self.label_mode == "truncate" then
            self:paintTruncatedLabels(bb, x, y)
        else
            self:paintLabels(bb, x, y)
        end
    end
    y = y + lh
    local step = g.cell + g.gap
    for col = 1, self.cols do
        for row = 1, self.rows do
            local lv = self.level(col, row)
            if lv ~= nil then
                bb:paintRect(x + (col - 1) * step, y + (row - 1) * step,
                    g.cell, g.cell, Blitbuffer.Color8(M.INK[lv] or M.INK[0]))
            end
        end
    end
end

function M.new(opts)
    return GridWidget:new{
        cols     = opts.cols,
        rows     = opts.rows,
        level    = opts.level,
        width    = opts.width,
        height   = opts.height,
        gap_ratio = opts.gap_ratio,
        gridMod  = resolveGrid(opts),
        col_labels  = opts.col_labels,
        face        = opts.face,
        label_color = opts.label_color,
        label_mode  = opts.label_mode,
    }
end

return M
```

- [ ] **Step 5: Run the whole harness**

Run: `sh tests/run.sh`
Expected: `ran 7 suites, 0 failed`, with `_test_gridwidget.lua  PASS 18  FAIL 0`. The heatmap and clock never return `nil` from `level()` (the heatmap returns `0` outside the year), so they are unaffected.

- [ ] **Step 6: Commit**

```bash
git add micromodules/atlas/gridwidget.lua tests/_test_gridwidget.lua
git commit -m "feat: let the grid leave cells blank and truncate labels"
```

---

### Task 2: One three-state cache per key

**Files:**
- Modify: `micromodules/atlas/source.lua` (whole file below)
- Test: `tests/_test_source.lua`

**Interfaces:**
- Produces:
  - `Source.getKeyed(key, refresh, deps) -> nil | false | result` — `deps.query` (required), `deps.schedule` (default `UIManager:scheduleIn(0, fn)`), `deps.accept(result) -> bool` (default: non-empty array).
  - `Source.get(refresh, deps)` — unchanged behaviour; now `getKeyed("hours", ...)`.
  - `Source.reset()` — clears every key (tests only).

- [ ] **Step 1: Write the failing tests**

Replace the final `t.done()` of `tests/_test_source.lua` with:

```lua
t.test("separate keys keep separate caches", function()
    -- A map switched from languages to authors must query again, never be
    -- answered from the other axis's cache.
    Source.reset()
    local d = makeDeps(function() return { "languages" } end)
    Source.getKeyed("map:language", nil, d.deps)
    d.run()
    eq(Source.getKeyed("map:language", nil, d.deps)[1], "languages")

    local e = makeDeps(function() return { "authors" } end)
    eq(Source.getKeyed("map:author", nil, e.deps), nil,
        "a new key starts in the loading state")
    e.run()
    eq(Source.getKeyed("map:author", nil, e.deps)[1], "authors")
    eq(Source.getKeyed("map:language", nil, d.deps)[1], "languages",
        "the first key's cache is untouched")
end)

t.test("the hour rows and a keyed query do not share a guard", function()
    Source.reset()
    local d = makeDeps(function() return { { hour = 1, secs = 1 } } end)
    Source.get(nil, d.deps)
    Source.getKeyed("map:language", nil, d.deps)
    eq(d.pendingCount(), 2, "each key schedules its own query")
end)

t.test("accept decides what is usable: an empty table can be a real answer", function()
    -- The map distinguishes "the library is empty" (a table) from "bookshelf
    -- did not answer" (nil). Phase 1's non-empty rule would fold both into
    -- false, so the map passes its own accept.
    Source.reset()
    local d = makeDeps(function() return { territories = {}, unassigned = {} } end)
    d.deps.accept = function(r) return r ~= nil end
    Source.getKeyed("map:genre", nil, d.deps)
    d.run()
    local got = Source.getKeyed("map:genre", nil, d.deps)
    assert(type(got) == "table", "an empty library is data, not the false state")
end)

t.test("with a custom accept, nil still resolves to false", function()
    Source.reset()
    local d = makeDeps(function() return nil end)
    d.deps.accept = function(r) return r ~= nil end
    Source.getKeyed("map:series", nil, d.deps)
    d.run()
    eq(Source.getKeyed("map:series", nil, d.deps), false)
end)

t.done()
```

- [ ] **Step 2: Run to verify they fail**

Run: `lua tests/_test_source.lua`
Expected: 4 failures, each `attempt to call field 'getKeyed' (a nil value)`; the 8 existing tests pass.

- [ ] **Step 3: Implement**

Replace `micromodules/atlas/source.lua` with:

```lua
-- Three-state, query-once caches, one per key.
--
-- ── WHY ─────────────────────────────────────────────────────────────────────
-- Bookshelf's reading_streak carries the scar of issue #194: a synchronous
-- query against a large statistics database froze the menu as it opened. Two
-- rules follow, and both are asserted in tests/_test_source.lua:
--
--   1. The query never runs on the paint thread. render() schedules it and
--      returns whatever is known right now.
--   2. A guard collapses concurrent renders (the hero grid and the start menu
--      can both render the same module in one frame) into one query.
--
-- Three states per key, deliberately distinct:
--   nil   -> not queried yet; a fetch is scheduled. Render "Reading…".
--   false -> queried; nothing usable came back. Render an explanation.
--   table -> the result.
--
-- Keys keep unrelated queries apart: phase 1's hour rows live under "hours",
-- and each axis of the territory map under its own "map:<axis>", so switching
-- a map from languages to authors can never be answered from the wrong cache.
local M = {}

local _state = {}   -- key -> { cache = nil|false|table, querying = bool, pending = {} }

local function stateFor(key)
    local s = _state[key]
    if not s then
        s = { cache = nil, querying = false, pending = {} }
        _state[key] = s
    end
    return s
end

-- Phase 1's rule: an empty result is the no-statistics state.
local function nonEmpty(result) return result ~= nil and #result > 0 end

local function defaultSchedule(fn) require("ui/uimanager"):scheduleIn(0, fn) end

local function hourDeps()
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return {
        query = function() return dofile(dir .. "db.lua").hourRows() end,
    }
end

-- Tests only.
function M.reset()
    _state = {}
end

-- deps.query    -> the result, or nil. Runs once, off the paint thread.
-- deps.schedule -> defers a function; defaults to UIManager:scheduleIn(0, …).
-- deps.accept   -> whether a result is usable; defaults to "a non-empty
--                  array". Anything it rejects, and any error, caches false.
function M.getKeyed(key, refresh, deps)
    local s = stateFor(key)
    if s.cache ~= nil then return s.cache end
    -- Every caller's refresh must survive to the query landing, even callers
    -- that arrive while a query is already in flight (the hero grid and the
    -- start menu can both render the same module in one frame). Collecting
    -- into pending here, before the querying guard below, is what makes
    -- that true.
    if refresh then s.pending[#s.pending + 1] = refresh end
    if s.querying then return nil end
    s.querying = true
    local schedule = deps.schedule or defaultSchedule
    local accept = deps.accept or nonEmpty
    schedule(function()
        local ok, result = pcall(deps.query)
        -- Never leave the cache at nil here, or the module would re-query
        -- on every single render.
        if ok and accept(result) then
            s.cache = result
        else
            s.cache = false
        end
        s.querying = false
        local callbacks = s.pending
        s.pending = {}
        for i = 1, #callbacks do pcall(callbacks[i]) end
    end)
    return nil
end

-- Phase 1's hour rows. A raised error, a nil return and a zero-length result
-- all mean the same thing to a reader: there are no statistics to show.
function M.get(refresh, deps)
    return M.getKeyed("hours", refresh, deps or hourDeps())
end

return M
```

- [ ] **Step 4: Run the whole harness**

Run: `sh tests/run.sh`
Expected: `ran 7 suites, 0 failed`, `_test_source.lua  PASS 12  FAIL 0`.

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/source.lua tests/_test_source.lua
git commit -m "feat: keep one three-state cache per key in the source"
```

---

### Task 3: Status greys and territory counts

**Files:**
- Create: `micromodules/atlas/territory.lua`
- Test: `tests/_test_territory.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `T.level(status) -> 0 | 1 | 2 | 4`
  - `T.prepare(lib, axis, unassigned_name) -> { territories = { { name, levels } }, books, finished, count, excluded, no_values }` where `lib` is `library.territories()` output (Task 5): `{ territories = { { name, books = { { path, status } } } }, unassigned = { { path, status } } }`.

- [ ] **Step 1: Write the failing tests**

Create `tests/_test_territory.lua`. The helpers at the top (`plan`, `countCells`) are used by Task 4's tests.

```lua
-- The territory map's logic, off-device: the grey each status gets, what the
-- card counts, and where every cell and label lands. The painting itself is
-- gridwidget's and is only verifiable on a Kindle.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local T = dofile("micromodules/atlas/territory.lua")
local Grid = dofile("micromodules/atlas/grid.lua")

-- Every glyph is 6 px, like the TextWidget stub in _test_gridwidget.lua.
local function measure(text) return #text * 6 end
local MIN = "abc"         -- 18 px
local OTHERS = "Others"

local function books(n, status, prefix)
    local out = {}
    for i = 1, n do
        out[i] = { path = (prefix or "b") .. i, status = status }
    end
    return out
end

local function territory(name, n, status)
    return { name = name, levels = (function()
        local lv = {}
        for i = 1, n do lv[i] = T.level(status) end
        return lv
    end)() }
end

local function plan(territories, width, height)
    return T.plan{ territories = territories, width = width, height = height,
        measure = measure, min_label = MIN, others_label = OTHERS, grid = Grid }
end

local function countCells(p)
    local n = 0
    for _, col in pairs(p.cells) do
        for _ in pairs(col) do n = n + 1 end
    end
    return n
end

-- ── level ──────────────────────────────────────────────────────────────────

t.test("each bookshelf status gets its own grey", function()
    eq(T.level("finished"), 4)
    eq(T.level("reading"), 2)
    eq(T.level("on_hold"), 1)
    eq(T.level("unread"), 0)
end)

t.test("KOReader's raw vocabulary maps to the same greys", function()
    eq(T.level("complete"), 4, "complete is finished")
    eq(T.level("abandoned"), 1, "abandoned is on hold")
end)

t.test("nil, new and unknown statuses are unread, never darker", function()
    eq(T.level(nil), 0)
    eq(T.level("new"), 0)
    eq(T.level("something-bookshelf-adds-later"), 0)
end)

-- ── prepare ────────────────────────────────────────────────────────────────

t.test("territories run largest first, ties by name", function()
    local p = T.prepare({ territories = {
        { name = "Spanish", books = books(2, "reading", "s") },
        { name = "English", books = books(5, "reading", "e") },
        { name = "French", books = books(2, "reading", "f") },
    } }, "language", "Unknown")
    eq(p.territories[1].name, "English")
    eq(p.territories[2].name, "French", "a tie is broken by name")
    eq(p.territories[3].name, "Spanish")
end)

t.test("inside a territory the books run darkest first", function()
    local p = T.prepare({ territories = {
        { name = "English", books = {
            { path = "a", status = nil },
            { path = "b", status = "finished" },
            { path = "c", status = "on_hold" },
            { path = "d", status = "reading" },
        } },
    } }, "language", "Unknown")
    eq(p.territories[1].levels, { 4, 2, 1, 0 })
end)

t.test("a book in two territories is one book in the counts", function()
    local p = T.prepare({ territories = {
        { name = "Gaiman", books = { { path = "good-omens", status = "finished" } } },
        { name = "Pratchett", books = { { path = "good-omens", status = "finished" },
                                        { path = "mort", status = "reading" } } },
    } }, "author", "No author")
    eq(p.books, 2, "good-omens counts once")
    eq(p.finished, 1)
    eq(p.count, 2, "but it is drawn in both territories")
end)

t.test("unassigned books become their own territory on most axes", function()
    local p = T.prepare({
        territories = { { name = "Fantasy", books = books(1, "finished", "f") } },
        unassigned = books(3, nil, "u"),
    }, "genre", "No genre")
    eq(p.count, 2)
    eq(p.territories[1].name, "No genre", "the largest territory comes first")
    eq(p.books, 4)
    eq(p.excluded, 0)
    eq(p.no_values, false)
end)

t.test("on the series axis unassigned books are left out and counted", function()
    local p = T.prepare({
        territories = { { name = "Discworld", books = books(2, "finished", "d") } },
        unassigned = books(41, nil, "u"),
    }, "series", "ignored")
    eq(p.count, 1, "no 'no series' territory")
    eq(p.books, 2)
    eq(p.excluded, 41)
end)

t.test("books but no values on the axis is its own state", function()
    local p = T.prepare({ territories = {}, unassigned = books(5, nil) },
        "genre", "No genre")
    eq(p.no_values, true)
end)

t.test("an empty library is not the no-values state", function()
    local p = T.prepare({ territories = {}, unassigned = {} }, "genre", "No genre")
    eq(p.books, 0)
    eq(p.no_values, false)
end)

t.test("a territory with no books is dropped", function()
    local p = T.prepare({ territories = {
        { name = "Empty", books = {} },
        { name = "English", books = books(1, "reading") },
    } }, "language", "Unknown")
    eq(p.count, 1)
end)

t.done()
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua tests/_test_territory.lua`
Expected: error — `cannot open micromodules/atlas/territory.lua`.

- [ ] **Step 3: Implement**

Create `micromodules/atlas/territory.lua`:

```lua
-- The territory map's logic: which grey a book gets, which territories are
-- shown, and where every cell and label lands. Pure -- no KOReader, no I/O --
-- so all of it is asserted in tests/_test_territory.lua.
--
-- One book is one cell. Books fill columns top to bottom; each territory
-- starts on a fresh column, with one blank column between territories as the
-- border. Territories run largest first, and inside one the books run darkest
-- first, so every region reads "finished -> unread" left to right.
local M = {}

-- Status -> grey step. Both vocabularies are accepted: bookshelf's
-- Repo.readProgress already maps KOReader's "complete"/"abandoned" to
-- "finished"/"on_hold", but a future path handing over the raw value must not
-- turn a finished book into an unread one. Step 3 is left unused on purpose,
-- to open the contrast between "reading" and "finished".
local LEVEL = {
    finished = 4, complete = 4,
    reading = 2,
    on_hold = 1, abandoned = 1,
}

-- Anything else -- "unread", "new", nil, a value nobody has invented yet -- is
-- unread. Guessing darker would claim reading that did not happen.
function M.level(status)
    return LEVEL[status] or 0
end

local function darkestFirst(a, b) return a > b end

-- Turns library.territories() output into what the card draws and counts.
--
--   lib        = { territories = { { name, books = { { path, status } } } },
--                  unassigned  = { { path, status } } }
--   axis       = "language" | "author" | "series" | "genre"
--   unassigned_name = the territory name for books with no value on this
--                axis ("No genre", ...). Ignored for series, whose unassigned
--                books are left out and counted instead: "no series" would be
--                the largest territory in almost any library and swallow the
--                map.
--
-- Returns {
--   territories = { { name, levels = { 4, 4, 2, 0, ... } } }, largest first,
--   books       = distinct books on the map (a two-author book counts once),
--   finished    = distinct finished books on the map,
--   count       = territories on the map, before any folding into "Others",
--   excluded    = series only: books left out for having no series,
--   no_values   = true when books exist but none has a value on this axis,
-- }
function M.prepare(lib, axis, unassigned_name)
    local list = {}
    for _, t in ipairs(lib.territories or {}) do
        if t.books and #t.books > 0 then
            list[#list + 1] = { name = t.name, books = t.books }
        end
    end
    local real = #list

    local unassigned = lib.unassigned or {}
    local excluded = 0
    if #unassigned > 0 then
        if axis == "series" then
            excluded = #unassigned
        else
            list[#list + 1] = { name = unassigned_name, books = unassigned }
        end
    end

    local seen, books, finished = {}, 0, 0
    local out = {}
    for i, t in ipairs(list) do
        local levels = {}
        for j, b in ipairs(t.books) do
            local lv = M.level(b.status)
            levels[j] = lv
            if not seen[b.path] then
                seen[b.path] = true
                books = books + 1
                if lv == 4 then finished = finished + 1 end
            end
        end
        table.sort(levels, darkestFirst)
        out[i] = { name = t.name, levels = levels }
    end

    table.sort(out, function(a, b)
        if #a.levels ~= #b.levels then return #a.levels > #b.levels end
        return a.name < b.name
    end)

    return {
        territories = out,
        books = books,
        finished = finished,
        count = #out,
        excluded = excluded,
        no_values = real == 0 and (#unassigned > 0),
    }
end

return M
```

- [ ] **Step 4: Run the whole harness**

Run: `sh tests/run.sh`
Expected: `ran 8 suites, 0 failed`, `_test_territory.lua  PASS 11  FAIL 0`.

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/territory.lua tests/_test_territory.lua
git commit -m "feat: map reading status to greys and count territories"
```

---

### Task 4: The territory layout

**Files:**
- Modify: `micromodules/atlas/territory.lua` (insert before the final `return M`)
- Test: `tests/_test_territory.lua`

**Interfaces:**
- Consumes: `T.prepare(...).territories` (Task 3); `atlas/grid.lua`'s `layout{ width, height, cols, rows, gap_ratio } -> { cell, gap, w, h }`.
- Produces:
  - `T.plan{ territories, width, height, measure, min_label, others_label, grid, gap_ratio } -> { rows, cols, geom, cells, labels, shown }` — `cells[col][row] = level` (missing = blank), `labels = { { col, text, width } }` for gridwidget's truncate mode, `shown` = territories named.
  - `T._solve(o, keep, minw)` — tests only.

Rules the tests pin down: every book drawn exactly once; one blank column between territories; each named territory's columns hold at least `measure(min_label)` px; labels never reach the next territory; the grid never overflows its box; the most territories that can all be named are named (binary search, checked against brute force); for that count the largest cell that fits wins, ties to fewer rows.

- [ ] **Step 1: Write the failing tests**

Replace the final `t.done()` of `tests/_test_territory.lua` with:

```lua
-- ── plan ───────────────────────────────────────────────────────────────────

t.test("the row count giving the largest cell wins", function()
    -- Four books in 100x100. One row: 4 columns, cell 22. Two rows: 2x2,
    -- cell 45. Three rows: 2 columns, 3 rows, cell 29. Four rows: cell 22.
    local p = plan({ territory("English", 4, "reading") }, 100, 100)
    eq(p.rows, 2)
    eq(p.cols, 2)
    eq(p.geom.cell, 45)
end)

t.test("books fill each column top to bottom, darkest first", function()
    local p = plan({ { name = "English", levels = { 4, 2, 1, 0 } } }, 100, 100)
    eq(p.cells[1][1], 4)
    eq(p.cells[1][2], 2)
    eq(p.cells[2][1], 1)
    eq(p.cells[2][2], 0)
end)

t.test("a blank column separates two territories", function()
    local p = plan({ territory("English", 4, "finished"),
                     territory("French", 4, "reading") }, 400, 100)
    local span = math.ceil(4 / p.rows)
    eq(p.cells[span + 1], nil, "the border column must be blank")
    eq(p.cells[span + 2][1], 2, "the second territory starts after it")
    eq(p.labels[2].col, span + 2)
end)

t.test("the end of a territory's last column stays blank", function()
    -- Three books in two rows: the last column holds one book and one blank.
    local p = T.plan{ territories = { territory("English", 3, "finished") },
        width = 60, height = 60, measure = measure, min_label = MIN,
        others_label = OTHERS, grid = Grid }
    eq(p.rows, 2)
    eq(p.cells[2][1], 4)
    eq(p.cells[2][2], nil, "no book there, so no cell")
end)

t.test("every book is drawn exactly once", function()
    local ts = {}
    for i = 1, 12 do ts[i] = territory("T" .. i, 25 - i, "reading") end
    local total = 0
    for i = 1, 12 do total = total + (25 - i) end
    local p = plan(ts, 500, 120)
    eq(countCells(p), total)
end)

t.test("a territory too narrow to name is folded into Others", function()
    -- One big territory and thirty single books in a narrow card: the singles
    -- cannot each hold "abc", so most of them must fold.
    local ts = { territory("Big", 40, "finished") }
    for i = 1, 30 do ts[#ts + 1] = territory(("S%02d"):format(i), 1, "reading") end
    local p = plan(ts, 200, 60)
    assert(p.shown < #ts, "expected folding, showed all " .. p.shown)
    assert(p.shown >= 1, "the big territory must survive")
    eq(p.labels[1].text, "Big")
    eq(countCells(p), 70, "folded books are still drawn, inside Others")
end)

t.test("every territory shown keeps a label at least min_label wide", function()
    local minw = measure(MIN)
    for width = 80, 600, 7 do
        local ts = {}
        for i = 1, 20 do ts[i] = territory("T" .. i, 21 - i, "reading") end
        local p = plan(ts, width, 90)
        local named = 0
        for _, lb in ipairs(p.labels) do
            if lb.text ~= OTHERS then
                named = named + 1
                assert(lb.width >= minw, ("width %d: label %s has %d px"):format(
                    width, lb.text, lb.width))
            end
        end
        eq(named, p.shown, "width " .. width .. ": every shown territory is named")
    end
end)

t.test("labels never run into the next territory", function()
    for width = 80, 600, 7 do
        local ts = {}
        for i = 1, 20 do ts[i] = territory("T" .. i, 21 - i, "reading") end
        local p = plan(ts, width, 90)
        local step = p.geom.cell + p.geom.gap
        for i = 2, #p.labels do
            local prev = p.labels[i - 1]
            local prev_end = (prev.col - 1) * step + prev.width
            local this_x = (p.labels[i].col - 1) * step
            assert(prev_end < this_x, ("width %d: label %d ends at %d, next starts at %d")
                :format(width, i - 1, prev_end, this_x))
        end
    end
end)

t.test("the grid never overflows its box across a realistic range", function()
    for width = 100, 700, 13 do
        for _, height in ipairs({ 40, 90, 160 }) do
            local ts = {}
            for i = 1, 8 do ts[i] = territory("T" .. i, 40 - 4 * i, "reading") end
            local p = plan(ts, width, height)
            assert(p.geom.w <= width, ("%dx%d: width %d"):format(width, height, p.geom.w))
            assert(p.geom.h <= height, ("%dx%d: height %d"):format(width, height, p.geom.h))
        end
    end
end)

t.test("no cell lands outside the planned columns and rows", function()
    local ts = {}
    for i = 1, 6 do ts[i] = territory("T" .. i, 7 * i, "reading") end
    local p = plan(ts, 300, 80)
    for col, rows in pairs(p.cells) do
        assert(col >= 1 and col <= p.cols, "column " .. col .. " out of range")
        for row in pairs(rows) do
            assert(row >= 1 and row <= p.rows, "row " .. row .. " out of range")
        end
    end
end)

t.test("a single territory in a card too small to name it still draws", function()
    local p = plan({ territory("Portuguese", 10, "finished") }, 10, 10)
    eq(countCells(p), 10, "every book still has a cell")
end)

t.test("three hundred books in sixty small territories still all draw, inside the box", function()
    -- No territory here is wide enough to name in 260 px, so the honest
    -- answer is one "Others" block -- but every book must still have a cell.
    local ts, total = {}, 0
    for i = 1, 60 do
        ts[i] = territory("A" .. i, (i % 9) + 1, "reading")
        total = total + (i % 9) + 1
    end
    local p = plan(ts, 260, 70)
    eq(countCells(p), total)
    assert(p.geom.w <= 260 and p.geom.h <= 70, "the grid must stay inside the card")
end)

t.test("the search names as many territories as brute force would", function()
    -- plan() binary-searches the number of named territories, which assumes
    -- that folding one more territory never makes naming the rest harder.
    -- Check that assumption against trying every count, on random libraries.
    local minw = measure(MIN)
    math.randomseed(7)
    for _ = 1, 300 do
        local ts = {}
        for i = 1, math.random(1, 40) do
            local lv = {}
            for j = 1, math.random(1, 30) do lv[j] = math.random(0, 4) end
            ts[i] = { name = "T" .. i, levels = lv }
        end
        table.sort(ts, function(a, b) return #a.levels > #b.levels end)
        local o = { territories = ts, width = math.random(80, 700),
            height = math.random(30, 200), measure = measure, min_label = MIN,
            others_label = OTHERS, grid = Grid }
        local brute = 0
        for keep = 0, #ts do
            if T._solve(o, keep, minw) then brute = keep end
        end
        eq(T.plan(o).shown, brute, ("%d territories in %dx%d"):format(#ts, o.width, o.height))
    end
end)

t.done()
```

- [ ] **Step 2: Run to verify they fail**

Run: `lua tests/_test_territory.lua`
Expected: the 13 new tests fail with `attempt to call field 'plan' (a nil value)` (or `'_solve'`); the 11 from Task 3 pass.

- [ ] **Step 3: Implement**

Insert into `micromodules/atlas/territory.lua`, immediately before the final `return M`:

```lua
-- The territories kept on the map, plus an "Others" block holding the rest.
local function blocksFor(territories, keep, others_label)
    local blocks = {}
    for i = 1, keep do
        blocks[i] = { text = territories[i].name, levels = territories[i].levels }
    end
    if keep < #territories then
        local rest = {}
        for i = keep + 1, #territories do
            for _, lv in ipairs(territories[i].levels) do rest[#rest + 1] = lv end
        end
        table.sort(rest, darkestFirst)
        blocks[#blocks + 1] = { text = others_label, levels = rest, others = true }
    end
    return blocks
end

-- Room a block's label has: its own columns and nothing more. The blank
-- border column is what keeps two labels from touching.
local function labelRoom(span, geom)
    return span * (geom.cell + geom.gap) - geom.gap
end

-- A layout that fits its box beats one that does not -- at a 1 px cell,
-- grid.layout can overflow, and a row count that stays inside the box must
-- win over one that spills. Then the larger cell. Ties keep the earlier, which
-- is the one with fewer rows.
local function better(fits, geom, best)
    if not best then return true end
    if fits ~= best.fits then return fits end
    return geom.cell > best.geom.cell
end

-- Lays the map out.
--
--   territories  = prepare(...).territories
--   width/height = the box for the GRID alone -- the label strip already
--                  taken out (gridwidget.labelHeight)
--   measure      = function(text) -> px width in the label face
--   min_label    = the shortest label worth drawing, e.g. "Mmm…"
--   others_label = "Others"
--   grid         = atlas/grid.lua (injected: tests hand in the real one)
--   gap_ratio    = passed through to grid.layout
--
-- How many territories are shown comes from the space, not a fixed N: a
-- territory stays only if its columns can hold min_label. The smallest
-- territories are folded into "Others" until every one left can be named. For that count, the row count
-- giving the largest cell that fits the box wins; ties go to fewer rows.
--
-- Returns {
--   rows, cols, geom,        -- geom is grid.layout's result for rows x cols
--   cells  = { [col] = { [row] = level } }   -- a missing entry is blank
--   labels = { { col, text, width } },       -- for gridwidget truncate mode
--   shown  = territories drawn under their own name,
-- }
-- The best layout that names the first `keep` territories, or nil when no
-- row count gives each of them room for min_label.
local function solve(o, keep, minw)
    local blocks = blocksFor(o.territories, keep, o.others_label)
    local biggest = 0
    for _, b in ipairs(blocks) do
        if #b.levels > biggest then biggest = #b.levels end
    end

    local best
    for rows = 1, math.max(1, biggest) do
        -- A cell under 2 px cannot show separated cells at all; once the
        -- height alone rules that out, more rows can only be worse.
        if rows > 1 and rows * 2 > o.height then break end
        local spans, cols = {}, -1
        for i, b in ipairs(blocks) do
            spans[i] = math.ceil(#b.levels / rows)
            cols = cols + spans[i] + 1
        end
        if cols < 1 then cols = 1 end
        local geom = o.grid.layout{ width = o.width, height = o.height,
            cols = cols, rows = rows, gap_ratio = o.gap_ratio }
        local named = true
        for i, b in ipairs(blocks) do
            if not b.others and labelRoom(spans[i], geom) < minw then
                named = false
                break
            end
        end
        -- An overflowing layout has room for labels only because it runs off
        -- the card, so it can never be what names a territory. It is accepted
        -- only as the last resort, with everything in "Others".
        local fits = geom.w <= o.width and geom.h <= o.height
        if named and (fits or keep == 0) and better(fits, geom, best) then
            best = { rows = rows, cols = cols, spans = spans, geom = geom,
                     fits = fits }
        end
    end
    if best then best.blocks = blocks end
    return best
end

-- Tests only: lets the suite check the binary search against brute force.
M._solve = solve

function M.plan(o)
    local minw = o.measure(o.min_label)

    -- Each named territory needs at least minw of its own, so no more than
    -- width / minw can ever be named.
    local most = math.floor(o.width / math.max(1, minw))
    if most > #o.territories then most = #o.territories end
    if most < 0 then most = 0 end

    -- Binary search for the most territories that can all be named. keep = 0
    -- always solves, since "Others" never has to be named. The planner runs
    -- on the paint path on an e-reader CPU, and a linear walk down from
    -- `most` costs a full row search per step -- tens of steps on a library
    -- with hundreds of authors.
    local lo, hi = 0, most
    local found = solve(o, 0, minw)
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        local attempt = solve(o, mid, minw)
        if attempt then
            lo, found = mid, attempt
        else
            hi = mid - 1
        end
    end

    local cells, labels = {}, {}
    local col = 1
    for i, b in ipairs(found.blocks) do
        local room = labelRoom(found.spans[i], found.geom)
        -- "Others" is named only when it has the room; the named territories
        -- always have it, by construction in solve().
        if room >= minw then
            labels[#labels + 1] = { col = col, text = b.text, width = room }
        end
        for k, lv in ipairs(b.levels) do
            local c = col + math.floor((k - 1) / found.rows)
            local r = (k - 1) % found.rows + 1
            cells[c] = cells[c] or {}
            cells[c][r] = lv
        end
        col = col + found.spans[i] + 1
    end
    return {
        rows = found.rows, cols = found.cols, geom = found.geom,
        cells = cells, labels = labels, shown = lo,
    }
end
```

- [ ] **Step 4: Run the whole harness**

Run: `sh tests/run.sh`
Expected: `ran 8 suites, 0 failed`, `_test_territory.lua  PASS 24  FAIL 0`.

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/territory.lua tests/_test_territory.lua
git commit -m "feat: lay territories out and fold the unnamed into Others"
```

---

### Task 5: Reading the library through bookshelf

**Files:**
- Create: `micromodules/atlas/library.lua`
- Test: `tests/_test_library.lua`

**Interfaces:**
- Consumes: bookshelf's `lib/bookshelf_book_repository` (`getGroupFilepaths`, `readProgress`, optional `getAllFilepaths`).
- Produces: `Library.territories(axis, repo?) -> { territories = { { name, books = { { path, status } } } }, unassigned = { { path, status } } } | nil`. `repo` is for tests.

- [ ] **Step 1: Write the failing tests**

Create `tests/_test_library.lua`:

```lua
-- The only layer that talks to bookshelf. What is testable off-device is how
-- it fails: bookshelf's group API is public but undocumented, so every way it
-- can be missing or broken must end in nil (the "Unavailable" card) or in one
-- unread book -- never in an error that escapes into KOReader's UI loop.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Library = dofile("micromodules/atlas/library.lua")

local function fakeRepo(o)
    o = o or {}
    return {
        getGroupFilepaths = o.getGroupFilepaths or function(kind)
            if kind == "language" then
                return { English = { "/b/a.epub", "/b/b.epub" }, Portuguese = { "/b/c.epub" } }
            end
            return {}
        end,
        readProgress = o.readProgress or function(path)
            if path == "/b/a.epub" then return 1.0, "finished" end
            return nil, nil
        end,
        getAllFilepaths = o.getAllFilepaths,
    }
end

local function byName(result)
    local out = {}
    for _, tr in ipairs(result.territories) do out[tr.name] = tr end
    return out
end

t.test("groups become territories, each book with its status", function()
    local got = byName(Library.territories("language", fakeRepo()))
    eq(#got.English.books, 2)
    eq(got.English.books[1], { path = "/b/a.epub", status = "finished" })
    eq(#got.Portuguese.books, 1)
end)

t.test("an axis bookshelf does not group by is refused", function()
    eq(Library.territories("format", fakeRepo()), nil)
    eq(Library.territories(nil, fakeRepo()), nil)
end)

t.test("a repository without the group API is unavailable, not an error", function()
    local repo = fakeRepo()
    repo.getGroupFilepaths = nil
    eq(Library.territories("language", repo), nil)
end)

t.test("a repository without readProgress is unavailable", function()
    local repo = fakeRepo()
    repo.readProgress = nil
    eq(Library.territories("language", repo), nil)
end)

t.test("a group API that raises is unavailable", function()
    local repo = fakeRepo{ getGroupFilepaths = function() error("renamed upstream") end }
    eq(Library.territories("language", repo), nil)
end)

t.test("a group API that returns garbage is unavailable", function()
    local repo = fakeRepo{ getGroupFilepaths = function() return "nope" end }
    eq(Library.territories("language", repo), nil)
end)

t.test("one unreadable sidecar makes that book unread, not the map empty", function()
    local repo = fakeRepo{ readProgress = function(path)
        if path == "/b/b.epub" then error("corrupt sdr") end
        return 1.0, "finished"
    end }
    local got = byName(Library.territories("language", repo))
    eq(got.English.books[1].status, "finished")
    eq(got.English.books[2].status, nil, "the broken one is unread")
    eq(got.Portuguese.books[1].status, "finished", "the rest are intact")
end)

t.test("books in no group come back as unassigned", function()
    local repo = fakeRepo{
        getGroupFilepaths = function() return { Discworld = { "/b/a.epub" } } end,
        getAllFilepaths = function() return { "/b/a.epub", "/b/x.epub", "/b/y.epub" } end,
    }
    local got = Library.territories("series", repo)
    eq(#got.unassigned, 2)
    eq(got.unassigned[1].path, "/b/x.epub")
end)

t.test("without getAllFilepaths there are simply no unassigned books", function()
    local got = Library.territories("language", fakeRepo())
    eq(got.unassigned, {})
end)

t.test("a getAllFilepaths that raises leaves the groups intact", function()
    local repo = fakeRepo{ getAllFilepaths = function() error("walk failed") end }
    local got = Library.territories("language", repo)
    eq(#got.territories, 2)
    eq(got.unassigned, {})
end)

t.test("an empty library is an answer, not unavailable", function()
    local repo = fakeRepo{ getGroupFilepaths = function() return {} end,
                           getAllFilepaths = function() return {} end }
    eq(Library.territories("genre", repo), { territories = {}, unassigned = {} })
end)

t.test("a missing bookshelf module is unavailable", function()
    -- No repo passed and none on package.path: require fails inside pcall.
    package.loaded["lib/bookshelf_book_repository"] = nil
    eq(Library.territories("language"), nil)
end)

t.done()
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua tests/_test_library.lua`
Expected: error — `cannot open micromodules/atlas/library.lua`.

- [ ] **Step 3: Implement**

Create `micromodules/atlas/library.lua`:

```lua
-- The territory map's one read of the library, through bookshelf's own book
-- repository. Never writes.
--
-- ── WHY bookshelf AND NOT statistics.sqlite3 ────────────────────────────────
-- The statistics database only knows books that were opened, and a real one
-- can hold ten. Bookshelf already walks the whole library for its Series /
-- Authors / Languages / Genres tabs, with the grouping normalised (one
-- language key for "pt-BR" and "por", one author for "Assis, Machado de" and
-- "Machado de Assis"). Repo.getGroupFilepaths reads those cached groups
-- without hydrating records or decoding covers.
--
-- The price: getGroupFilepaths is public but not part of bookshelf's
-- documented micro-module API. Every call is pcall'd, and anything missing or
-- raising returns nil -- the card's "Unavailable" state, never a crash.
local M = {}

local AXES = { language = true, author = true, series = true, genre = true }

local function loadRepo()
    local ok, repo = pcall(require, "lib/bookshelf_book_repository")
    if ok and type(repo) == "table" then return repo end
    return nil
end

-- A book whose sidecar cannot be read is unread, not a failed query: one
-- corrupt .sdr must not blank the whole map.
local function statusOf(repo, path)
    local ok, _pct, status = pcall(repo.readProgress, path)
    if ok then return status end
    return nil
end

-- Returns
--   { territories = { { name, books = { { path, status } } } },
--     unassigned  = { { path, status } } }
-- or nil when bookshelf cannot answer.
--
-- `unassigned` holds books in no group at all. Bookshelf leaves a book with
-- no author, genre or series out of every group -- only languages get an
-- "Unknown" group -- so they are found by comparing the groups against the
-- whole walked library. Without Repo.getAllFilepaths it is simply empty.
--
-- `repo` is for tests; inside KOReader it is bookshelf's module.
function M.territories(axis, repo)
    if not AXES[axis] then return nil end
    repo = repo or loadRepo()
    if not repo then return nil end
    if type(repo.getGroupFilepaths) ~= "function"
        or type(repo.readProgress) ~= "function" then
        return nil
    end

    local ok, groups = pcall(repo.getGroupFilepaths, axis)
    if not ok or type(groups) ~= "table" then return nil end

    -- Plain Lua strings and numbers all the way down: nothing here holds a
    -- pointer into anything that could be freed under it.
    local territories, grouped = {}, {}
    for name, paths in pairs(groups) do
        if type(name) == "string" and name ~= "" and type(paths) == "table" then
            local books = {}
            for _, path in ipairs(paths) do
                if type(path) == "string" then
                    books[#books + 1] = { path = path, status = statusOf(repo, path) }
                    grouped[path] = true
                end
            end
            territories[#territories + 1] = { name = name, books = books }
        end
    end

    local unassigned = {}
    if type(repo.getAllFilepaths) == "function" then
        local ok_all, all = pcall(repo.getAllFilepaths)
        if ok_all and type(all) == "table" then
            for _, path in ipairs(all) do
                if type(path) == "string" and not grouped[path] then
                    grouped[path] = true
                    unassigned[#unassigned + 1] = { path = path, status = statusOf(repo, path) }
                end
            end
        end
    end

    return { territories = territories, unassigned = unassigned }
end

return M
```

- [ ] **Step 4: Run the whole harness**

Run: `sh tests/run.sh`
Expected: `ran 9 suites, 0 failed`, `_test_library.lua  PASS 12  FAIL 0`.

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/library.lua tests/_test_library.lua
git commit -m "feat: read the library's groups through bookshelf's repository"
```

---

### Task 6: The `atlas_map` module and its install

**Files:**
- Create: `micromodules/atlas_map.lua`
- Test: `tests/_test_map_module.lua`
- Modify: `tools/install.sh`

**Interfaces:**
- Consumes: `Source.getKeyed` (Task 2), `T.prepare` / `T.plan` (Tasks 3–4), `Library.territories` (Task 5), `GW.new` / `GW.labelHeight` with `label_mode = "truncate"` (Task 1), bookshelf's `Kit.valueCard`, `Kit.face`, `Kit.sc`, `Kit.radioRow`, `Kit.settingsReopen`, `ctx.config:get/set`.
- Produces: the module spec `{ key = "atlas_map", title, summary, render, show_settings }`; per-instance config field `axis` ∈ `language | author | series | genre`, default `language`.

- [ ] **Step 1: Write the failing tests**

Create `tests/_test_map_module.lua`:

```lua
-- atlas_map.lua is composition -- states, the heading and context line, the
-- settings dialog -- over helpers tested on their own. It runs here against
-- stubs of bookshelf's Kit and KOReader's widgets, which catches what the
-- other suites cannot: a typo, a nil, a state wired to the wrong card. The
-- painting and the real host are verified on the device.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

-- ── stubs ──────────────────────────────────────────────────────────────────
local function ctor(extra)
    return { new = function(_, o)
        o = o or {}
        if extra then extra(o) end
        return o
    end }
end
package.loaded["ui/geometry"] = { new = function(_, o) return o end }
package.loaded["ffi/blitbuffer"] = { Color8 = function(v) return { v = v } end }
local WidgetStub = {}
function WidgetStub:extend(sub) return setmetatable(sub or {}, { __index = self }) end
function WidgetStub:new(o)
    o = setmetatable(o or {}, { __index = self })
    if o.init then o:init() end
    return o
end
function WidgetStub:handleEvent() return false end
package.loaded["ui/widget/widget"] = WidgetStub
package.loaded["ui/widget/textwidget"] = ctor(function(o)
    o.getSize = function(self) return { w = #(self.text or "") * 6, h = 10 } end
    o.free = function() end
end)
package.loaded["ui/widget/verticalgroup"] = ctor()
package.loaded["ui/widget/verticalspan"] = ctor()

local scheduled = {}
local shown_dialog
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, _secs, fn) scheduled[#scheduled + 1] = fn end,
    show = function(_, d) shown_dialog = d end,
    close = function() end,
}
package.loaded["ui/widget/buttondialog"] = ctor()

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_module_kit"] = {
    COLOR_MUTED = "muted",
    sc = function() return function(n) return n end end,
    face = function() return "FACE", false end,
    valueCard = function(o) return { card = true, heading = o.heading, value = o.value, sub = o.sub } end,
    radioRow = function(o) return { text = (o.active and "* " or "  ") .. o.label, pick = o.on_pick } end,
    settingsReopen = function() end,
}

-- The library is faked through the loader's memo: atlas("library") returns
-- whatever sits in package.loaded["atlas/library"].
local library_answer, library_axis
package.loaded["atlas/library"] = {
    territories = function(axis)
        library_axis = axis
        return library_answer
    end,
}

-- Pre-seeded under the loader's key, so the module and this suite share one
-- instance and a test can reset it.
local Source = dofile("micromodules/atlas/source.lua")
package.loaded["atlas/source"] = Source

local Map = dofile("micromodules/atlas_map.lua")

local function runScheduled()
    local q = scheduled
    scheduled = {}
    for i = 1, #q do q[i]() end
end

local function config(values)
    values = values or {}
    return {
        get = function(_, k, default) if values[k] == nil then return default end return values[k] end,
        set = function(_, k, v) values[k] = v end,
        values = values,
    }
end

-- Renders once to kick off the query, lets it land, renders again.
local function settle(ctx)
    Source.reset()
    scheduled = {}
    Map.render(ctx)
    runScheduled()
    return Map.render(ctx)
end

local function ctx(extra)
    local c = { width = 400, height = 160, scale = 100, refresh = function() end,
                config = config() }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function lib(territories, unassigned)
    return { territories = territories, unassigned = unassigned or {} }
end

local function book(path, status) return { path = path, status = status } end

-- ── tests ──────────────────────────────────────────────────────────────────

t.test("the module declares a frozen key, a summary and settings", function()
    eq(Map.key, "atlas_map")
    assert(type(Map.summary) == "string" and #Map.summary > 0)
    assert(type(Map.render) == "function")
    assert(type(Map.show_settings) == "function")
end)

t.test("the first render is the loading card and queries off the paint path", function()
    Source.reset()
    scheduled = {}
    library_axis = nil
    local card = Map.render(ctx())
    eq(card.value, "Reading…")
    eq(library_axis, nil, "the library must not be read inside render")
    eq(#scheduled, 1)
end)

t.test("a bookshelf that cannot answer is the Unavailable card", function()
    library_answer = nil
    local card = settle(ctx())
    eq(card.value, "Unavailable")
end)

t.test("an empty library is the No books card", function()
    library_answer = lib({}, {})
    eq(settle(ctx()).value, "No books")
end)

t.test("books with no genre at all get the axis's own empty card", function()
    library_answer = lib({}, { book("/a", nil) })
    local card = settle(ctx{ config = config{ axis = "genre" } })
    eq(card.value, "No genres")
    eq(card.heading, "Atlas map · Genres")
end)

t.test("with data, the card is heading, grid and context line", function()
    library_answer = lib({
        { name = "English", books = { book("/a", "finished"), book("/b", "reading") } },
        { name = "Portuguese", books = { book("/c", nil) } },
    })
    local card = settle(ctx())
    eq(card.card, nil, "must not be a valueCard")
    eq(card[1].text, "Atlas map · Languages")
    eq(card[5].text, "3 books · 1 finished · 2 languages")
    local grid = card[3]
    assert(grid.level, "the middle child should be the grid widget")
    eq(grid.label_mode, "truncate")
    eq(grid.level(1, 1), 4, "English's finished book comes first")
end)

t.test("the series axis says how many books were left out", function()
    library_answer = lib({ { name = "Discworld", books = { book("/a", "finished") } } },
        { book("/x"), book("/y") })
    local card = settle(ctx{ config = config{ axis = "series" } })
    eq(card[5].text, "1 book · 1 finished · 1 series · 2 not in a series")
end)

t.test("counts of one are singular", function()
    library_answer = lib({ { name = "English", books = { book("/a", "reading") } } })
    eq(settle(ctx())[5].text, "1 book · 0 finished · 1 language")
end)

t.test("an unknown stored axis falls back to languages", function()
    library_answer = lib({}, {})
    settle(ctx{ config = config{ axis = "planets" } })
    eq(library_axis, "language")
end)

t.test("the Add picker has no config and still renders", function()
    library_answer = lib({ { name = "English", books = { book("/a", "reading") } } })
    local c = ctx()
    c.config = nil
    local card = settle(c)
    eq(card[1].text, "Atlas map · Languages")
end)

t.test("each axis has its own cache", function()
    library_answer = lib({ { name = "English", books = { book("/a", "reading") } } })
    settle(ctx())
    scheduled = {}
    local card = Map.render(ctx{ config = config{ axis = "author" } })
    eq(card.value, "Reading…", "switching axis must query again")
end)

t.test("settings list the four axes and a pick stores the axis", function()
    shown_dialog = nil
    local c = ctx()
    Map.show_settings(c)
    assert(shown_dialog, "a dialog should be shown")
    eq(#shown_dialog.buttons, 4)
    eq(shown_dialog.buttons[1][1].text, "* Languages", "the current axis is checked")
    shown_dialog.buttons[3][1].pick()
    eq(c.config.values.axis, "series")
end)

t.test("settings without a config do nothing rather than raise", function()
    local c = ctx()
    c.config = nil
    Map.show_settings(c)
end)

t.done()
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua tests/_test_map_module.lua`
Expected: error — `cannot open micromodules/atlas_map.lua`.

- [ ] **Step 3: Implement**

Create `micromodules/atlas_map.lua`:

```lua
-- Reading Atlas: the library as territory. One cell per book, grouped by
-- language, author, series or genre; the grey is how far the book was read.
--
-- The axis is per-instance config (long-press > Module settings), so the card
-- can be added twice -- languages in one, authors in the other.
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

-- Settings-dialog order.
local AXES = { "language", "author", "series", "genre" }
local DEFAULT_AXIS = "language"

local AXIS = {
    language = {
        title = _("Languages"), one = _("language"), noun = _("languages"), unassigned = _("Unknown"),
        none = _("No languages"), none_sub = _("None of your books declare a language."),
    },
    author = {
        title = _("Authors"), one = _("author"), noun = _("authors"), unassigned = _("No author"),
        none = _("No authors"), none_sub = _("None of your books name an author."),
    },
    series = {
        title = _("Series"), one = _("series"), noun = _("series"), unassigned = _("No series"),
        none = _("No series"), none_sub = _("None of your books belong to a series."),
    },
    genre = {
        title = _("Genres"), one = _("genre"), noun = _("genres"), unassigned = _("No genre"),
        none = _("No genres"), none_sub = _("None of your books carry a genre tag."),
    },
}

-- The shortest label worth drawing: three letters and an ellipsis. "M" is
-- about the widest letter, so this errs on the side of folding a territory
-- rather than naming it with a single character.
local MIN_LABEL = "Mmm…"

-- ctx.config is absent in the Add picker, and a hand-edited or future value
-- must not reach AXIS[] as a nil.
local function axisOf(ctx)
    local axis = ctx and ctx.config and ctx.config:get("axis", DEFAULT_AXIS)
    if not AXIS[axis] then axis = DEFAULT_AXIS end
    return axis
end

local function fetch(axis, refresh)
    return atlas("source").getKeyed("map:" .. axis, refresh, {
        query = function() return atlas("library").territories(axis) end,
        -- An empty library is data ({}), not "bookshelf did not answer" (nil).
        accept = function(result) return result ~= nil end,
    })
end

-- The plan is the expensive part, and the host renders the same card several
-- times at different scales. Keyed on everything plan() reads; the prepared
-- table is a stable identity for as long as its source cache lives.
local _plan_memo = setmetatable({}, { __mode = "k" })

local function planFor(prep, width, height, face, measure)
    local per = _plan_memo[prep]
    if not per then
        per = {}
        _plan_memo[prep] = per
    end
    local key = width .. "x" .. height .. ":" .. tostring(face)
    if not per[key] then
        per[key] = atlas("territory").plan{
            territories = prep.territories, width = width, height = height,
            measure = measure, min_label = MIN_LABEL, others_label = _("Others"),
            grid = atlas("grid"),
        }
    end
    return per[key]
end

local _prep_memo = setmetatable({}, { __mode = "k" })

local function prepared(lib, axis)
    local prep = _prep_memo[lib]
    if not prep then
        prep = atlas("territory").prepare(lib, axis, AXIS[axis].unassigned)
        _prep_memo[lib] = prep
    end
    return prep
end

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local axis = axisOf(ctx)
    local A = AXIS[axis]
    local heading_text = _("Atlas map") .. " · " .. A.title

    local lib = fetch(axis, refresh)
    if lib == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = _("Reading…") }
    end
    if lib == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = _("Unavailable"),
            sub = _("This bookshelf version does not share its library. Update bookshelf.") }
    end

    local prep = prepared(lib, axis)
    if prep.no_values then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = A.none, sub = A.none_sub }
    end
    if prep.books == 0 then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = heading_text, value = _("No books"),
            sub = _("No books found in KOReader's home folder.") }
    end

    local TextWidget    = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan  = require("ui/widget/verticalspan")
    local sc = Kit.sc(scale_pct)
    local hface, hbold = Kit.face(15, scale_pct, { bold = true })
    local sface = Kit.face(12, scale_pct)

    -- bookshelf's ngettext always answers the singular, so plurals are
    -- chosen here.
    local context = string.format("%d %s · %d %s · %d %s",
        prep.books, prep.books == 1 and _("book") or _("books"),
        prep.finished, _("finished"),
        prep.count, prep.count == 1 and A.one or A.noun)
    if prep.excluded > 0 then
        context = context .. string.format(" · %d %s", prep.excluded, _("not in a series"))
    end

    local heading = TextWidget:new{ text = heading_text, face = hface,
        bold = hbold, fgcolor = Kit.COLOR_MUTED, max_width = width }
    local sub = TextWidget:new{ text = context, face = sface,
        fgcolor = Kit.COLOR_MUTED, max_width = width }

    local chrome = heading:getSize().h + sub:getSize().h + sc(6)
    local avail = ctx.height and math.max(sc(20), ctx.height - chrome)
        or math.floor(width / 3)

    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))
    -- The plan must be solved against exactly the grid height the widget
    -- will end up with, or the two disagree about the cell size and the
    -- labels land on the wrong columns.
    local grid_h = math.max(1, avail - GW.labelHeight(sface))
    local function measure(text)
        local tw = TextWidget:new{ text = text, face = sface }
        local w = tw:getSize().w
        tw:free()
        return w
    end
    local plan = planFor(prep, width, grid_h, sface, measure)

    local grid = GW.new{
        width = width, height = avail, cols = plan.cols, rows = plan.rows,
        col_labels = plan.labels, label_mode = "truncate",
        face = sface, label_color = Kit.COLOR_MUTED,
        -- nil is a blank: the border between territories and the end of a
        -- territory's last column. Unread books are 0 and still paint.
        level = function(col, row)
            local c = plan.cells[col]
            return c and c[row]
        end,
    }

    return VerticalGroup:new{
        align = "left",
        heading,
        VerticalSpan:new{ width = sc(3) },
        grid,
        VerticalSpan:new{ width = sc(3) },
        sub,
    }
end

-- A radio list of axes. Each pick persists on this card's entry (which
-- reloads the card) and re-opens the dialog so the checkmark moves.
local function showSettings(ctx)
    if not (ctx and ctx.config) then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager    = require("ui/uimanager")
    local current = axisOf(ctx)
    local dialog
    local buttons = {}
    for _i, key in ipairs(AXES) do
        buttons[#buttons + 1] = { Kit.radioRow{
            label = AXIS[key].title, active = current == key,
            on_pick = function()
                ctx.config:set("axis", key)
                Kit.settingsReopen(ctx, dialog, showSettings)
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title        = _("Atlas map"),
        title_align  = "center",
        width_factor = 0.65,
        buttons      = buttons,
    }
    UIManager:show(dialog)
end

return {
    key           = "atlas_map", -- stored in users' menus; never change it
    title         = _("Atlas map"),
    summary       = _("Your library by language, author, series or genre. Works offline."),
    render        = render,
    show_settings = showSettings,
}
```

- [ ] **Step 4: Run the whole harness**

Run: `sh tests/run.sh`
Expected: `ran 10 suites, 0 failed`, `_test_map_module.lua  PASS 13  FAIL 0`.

- [ ] **Step 5: Install the module file**

In `tools/install.sh`, replace

```sh
cp micromodules/atlas_heatmap.lua micromodules/atlas_clock.lua "$DEST/"
```

with

```sh
cp micromodules/atlas_heatmap.lua micromodules/atlas_clock.lua micromodules/atlas_map.lua "$DEST/"
```

and in the AppleDouble comment below it replace

```sh
# filesystem an e-reader exposes over USB. Two of them -- ._atlas_heatmap.lua
# and ._atlas_clock.lua -- end in ".lua", which is exactly what bookshelf's
```

with

```sh
# filesystem an e-reader exposes over USB. Three of them -- ._atlas_heatmap.lua,
# ._atlas_clock.lua and ._atlas_map.lua -- end in ".lua", which is exactly what bookshelf's
```

- [ ] **Step 6: Verify the install into a scratch directory**

```bash
D=$(mktemp -d) && sh tools/install.sh "$D" && ls "$D/bookshelf/micromodules" "$D/bookshelf/micromodules/atlas"; rm -rf "$D"
```

Expected: `atlas_clock.lua  atlas_heatmap.lua  atlas_map.lua` and, under `atlas/`, `aggregate.lua calendar.lua db.lua grid.lua gridwidget.lua library.lua loader.lua scale.lua source.lua territory.lua`.

- [ ] **Step 7: Commit**

```bash
git add micromodules/atlas_map.lua tests/_test_map_module.lua tools/install.sh
git commit -m "feat: add the atlas_map module"
```

---

### Task 7: Documentation and the device checklist

**Files:**
- Modify: `README.md`
- Modify: `docs/CARRY-FORWARD.md`

No code. This task is done when the docs state exactly what is verified and what is not.

- [ ] **Step 1: README — what exists**

In `README.md`, replace the paragraph that begins `**Phase 2 — the reading map, without a network.**` (under `## Planned`) with nothing — delete it — and add this after the `**Atlas hours**` paragraph in `## What works today`:

```markdown
**Atlas map** (`atlas_map`) — your whole library as territory: one square
per book, grouped by language, author, series or genre, shaded by how far you
got (unread, on hold, reading, finished). Pick the grouping from the card's
*Module settings*; add the card twice to see two at once. It reads bookshelf's
own library, not the statistics database, so it is full even if you have
barely opened a book in KOReader. **Not yet verified on a device.**
```

Change the line `Two modules, both running on a real Kindle.` to `Three modules. The first two run on a real Kindle; the third is waiting for one.`

Change the `Both read KOReader's` sentence's subject to `Atlas year and Atlas hours read KOReader's`.

In the Install section, change `add **Atlas year** and **Atlas hours**` to `add **Atlas year**, **Atlas hours** and **Atlas map**`.

In the Planned section, change `**Phase 3 — the reading map, enriched.** Country and genre,` to `**Phase 3 — the reading map, enriched.** Country — and genre for books that carry none —`.

In Development, change `# 7 suites, 56 tests` to `# 10 suites, 114 tests`.

- [ ] **Step 2: CARRY-FORWARD — the device checklist**

Append to `docs/CARRY-FORWARD.md`:

```markdown
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
```

- [ ] **Step 3: Check the numbers in the README are true**

Run: `sh tests/run.sh`
Expected: 10 suites, and the PASS counts sum to 114 (9 + 10 + 18 + 5 + 3 + 8 + 12 + 24 + 12 + 13).

- [ ] **Step 4: Commit**

```bash
git add README.md docs/CARRY-FORWARD.md
git commit -m "docs: describe atlas_map and list what the device must verify"
```
