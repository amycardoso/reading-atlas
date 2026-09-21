# Reading Atlas Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two drop-in micro-modules for `bookshelf.koplugin` — `atlas_heatmap` (a year of reading as a grid of days) and `atlas_clock` (an hour × weekday grid) — reading KOReader's `statistics.sqlite3`.

**Architecture:** One SQL query, grouped by UTC hour, feeds both modules through a shared three-state cache. All bucketing, scaling and geometry are pure Lua functions in `micromodules/atlas/`, tested outside KOReader. Only the blitbuffer painting needs a device.

**Tech Stack:** Lua 5.1 / LuaJIT, KOReader runtime (`lua-ljsqlite3`, `ffi/blitbuffer`, `ui/uimanager`), bookshelf's module kit.

**Spec:** `docs/superpowers/specs/2026-09-20-reading-atlas-micromodules-design.md`

## Global Constraints

- **Module keys are frozen once released:** `atlas_heatmap`, `atlas_clock`. Never change them.
- **The host owns size.** Never write a font-fitting loop. Size every font through `Kit.sc(scale_pct)` / `Kit.face(size, scale_pct, opts)`.
- **The statistics DB is opened read-only, always.** `SQ3.open(path, "ro")` plus `PRAGMA busy_timeout=200;`. This project never writes to it.
- **The query runs once and off the paint thread** (`UIManager:scheduleIn(0, ...)` behind a `_querying` guard), per bookshelf issue #194.
- **Three states are distinct and never conflated:** `nil` = not queried yet (loading), `false` = queried, no statistics available, `table` = data.
- **Five intensity steps: 0..4.** Step 0 is "no reading". Steps 1..4 come from quartiles of days that have reading, never from absolute minutes.
- **Heatmap intensity is time read**, not pages.
- **Helpers are never loaded with `require("lib/...")`** — that path resolves into bookshelf's own `lib/`. Use the `atlas()` loader defined in Task 1.
- Commit messages in English, no AI attribution.

## Prerequisites

The suites run under a standalone Lua interpreter, which **is not installed on
this machine** (checked 2026-09-20: neither `lua` nor `luajit` is on PATH).
Install one before Task 1, or every "run the tests" step fails for the wrong
reason:

```bash
brew install lua        # or: brew install luajit
lua -v
```

LuaJIT matches KOReader's own runtime (Lua 5.1 semantics) most closely. Either
works for these suites, but **write Lua 5.1-compatible code**: no integer
division operator (`//`), no `goto`, no bitwise operators. KOReader is LuaJIT,
so 5.3-only syntax loads on a laptop and then fails on the device.

## File Structure

Deployed layout, under `<koreader settings>/bookshelf/micromodules/`:

```
atlas_heatmap.lua     <- scanned by bookshelf (spec table)
atlas_clock.lua       <- scanned by bookshelf (spec table)
atlas/                <- NOT scanned: scanDir is non-recursive and filters *.lua
  loader.lua          <- shared dofile-based helper loader
  aggregate.lua       <- pure: hour rows -> day / hour x weekday buckets
  scale.lua           <- pure: values -> quartile thresholds -> step 0..4
  grid.lua            <- pure: available box + cell counts -> cell geometry
  gridwidget.lua      <- paintTo widget (device-verified)
  db.lua              <- opens statistics.sqlite3, runs the one query
  source.lua          <- three-state cache + background scheduling
```

The repository mirrors this exactly, so installing is a plain directory copy.

```
micromodules/...      <- as above
tests/_helpers.lua    <- tiny runner (pass/fail counts, eq)
tests/run.sh          <- globs tests/_test_*.lua
tests/_test_*.lua     <- one suite per pure unit
tools/install.sh      <- copy micromodules/ into a KOReader settings dir
```

**Why the split:** `aggregate`, `scale` and `grid` hold every decision worth asserting and depend on nothing from KOReader, so they are tested on a laptop. `db`, `source` and `gridwidget` touch the runtime and stay deliberately thin — thin enough that reading them is enough to trust them.

---

### Task 1: Test harness and the helper loader

**Files:**
- Create: `tests/_helpers.lua`
- Create: `tests/run.sh`
- Create: `micromodules/atlas/loader.lua`
- Create: `tests/fixtures/atlas/probe.lua`
- Test: `tests/_test_loader.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `H.runner()` → `t` with `t.test(name, fn)`, `t.done()`; `H.eq(got, want, msg)`. `Loader.make(dir)` → `atlas(name)` function that dofiles `<dir>/atlas/<name>.lua` once, memoized in `package.loaded` under the key `"atlas/" .. name`.

- [ ] **Step 1: Write the failing test**

Create `tests/_test_loader.lua`:

```lua
-- The helper loader must NOT go through require("lib/..."), which would
-- resolve into bookshelf's own lib/ directory when running inside KOReader.
-- It dofiles from a path derived from the calling file, and memoizes so two
-- spec files sharing a helper load it once.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Loader = dofile("micromodules/atlas/loader.lua")

-- A fixture rather than a real helper, so this suite tests the loader and
-- nothing else, and does not break when a helper's shape changes.
local FIXTURES = "tests/fixtures/"

t.test("loads a helper relative to the given dir", function()
    local atlas = Loader.make(FIXTURES)
    eq(atlas("probe").marker, "probe")
end)

t.test("memoizes: the same table comes back twice", function()
    local atlas = Loader.make(FIXTURES)
    eq(atlas("probe"), atlas("probe"), "should be the same table")
end)

t.test("two loaders share one instance via package.loaded", function()
    local a = Loader.make(FIXTURES)("probe")
    local b = Loader.make(FIXTURES)("probe")
    eq(a, b, "both loaders should hand back the same table")
end)

t.done()
```

- [ ] **Step 2: Create the fixture and the harness so the test can run**

Create `tests/fixtures/atlas/probe.lua`:

```lua
-- Fixture for tests/_test_loader.lua. Deliberately trivial: the loader suite
-- asserts loading and memoization, not anything about a real helper.
return { marker = "probe" }
```


Create `tests/_helpers.lua`:

```lua
-- Shared helpers for Reading Atlas's pure-Lua suites. Run by tests/run.sh
-- under a standalone `lua`, NOT inside KOReader. Named with a leading
-- underscore and no _test_ prefix, so run.sh's glob skips it.
local M = {}

function M.runner()
    local pass, fail = 0, 0
    local t = {}
    t.test = function(name, fn)
        local ok, err = pcall(fn)
        if ok then
            pass = pass + 1
        else
            fail = fail + 1
            io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n")
        end
    end
    t.done = function()
        io.stdout:write(("PASS %d  FAIL %d\n"):format(pass, fail))
        os.exit(fail == 0 and 0 or 1)
    end
    return t
end

-- Deep-enough equality for the tables these suites compare (numbers, strings,
-- and flat/nested tables of them). Reports the path to the first difference,
-- because "tables differ" is useless when the table has 365 keys.
function M.eq(got, want, msg)
    local function cmp(a, b, path)
        if type(a) ~= type(b) then
            error(("%s: at %s got %s, want %s"):format(
                msg or "eq", path, type(a), type(b)), 0)
        end
        if type(a) ~= "table" then
            if a ~= b then
                error(("%s: at %s got %s, want %s"):format(
                    msg or "eq", path, tostring(a), tostring(b)), 0)
            end
            return
        end
        for k, v in pairs(a) do cmp(v, b[k], path .. "." .. tostring(k)) end
        for k in pairs(b) do
            if a[k] == nil then
                error(("%s: at %s.%s missing in got"):format(
                    msg or "eq", path, tostring(k)), 0)
            end
        end
    end
    cmp(got, want, "")
end

return M
```

Create `tests/run.sh`:

```sh
#!/bin/sh
# Run the pure-Lua Reading Atlas suites and report a single pass/fail.
#
#   sh tests/run.sh            # uses `lua` from PATH
#   LUA=luajit sh tests/run.sh
#
# A suite FAILS if it exits non-zero or prints a "FAIL " marker line.
cd "$(dirname "$0")/.." || exit 2
LUA="${LUA:-lua}"

total=0
failed=0
for f in tests/_test_*.lua; do
    total=$((total + 1))
    out=$("$LUA" "$f" 2>&1)
    status=$?
    if [ $status -ne 0 ] || printf '%s' "$out" | grep -q '^FAIL '; then
        failed=$((failed + 1))
        printf 'FAIL  %s\n%s\n' "$f" "$out"
    else
        printf 'ok    %s  %s\n' "$f" "$(printf '%s' "$out" | tail -1)"
    fi
done

printf 'ran %d suites, %d failed\n' "$total" "$failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `sh tests/run.sh`
Expected: FAIL — `micromodules/atlas/loader.lua` does not exist yet.

- [ ] **Step 4: Write the loader**

Create `micromodules/atlas/loader.lua`:

```lua
-- Helper loader for Reading Atlas.
--
-- ── WHY NOT require() ───────────────────────────────────────────────────────
-- Bookshelf dofiles each micro-module, and notes that a dofile'd file can
-- still require("lib/...") because package.path is process-wide. That is
-- exactly the problem: package.path points at BOOKSHELF's plugin root, so
-- require("lib/aggregate") would look inside bookshelf's lib/, not ours. Our
-- helpers live in a sibling atlas/ directory that is on nobody's package.path.
--
-- So: resolve from the calling file's own location and dofile. Results are
-- memoized in package.loaded (process-wide) under an "atlas/" prefix, so the
-- two spec files share one instance of each helper.
local M = {}

-- `dir` is the directory holding the spec files, WITH a trailing slash. A spec
-- file gets it from:  debug.getinfo(1, "S").source:match("^@(.+/)")
function M.make(dir)
    return function(name)
        local key = "atlas/" .. name
        local hit = package.loaded[key]
        if hit ~= nil then return hit end
        local mod = dofile(dir .. "atlas/" .. name .. ".lua")
        package.loaded[key] = mod
        return mod
    end
end

return M
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: `ran 1 suites, 0 failed`

- [ ] **Step 6: Commit**

```bash
chmod +x tests/run.sh
git add tests/ micromodules/atlas/loader.lua
git commit -m "test: add pure-Lua harness and the atlas helper loader

Helpers cannot be reached with require(\"lib/...\"): package.path points at
bookshelf's plugin root inside KOReader, so that name would resolve into
bookshelf's own lib/. The loader dofiles from the calling file's directory
instead and memoizes in package.loaded."
```

---

### Task 2: Day and hour×weekday bucketing

**Files:**
- Create: `micromodules/atlas/aggregate.lua`
- Test: `tests/_test_aggregate.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Aggregate.byDay(hour_rows, localtime)` → `{ ["YYYY-MM-DD"] = seconds }`
  - `Aggregate.byHourWeekday(hour_rows, localtime)` → `{ [wday] = { [hour] = seconds } }`, `wday` 1..7 with 1 = Sunday (matching `os.date("*t").wday`), `hour` 0..23
  - `hour_rows` is `{ { hour = <UTC hour number>, secs = <number> }, ... }` where `hour = floor(start_time / 3600)`
  - `localtime` is an injected `function(unix_ts) -> os.date("*t")-shaped table`; defaults to `os.date("*t", ts)`

**Design note for the implementer:** the injected `localtime` is what makes these tests deterministic. Without it every assertion would depend on the timezone of whoever runs the suite, and the suite would pass in São Paulo and fail in CI.

A reading session that crosses an hour boundary is attributed entirely to the hour it started in. Rows in `page_stat_data` are per page, so the error is bounded by one page's duration — small, and consistent between the two modules.

- [ ] **Step 1: Write the failing test**

Create `tests/_test_aggregate.lua`:

```lua
-- Bucketing is where every "when did I read" claim is decided, so it is
-- tested against an INJECTED clock: the same input must bucket identically
-- regardless of the machine's timezone.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Agg = dofile("micromodules/atlas/aggregate.lua")

-- A fake "local time" that is UTC+0, so expectations are readable.
local function utc(ts) return os.date("!*t", ts) end

-- 2026-01-05 was a Monday. os.date wday: 1=Sunday, so Monday is 2.
local MON_0900 = 1767603600  -- 2026-01-05T09:00:00Z

t.test("byDay sums a single hour into its day", function()
    local rows = { { hour = math.floor(MON_0900 / 3600), secs = 600 } }
    eq(Agg.byDay(rows, utc), { ["2026-01-05"] = 600 })
end)

t.test("byDay sums several hours of the same day", function()
    local rows = {
        { hour = math.floor(MON_0900 / 3600),            secs = 600 },
        { hour = math.floor((MON_0900 + 3600) / 3600),   secs = 300 },
    }
    eq(Agg.byDay(rows, utc), { ["2026-01-05"] = 900 })
end)

t.test("byDay separates days", function()
    local rows = {
        { hour = math.floor(MON_0900 / 3600),             secs = 600 },
        { hour = math.floor((MON_0900 + 86400) / 3600),   secs = 100 },
    }
    eq(Agg.byDay(rows, utc), { ["2026-01-05"] = 600, ["2026-01-06"] = 100 })
end)

t.test("byDay on no rows is an empty table, not nil", function()
    eq(Agg.byDay({}, utc), {})
end)

t.test("byHourWeekday puts Monday 09:00 at wday 2, hour 9", function()
    local rows = { { hour = math.floor(MON_0900 / 3600), secs = 600 } }
    local got = Agg.byHourWeekday(rows, utc)
    eq(got[2][9], 600)
end)

t.test("byHourWeekday sums the same slot across weeks", function()
    local rows = {
        { hour = math.floor(MON_0900 / 3600),                secs = 600 },
        { hour = math.floor((MON_0900 + 7 * 86400) / 3600),  secs = 400 },
    }
    local got = Agg.byHourWeekday(rows, utc)
    eq(got[2][9], 1000)
end)

t.test("byHourWeekday returns a full 7x24 grid, zeros included", function()
    local got = Agg.byHourWeekday({ { hour = math.floor(MON_0900 / 3600), secs = 60 } }, utc)
    local cells, sum = 0, 0
    for wday = 1, 7 do
        for hour = 0, 23 do
            assert(got[wday][hour] ~= nil,
                ("missing cell wday=%d hour=%d"):format(wday, hour))
            cells = cells + 1
            sum = sum + got[wday][hour]
        end
    end
    eq(cells, 168, "grid should have 7*24 cells")
    eq(sum, 60, "only the seeded minute should be counted")
end)

t.done()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua tests/_test_aggregate.lua`
Expected: FAIL — `attempt to call field 'byDay' (a nil value)`

- [ ] **Step 3: Implement**

Create `micromodules/atlas/aggregate.lua`:

```lua
-- Pure bucketing of reading time. No KOReader, no I/O, no globals touched.
--
-- Input is always `hour_rows`: { { hour = <UTC hour number>, secs = n }, ... }
-- where hour = floor(start_time / 3600). One query produces it; both modules
-- consume it.
--
-- `localtime` is injected so the suites are timezone-independent. Production
-- callers omit it and get os.date("*t", ts), i.e. the device's local time,
-- which is what a reader means by "what did I read on Tuesday".
local M = {}

local function defaultLocaltime(ts) return os.date("*t", ts) end

-- { ["YYYY-MM-DD"] = seconds }, only for days that have reading.
function M.byDay(hour_rows, localtime)
    localtime = localtime or defaultLocaltime
    local out = {}
    for i = 1, #hour_rows do
        local row = hour_rows[i]
        local d = localtime(row.hour * 3600)
        local key = ("%04d-%02d-%02d"):format(d.year, d.month, d.day)
        out[key] = (out[key] or 0) + row.secs
    end
    return out
end

-- Full 7x24 grid of seconds. Zeros are PRESENT, not absent: the widget paints
-- every cell, and a nil would make it decide between "no data" and "no
-- reading" at paint time, which is a decision that belongs here.
function M.byHourWeekday(hour_rows, localtime)
    localtime = localtime or defaultLocaltime
    local out = {}
    for wday = 1, 7 do
        out[wday] = {}
        for hour = 0, 23 do out[wday][hour] = 0 end
    end
    for i = 1, #hour_rows do
        local row = hour_rows[i]
        local d = localtime(row.hour * 3600)
        out[d.wday][d.hour] = out[d.wday][d.hour] + row.secs
    end
    return out
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: `ran 2 suites, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/aggregate.lua tests/_test_aggregate.lua
git commit -m "feat: bucket reading time by day and by hour x weekday

One hour-grouped row set feeds both modules. The local-time converter is
injected so the suites assert the same result in any timezone."
```

---

### Task 3: Quartile intensity scale

**Files:**
- Create: `micromodules/atlas/scale.lua`
- Test: `tests/_test_scale.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Scale.thresholds(values)` → sorted array of 3 numbers (the quartile cuts), or `nil` when there is nothing to scale
  - `Scale.level(value, thresholds)` → integer 0..4

- [ ] **Step 1: Write the failing test**

Create `tests/_test_scale.lua`:

```lua
-- Five steps: 0 (no reading) plus four levels cut at quartiles of the days
-- that DO have reading. Quartiles, not fixed minutes, so a twenty-minute
-- reader and a three-hour reader each see the shape of their own year rather
-- than an empty grid or a saturated one.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Scale = dofile("micromodules/atlas/scale.lua")

t.test("zero is always level 0, whatever the thresholds", function()
    eq(Scale.level(0, { 10, 20, 30 }), 0)
end)

t.test("a value spreads across the four levels", function()
    local th = Scale.thresholds({ 10, 20, 30, 40 })
    eq(Scale.level(10, th), 1)
    eq(Scale.level(40, th), 4)
end)

t.test("levels are monotonic: more time never means a lower level", function()
    local vals = {}
    for i = 1, 100 do vals[i] = i * 7 end
    local th = Scale.thresholds(vals)
    local prev = 0
    for i = 1, 100 do
        local lv = Scale.level(vals[i], th)
        assert(lv >= prev, ("level dropped at %d: %d after %d"):format(i, lv, prev))
        prev = lv
    end
end)

t.test("every level from 1 to 4 is actually used on a wide spread", function()
    local vals = {}
    for i = 1, 100 do vals[i] = i end
    local th = Scale.thresholds(vals)
    local seen = {}
    for i = 1, 100 do seen[Scale.level(vals[i], th)] = true end
    for lv = 1, 4 do
        assert(seen[lv], "level " .. lv .. " was never used")
    end
end)

t.test("all-identical values still land on a single valid level", function()
    local vals = {}
    for i = 1, 10 do vals[i] = 600 end
    local th = Scale.thresholds(vals)
    local lv = Scale.level(600, th)
    assert(lv >= 1 and lv <= 4, "got level " .. tostring(lv))
end)

t.test("a single reading day does not crash and is not level 0", function()
    local th = Scale.thresholds({ 600 })
    assert(Scale.level(600, th) >= 1)
end)

t.test("no values at all yields nil thresholds, and level falls back to 0", function()
    eq(Scale.thresholds({}), nil)
    eq(Scale.level(0, nil), 0)
end)

t.test("a positive value with nil thresholds is level 1, never 0", function()
    -- Guards a real failure mode: if thresholds are missing for any reason,
    -- a day WITH reading must never be painted as a day without.
    eq(Scale.level(600, nil), 1)
end)

t.done()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua tests/_test_scale.lua`
Expected: FAIL — cannot open `micromodules/atlas/scale.lua`

- [ ] **Step 3: Implement**

Create `micromodules/atlas/scale.lua`:

```lua
-- Five intensity steps, 0..4.
--
-- Step 0 means "did not read". Steps 1..4 are quartiles of the values that
-- are > 0, so the scale is relative to the reader's own history. Absolute
-- minute thresholds were rejected in the design: they make a light reader's
-- year look empty and a heavy reader's look uniformly full.
local M = {}

-- Returns the three quartile cuts of the positive values, or nil when there
-- are none. Cuts are read off the sorted values by position, which needs no
-- interpolation and behaves sanely on tiny samples.
function M.thresholds(values)
    local pos = {}
    for i = 1, #values do
        if values[i] and values[i] > 0 then pos[#pos + 1] = values[i] end
    end
    if #pos == 0 then return nil end
    table.sort(pos)
    local function at(fraction)
        local idx = math.floor(#pos * fraction + 0.5)
        if idx < 1 then idx = 1 end
        if idx > #pos then idx = #pos end
        return pos[idx]
    end
    return { at(0.25), at(0.50), at(0.75) }
end

-- 0 for no reading; otherwise 1..4.
function M.level(value, thresholds)
    if not value or value <= 0 then return 0 end
    -- No thresholds but real reading: show the lowest INK level, never blank.
    -- Painting a day that had reading as empty is the one error a heatmap
    -- must not make.
    if not thresholds then return 1 end
    if value <= thresholds[1] then return 1 end
    if value <= thresholds[2] then return 2 end
    if value <= thresholds[3] then return 3 end
    return 4
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: `ran 3 suites, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/scale.lua tests/_test_scale.lua
git commit -m "feat: quartile-based five-step intensity scale

Relative to the reader's own history, so light and heavy readers both get a
legible year. A day with reading can never fall to the empty step."
```

---

### Task 4: Grid geometry

**Files:**
- Create: `micromodules/atlas/grid.lua`
- Test: `tests/_test_grid.lua`

**Interfaces:**
- Consumes: nothing.
- Produces: `Grid.layout(opts)` → `{ cell = n, gap = n, w = n, h = n }` where `opts` is `{ width, height, cols, rows, gap_ratio }`. `gap_ratio` defaults to `0.18` (gap as a fraction of cell size). `w`/`h` are the painted extent, always `<= width` / `<= height`.

- [ ] **Step 1: Write the failing test**

Create `tests/_test_grid.lua`:

```lua
-- The host re-renders the card at different scales until it fits, so this
-- geometry runs a lot and must never return something unpaintable: a cell
-- below one pixel, or an extent wider than the box it was given.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Grid = dofile("micromodules/atlas/grid.lua")

t.test("fits inside the box it is given", function()
    local g = Grid.layout{ width = 300, height = 100, cols = 53, rows = 7 }
    assert(g.w <= 300, "width overflow: " .. g.w)
    assert(g.h <= 100, "height overflow: " .. g.h)
end)

t.test("cell is at least 1 pixel even in an absurdly small box", function()
    local g = Grid.layout{ width = 10, height = 10, cols = 53, rows = 7 }
    assert(g.cell >= 1, "cell was " .. tostring(g.cell))
end)

t.test("the limiting dimension decides the cell size", function()
    -- Very wide, very short: height must be what constrains a 7-row grid.
    local g = Grid.layout{ width = 10000, height = 70, cols = 53, rows = 7 }
    assert(g.h <= 70, "height overflow: " .. g.h)
    assert(g.cell <= 10, "cell should be limited by height, got " .. g.cell)
end)

t.test("extent matches cell and gap arithmetic exactly", function()
    local g = Grid.layout{ width = 400, height = 200, cols = 10, rows = 5 }
    eq(g.w, g.cell * 10 + g.gap * 9, "width must be cells plus inner gaps")
    eq(g.h, g.cell * 5 + g.gap * 4, "height must be cells plus inner gaps")
end)

t.test("a single column and row is valid", function()
    local g = Grid.layout{ width = 50, height = 50, cols = 1, rows = 1 }
    eq(g.gap, 0, "one cell has no inner gap to draw")
    assert(g.cell >= 1)
end)

t.test("zero or negative box still returns a paintable 1px cell", function()
    local g = Grid.layout{ width = 0, height = 0, cols = 7, rows = 7 }
    assert(g.cell >= 1, "cell was " .. tostring(g.cell))
end)

t.done()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua tests/_test_grid.lua`
Expected: FAIL — cannot open `micromodules/atlas/grid.lua`

- [ ] **Step 3: Implement**

Create `micromodules/atlas/grid.lua`:

```lua
-- Cell geometry for a cols x rows grid inside a box.
--
-- Integer pixels only: e-ink has no subpixels, and a fractional cell would
-- make neighbouring columns differ by a pixel in a way that reads as a wobble.
local M = {}

local DEFAULT_GAP_RATIO = 0.18

function M.layout(opts)
    local cols = math.max(1, opts.cols or 1)
    local rows = math.max(1, opts.rows or 1)
    local ratio = opts.gap_ratio or DEFAULT_GAP_RATIO
    local width = math.max(0, opts.width or 0)
    local height = math.max(0, opts.height or 0)

    -- Solve cell from each dimension independently, then take the tighter.
    -- With gap = cell * ratio: extent = cell * n + cell * ratio * (n - 1).
    local function cellFor(extent, n)
        local denom = n + ratio * (n - 1)
        return math.floor(extent / denom)
    end

    local cell = math.min(cellFor(width, cols), cellFor(height, rows))
    -- Never return an unpaintable cell. A 1px grid in a 10px box overflows
    -- the box, and that is correct: the host clips as its documented
    -- backstop, and a visible sliver beats an invisible card.
    if cell < 1 then cell = 1 end

    local gap = math.floor(cell * ratio)
    if cell > 2 and gap < 1 then gap = 1 end

    return {
        cell = cell,
        gap  = gap,
        w    = cell * cols + gap * (cols - 1),
        h    = cell * rows + gap * (rows - 1),
    }
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: `ran 4 suites, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/grid.lua tests/_test_grid.lua
git commit -m "feat: integer-pixel grid geometry

Solves cell size from whichever dimension is tighter and never returns a
sub-pixel cell, since the host re-renders this at many scales."
```

---

### Task 5: The grid widget

**Files:**
- Create: `micromodules/atlas/gridwidget.lua`
- Test: `tests/_test_gridwidget.lua`

**Interfaces:**
- Consumes: `Grid.layout` (Task 4).
- Produces: `GridWidget.new(opts)` → a widget table with `getSize()` and `paintTo(bb, x, y)`. `opts` is `{ width, height, cols, rows, level = function(col, row) -> 0..4 }`, columns and rows both 1-based.

**Design note:** the widget takes a `level(col, row)` callback rather than a data table, so the same widget paints the 53×7 heatmap and the 24×7 clock without knowing what either means. `INK` maps step 0..4 to luminance, light to dark — step 0 is a very light grey, not white, so an unread day still reads as part of the grid.

Only `getSize` is unit-tested. `paintTo` needs a real blitbuffer and is verified on the device in Task 9.

- [ ] **Step 1: Write the failing test**

Create `tests/_test_gridwidget.lua`:

```lua
-- Only the size contract is testable off-device: paintTo needs a real
-- blitbuffer. What matters here is that the widget reports the size it will
-- actually paint, because the host lays out around that number.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

-- Stub the two KOReader modules the widget pulls in at load.
package.loaded["ui/geometry"] = {
    new = function(_, o) return o end,
}
package.loaded["ffi/blitbuffer"] = {
    Color8 = function(v) return { v = v } end,
}

local GW = dofile("micromodules/atlas/gridwidget.lua")

t.test("getSize matches the grid extent", function()
    local Grid = dofile("micromodules/atlas/grid.lua")
    local want = Grid.layout{ width = 400, height = 200, cols = 10, rows = 5 }
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    local size = w:getSize()
    eq(size.w, want.w)
    eq(size.h, want.h)
end)

t.test("exposes one ink value per step, 0 through 4", function()
    for lv = 0, 4 do
        assert(GW.INK[lv] ~= nil, "no ink for level " .. lv)
    end
end)

t.test("ink darkens monotonically as the level rises", function()
    for lv = 1, 4 do
        assert(GW.INK[lv] < GW.INK[lv - 1],
            ("level %d should be darker than %d"):format(lv, lv - 1))
    end
end)

t.test("step 0 is grey, not white: an unread day stays part of the grid", function()
    assert(GW.INK[0] < 255, "level 0 must not be pure white")
end)

t.done()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua tests/_test_gridwidget.lua`
Expected: FAIL — cannot open `micromodules/atlas/gridwidget.lua`

- [ ] **Step 3: Implement**

Create `micromodules/atlas/gridwidget.lua`:

```lua
-- A cols x rows grid of filled cells, painted straight into the blitbuffer.
--
-- Follows bookshelf's analogue_clock: a plain table with getSize() and
-- paintTo(bb, x, y). There is no polygon fill in KOReader, and none is
-- needed -- every cell is a rectangle.
--
-- The caller supplies level(col, row) -> 0..4 rather than a data table, so
-- this one widget paints both the day heatmap and the hour x weekday clock.
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")

local Grid = nil  -- injected below by the spec files' loader, or dofile'd

local M = {}

-- Luminance per step, light to dark. Five steps is the ceiling for what is
-- reliably distinguishable on e-ink at this cell size; step 0 is a light grey
-- rather than white so a day without reading still reads as a cell.
M.INK = { [0] = 0xE0, [1] = 0xB0, [2] = 0x80, [3] = 0x50, [4] = 0x20 }

-- `grid_mod` lets callers hand in the already-loaded Grid helper. Falls back
-- to a sibling dofile so this file also works standalone in tests.
function M.setGrid(grid_mod) Grid = grid_mod end

local function grid()
    if Grid then return Grid end
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    Grid = dofile(dir .. "grid.lua")
    return Grid
end

function M.new(opts)
    local g = grid().layout{
        width = opts.width, height = opts.height,
        cols = opts.cols, rows = opts.rows,
        gap_ratio = opts.gap_ratio,
    }
    local w = {
        cols = opts.cols, rows = opts.rows,
        level = opts.level,
        geom = g,
        dimen = Geom:new{ w = g.w, h = g.h },
    }
    function w:getSize() return Geom:new{ w = g.w, h = g.h } end
    function w:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = g.w, h = g.h }
        local step = g.cell + g.gap
        for col = 1, self.cols do
            for row = 1, self.rows do
                local lv = self.level(col, row) or 0
                bb:paintRect(x + (col - 1) * step, y + (row - 1) * step,
                    g.cell, g.cell, Blitbuffer.Color8(M.INK[lv] or M.INK[0]))
            end
        end
    end
    return w
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: `ran 5 suites, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add micromodules/atlas/gridwidget.lua tests/_test_gridwidget.lua
git commit -m "feat: blitbuffer grid widget shared by both modules

Takes a level(col,row) callback rather than data, so one widget paints the
day heatmap and the hour x weekday clock."
```

---

### Task 6: Statistics query and the three-state source

**Files:**
- Create: `micromodules/atlas/db.lua`
- Create: `micromodules/atlas/source.lua`
- Test: `tests/_test_source.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Db.hourRows()` → array of `{ hour = n, secs = n }`, or `nil` when the database is missing or unreadable
  - `Source.get(refresh, deps)` → `nil` (loading, a fetch was scheduled) / `false` (queried, no statistics) / `table` (hour rows). `deps` is `{ query = fn, schedule = fn, now = fn }`, injected by tests and omitted in production.
  - `Source.reset()` — clears the cache; used by tests only.

**Design note:** `db.lua` stays thin on purpose — it holds the SQL and nothing else, because it cannot be unit-tested off-device. Everything worth asserting (the three states, the query-once guard) lives in `source.lua` behind injected dependencies.

The SQL groups by UTC hour, which bounds the result at a few thousand rows over years of reading, and serves both modules from one scan.

- [ ] **Step 1: Write the failing test**

Create `tests/_test_source.lua`:

```lua
-- The contract that bookshelf issue #194 paid for: the query runs once, off
-- the paint thread, and the three states are never conflated. A caller must
-- be able to tell "still loading" from "there are no statistics", because
-- they render as different cards.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Source = dofile("micromodules/atlas/source.lua")

-- Deferred scheduler: collects thunks so a test can decide when they run.
local function makeDeps(query)
    local pending = {}
    return {
        deps = {
            query = query,
            schedule = function(fn) pending[#pending + 1] = fn end,
            now = function() return 1000 end,
        },
        run = function()
            local queued = pending
            pending = {}
            for i = 1, #queued do queued[i]() end
        end,
        pendingCount = function() return #pending end,
    }
end

t.test("first call returns nil (loading) and does not query inline", function()
    Source.reset()
    local calls = 0
    local d = makeDeps(function() calls = calls + 1; return {} end)
    eq(Source.get(nil, d.deps), nil, "first call should report loading")
    eq(calls, 0, "query must NOT run on the paint thread")
    eq(d.pendingCount(), 1, "a fetch should have been scheduled")
end)

t.test("after the scheduled fetch runs, the rows are returned", function()
    Source.reset()
    local rows = { { hour = 10, secs = 60 } }
    local d = makeDeps(function() return rows end)
    Source.get(nil, d.deps)
    d.run()
    eq(Source.get(nil, d.deps), rows)
end)

t.test("a missing database resolves to false, not nil", function()
    Source.reset()
    local d = makeDeps(function() return nil end)
    Source.get(nil, d.deps)
    d.run()
    eq(Source.get(nil, d.deps), false, "no statistics must be false, not loading")
end)

t.test("concurrent renders schedule the query only once", function()
    Source.reset()
    local calls = 0
    local d = makeDeps(function() calls = calls + 1; return {} end)
    Source.get(nil, d.deps)
    Source.get(nil, d.deps)
    Source.get(nil, d.deps)
    eq(d.pendingCount(), 1, "the guard should collapse concurrent renders")
    d.run()
    eq(calls, 1, "the query should have run exactly once")
end)

t.test("the refresh callback fires once the data lands", function()
    Source.reset()
    local refreshed = 0
    local d = makeDeps(function() return {} end)
    Source.get(function() refreshed = refreshed + 1 end, d.deps)
    eq(refreshed, 0, "must not refresh before the data exists")
    d.run()
    eq(refreshed, 1)
end)

t.test("a query that raises resolves to false and does not wedge the guard", function()
    Source.reset()
    local d = makeDeps(function() error("boom") end)
    Source.get(nil, d.deps)
    d.run()
    eq(Source.get(nil, d.deps), false)
end)

t.done()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua tests/_test_source.lua`
Expected: FAIL — cannot open `micromodules/atlas/source.lua`

- [ ] **Step 3: Write the database layer**

Create `micromodules/atlas/db.lua`:

```lua
-- The one query Reading Atlas makes. Read-only, always.
--
-- Grouping by UTC hour bounds the result at hours-with-reading (a few
-- thousand over years) instead of one row per page read, and serves both the
-- day heatmap and the hour x weekday clock from a single scan. Converting to
-- local time is Lua's job, in aggregate.lua, where it can be tested.
--
-- Session time is attributed to the hour the page was opened in. Rows are
-- per page, so the error is bounded by one page's duration.
local M = {}

local SQL = [[
    SELECT start_time / 3600 AS hour, SUM(duration) AS secs
    FROM page_stat_data
    GROUP BY hour
    ORDER BY hour;
]]

-- Returns an array of { hour = n, secs = n }, or nil when there is no
-- readable statistics database. nil is a real answer here -- the caller turns
-- it into the "no statistics" state -- so failures are swallowed by design.
function M.hourRows()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil end
    local path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil end

    local ok, rows = pcall(function()
        local conn = SQ3.open(path, "ro")
        conn:exec("PRAGMA busy_timeout=200;")
        local result = conn:exec(SQL)
        conn:close()
        if not result or not result[1] then return {} end
        local out = {}
        for i = 1, #result[1] do
            out[i] = {
                hour = tonumber(result[1][i]),
                secs = tonumber(result[2][i]) or 0,
            }
        end
        return out
    end)
    if not ok then return nil end
    return rows
end

return M
```

- [ ] **Step 4: Write the source**

Create `micromodules/atlas/source.lua`:

```lua
-- Three-state, query-once cache over db.hourRows().
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
-- Three states, deliberately distinct:
--   nil   -> not queried yet; a fetch is scheduled. Render "Reading…".
--   false -> queried; no statistics database. Render an explanation.
--   table -> hour rows.
local M = {}

local _cache = nil      -- nil | false | table
local _querying = false

local function defaultDeps()
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return {
        query = function() return dofile(dir .. "db.lua").hourRows() end,
        schedule = function(fn) require("ui/uimanager"):scheduleIn(0, fn) end,
        now = os.time,
    }
end

-- Tests only.
function M.reset()
    _cache = nil
    _querying = false
end

function M.get(refresh, deps)
    deps = deps or defaultDeps()
    if _cache ~= nil then return _cache end
    if _querying then return nil end
    _querying = true
    deps.schedule(function()
        local ok, rows = pcall(deps.query)
        -- Both a raised error and a nil return mean the same thing to a
        -- reader: there are no statistics to show. Never leave the cache at
        -- nil here, or the module would re-query on every single render.
        _cache = (ok and rows) or false
        _querying = false
        if refresh then pcall(refresh) end
    end)
    return nil
end

return M
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: `ran 6 suites, 0 failed`

- [ ] **Step 6: Commit**

```bash
git add micromodules/atlas/db.lua micromodules/atlas/source.lua tests/_test_source.lua
git commit -m "feat: read-only statistics query behind a three-state cache

One hour-grouped scan serves both modules. The query is scheduled off the
paint thread behind a guard, per bookshelf issue #194, and loading is kept
distinct from having no statistics at all."
```

---

### Task 7: The `atlas_heatmap` module

**Files:**
- Create: `micromodules/atlas_heatmap.lua`
- Test: `tests/_test_heatmap_columns.lua`
- Create: `micromodules/atlas/calendar.lua`

**Interfaces:**
- Consumes: `Source.get`, `Aggregate.byDay`, `Scale.thresholds` / `Scale.level`, `GridWidget.new`, `Loader.make`.
- Produces: a bookshelf module spec with `key = "atlas_heatmap"`. `Calendar.columns(year, localtime)` → `{ weeks = n, dayKey = function(col, row) -> "YYYY-MM-DD"|nil }`, with `row` 1..7 (1 = Sunday) and `col` 1..weeks.

- [ ] **Step 1: Write the failing test**

Create `tests/_test_heatmap_columns.lua`:

```lua
-- The calendar mapping is where an off-by-one becomes a year drawn one day
-- skewed, which is the kind of bug you only notice in December.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local Cal = dofile("micromodules/atlas/calendar.lua")
local function utc(ts) return os.date("!*t", ts) end

t.test("a year needs 53 columns at most and 52 at least", function()
    local c = Cal.columns(2026, utc)
    assert(c.weeks >= 52 and c.weeks <= 54, "got " .. c.weeks)
end)

t.test("2026-01-01 was a Thursday: row 5, column 1", function()
    local c = Cal.columns(2026, utc)
    eq(c.dayKey(1, 5), "2026-01-01")
end)

t.test("cells before the first day of the year are empty", function()
    local c = Cal.columns(2026, utc)
    eq(c.dayKey(1, 1), nil, "Sunday of week 1 precedes Jan 1 in 2026")
end)

t.test("the last day of the year is present exactly once", function()
    local c = Cal.columns(2026, utc)
    local seen = 0
    for col = 1, c.weeks do
        for row = 1, 7 do
            if c.dayKey(col, row) == "2026-12-31" then seen = seen + 1 end
        end
    end
    eq(seen, 1)
end)

t.test("every day of a leap year appears exactly once", function()
    local c = Cal.columns(2024, utc)
    local count = 0
    for col = 1, c.weeks do
        for row = 1, 7 do
            if c.dayKey(col, row) then count = count + 1 end
        end
    end
    eq(count, 366, "2024 is a leap year")
end)

t.done()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua tests/_test_heatmap_columns.lua`
Expected: FAIL — cannot open `micromodules/atlas/calendar.lua`

- [ ] **Step 3: Implement the calendar mapping**

Create `micromodules/atlas/calendar.lua`:

```lua
-- Maps a year onto GitHub's layout: one column per week, one row per weekday,
-- row 1 = Sunday to match os.date("*t").wday. Cells before January 1st and
-- after December 31st are empty.
local M = {}

local function defaultLocaltime(ts) return os.date("*t", ts) end

function M.columns(year, localtime)
    localtime = localtime or defaultLocaltime
    -- Noon avoids DST midnight shifts moving a day into its neighbour.
    local jan1 = os.time{ year = year, month = 1, day = 1, hour = 12 }
    local dec31 = os.time{ year = year, month = 12, day = 31, hour = 12 }
    local first_wday = localtime(jan1).wday          -- 1..7, 1 = Sunday
    local days = math.floor((dec31 - jan1) / 86400) + 1
    local weeks = math.ceil((first_wday - 1 + days) / 7)

    local function dayKey(col, row)
        -- Cell index counted from the Sunday that opens week 1.
        local idx = (col - 1) * 7 + row
        local day_of_year = idx - (first_wday - 1)
        if day_of_year < 1 or day_of_year > days then return nil end
        local d = localtime(jan1 + (day_of_year - 1) * 86400)
        return ("%04d-%02d-%02d"):format(d.year, d.month, d.day)
    end

    return { weeks = weeks, dayKey = dayKey }
end

return M
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `sh tests/run.sh`
Expected: `ran 7 suites, 0 failed`

- [ ] **Step 5: Write the module spec file**

Create `micromodules/atlas_heatmap.lua`:

```lua
-- Reading Atlas: a year of reading as a grid of days.
--
-- Drop this file, atlas_clock.lua and the atlas/ directory into
-- <koreader settings>/bookshelf/micromodules/ .
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local rows = atlas("source").get(refresh)

    if rows == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading year"), value = _("Reading…") }
    end
    if rows == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading year"), value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local year = tonumber(os.date("%Y"))
    local by_day = atlas("aggregate").byDay(rows)
    local values = {}
    for _k, v in pairs(by_day) do values[#values + 1] = v end
    local Scale = atlas("scale")
    local thresholds = Scale.thresholds(values)

    local cal = atlas("calendar").columns(year)
    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))

    return GW.new{
        width = width,
        height = ctx.height or math.floor(width / 7),
        cols = cal.weeks,
        rows = 7,
        level = function(col, row)
            local key = cal.dayKey(col, row)
            if not key then return 0 end
            return Scale.level(by_day[key], thresholds)
        end,
    }
end

return {
    key     = "atlas_heatmap",
    title   = _("Reading year"),
    summary = _("From KOReader statistics. Works offline."),
    render  = render,
}
```

- [ ] **Step 6: Verify the spec file is structurally valid**

Run:
```bash
lua -e 'local f = loadfile("micromodules/atlas_heatmap.lua"); assert(f, "syntax error"); print("syntax ok")'
```
Expected: `syntax ok`

(The file cannot be *executed* outside KOReader — it requires bookshelf's kit — so this checks syntax only. Behaviour is verified on the device in Task 9.)

- [ ] **Step 7: Commit**

```bash
git add micromodules/atlas_heatmap.lua micromodules/atlas/calendar.lua tests/_test_heatmap_columns.lua
git commit -m "feat: add the atlas_heatmap module

A year of reading as a GitHub-style grid of days, with the calendar mapping
tested against leap years and the first-weekday offset."
```

---

### Task 8: The `atlas_clock` module

**Files:**
- Create: `micromodules/atlas_clock.lua`

**Interfaces:**
- Consumes: `Source.get`, `Aggregate.byHourWeekday`, `Scale`, `GridWidget`, `Loader.make`.
- Produces: a bookshelf module spec with `key = "atlas_clock"`.

**Design note:** columns are hours 0..23 and rows are weekdays 1..7, so the card is wide and short — the same proportion as the heatmap, which is why both sit well in one grid row. No new tested logic is introduced: this task is composition over units already covered by Tasks 2, 3, 4 and 5.

- [ ] **Step 1: Write the module spec file**

Create `micromodules/atlas_clock.lua`:

```lua
-- Reading Atlas: when do I actually read? Hours across, weekdays down.
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local rows = atlas("source").get(refresh)

    if rows == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading clock"), value = _("Reading…") }
    end
    if rows == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading clock"), value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local grid_data = atlas("aggregate").byHourWeekday(rows)
    local values = {}
    for wday = 1, 7 do
        for hour = 0, 23 do
            values[#values + 1] = grid_data[wday][hour]
        end
    end
    local Scale = atlas("scale")
    local thresholds = Scale.thresholds(values)

    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))

    return GW.new{
        width = width,
        height = ctx.height or math.floor(width / 3),
        cols = 24,
        rows = 7,
        -- col 1 is hour 0; row 1 is Sunday, matching os.date wday.
        level = function(col, row)
            return Scale.level(grid_data[row][col - 1], thresholds)
        end,
    }
end

return {
    key     = "atlas_clock",
    title   = _("Reading clock"),
    summary = _("From KOReader statistics. Works offline."),
    render  = render,
}
```

- [ ] **Step 2: Verify the spec file is structurally valid**

Run:
```bash
lua -e 'local f = loadfile("micromodules/atlas_clock.lua"); assert(f, "syntax error"); print("syntax ok")'
```
Expected: `syntax ok`

- [ ] **Step 3: Run the whole suite to confirm nothing regressed**

Run: `sh tests/run.sh`
Expected: `ran 7 suites, 0 failed`

- [ ] **Step 4: Commit**

```bash
git add micromodules/atlas_clock.lua
git commit -m "feat: add the atlas_clock module

Hours across, weekdays down, over the same query and the same grid widget as
the heatmap."
```

---

### Task 9: Install script and on-device verification

**Files:**
- Create: `tools/install.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: an installed, verified pair of modules.

- [ ] **Step 1: Write the install script**

Create `tools/install.sh`:

```sh
#!/bin/sh
# Copy Reading Atlas into a KOReader settings directory.
#
#   sh tools/install.sh /mnt/onboard/.adds/koreader/settings      # Kobo
#   sh tools/install.sh /mnt/us/koreader/settings                 # Kindle
#
# The target is KOReader's SETTINGS dir, not its plugins dir: bookshelf scans
# <settings>/bookshelf/micromodules/ for user modules, and that location
# survives bookshelf updates.
set -e

SETTINGS="$1"
if [ -z "$SETTINGS" ]; then
    echo "usage: sh tools/install.sh <koreader-settings-dir>" >&2
    exit 2
fi
if [ ! -d "$SETTINGS" ]; then
    echo "not a directory: $SETTINGS" >&2
    exit 2
fi

DEST="$SETTINGS/bookshelf/micromodules"
mkdir -p "$DEST/atlas"

cd "$(dirname "$0")/.."
cp micromodules/atlas_heatmap.lua micromodules/atlas_clock.lua "$DEST/"
cp micromodules/atlas/*.lua "$DEST/atlas/"

echo "installed to $DEST"
echo "restart KOReader, then add the modules from the bookshelf module picker."
```

- [ ] **Step 2: Install onto the device**

Run: `sh tools/install.sh <your KOReader settings dir>`
Expected: `installed to .../bookshelf/micromodules`

- [ ] **Step 3: Verify on the device**

Restart KOReader, open bookshelf, long-press the module grid, tap **+**, and confirm:

- [ ] "Reading year" and "Reading clock" both appear in the picker
- [ ] Adding each one draws a grid, not an error card
- [ ] Opening the shelf does not stall, even on the first open after a restart (this is the #194 behaviour)
- [ ] The five intensity steps are distinguishable on the actual screen — if steps 2 and 3 are hard to tell apart, adjust `M.INK` in `micromodules/atlas/gridwidget.lua` and reinstall
- [ ] Resizing the module (long-press, `-` / `+`) keeps the grid inside its cell

If a module does not appear at all, check KOReader's log for `[bookshelf] micro-module` — the loader logs the reason and skips silently otherwise.

- [ ] **Step 4: Update the README status**

In `README.md`, replace the status block with:

```markdown
> **Status: phase 1 usable.** `atlas_heatmap` and `atlas_clock` install and
> run. Install with `sh tools/install.sh <koreader-settings-dir>`.
```

- [ ] **Step 5: Commit**

```bash
chmod +x tools/install.sh
git add tools/install.sh README.md
git commit -m "feat: add install script and mark phase 1 usable"
```

---

## Verification

Phase 1 is done when all of the following hold:

- `sh tests/run.sh` reports `ran 7 suites, 0 failed`
- Both modules appear in bookshelf's picker and draw grids on the device
- The shelf opens without stalling on a cold start
- Nothing in the repository writes to `statistics.sqlite3` — confirm with
  `grep -rn "SQ3.open" micromodules/` and check every hit passes `"ro"`
