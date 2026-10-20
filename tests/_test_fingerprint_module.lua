-- atlas_fingerprint.lua is composition over fingerprint.lua and the strip
-- widget. It runs here against stubs of bookshelf's Kit and KOReader's
-- widgets, to catch what the other suites cannot: a typo, a nil, a state wired
-- to the wrong card. Painting and the real database are verified on a device.
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
package.loaded["ffi/blitbuffer"] = { Color8 = function(v) return v end }
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
package.loaded["ui/widget/overlapgroup"] = ctor()
package.loaded["ui/widget/container/rightcontainer"] = ctor()

local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, _secs, fn) scheduled[#scheduled + 1] = fn end,
}
package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_module_kit"] = {
    COLOR_MUTED = "muted", COLOR_PRIMARY = "primary",
    sc = function() return function(n) return n end end,
    face = function() return "FACE", false end,
    valueCard = function(o) return { card = true, heading = o.heading, value = o.value, sub = o.sub } end,
}

-- The database is faked through the loader's memo, keeping db.lua's
-- contract: books ordered by last_open DESC, id (NULLs last) and capped, each
-- with a sig, and page rows only for books whose sig is not in `known`.
local db_answer, db_calls, db_rows_for = nil, 0, {}
package.loaded["atlas/db"] = {
    fingerprintRows = function(limit, known)
        db_calls = db_calls + 1
        assert(limit == 6, "asks for at most six books")
        if db_answer == nil then return nil end
        known = known or {}
        local books = {}
        for i, b in ipairs(db_answer.books) do books[i] = b end
        table.sort(books, function(x, y)
            local xo, yo = x.last_open or -1, y.last_open or -1
            if xo ~= yo then return xo > yo end
            return x.id < y.id
        end)
        while #books > limit do table.remove(books) end
        local out, want = { books = {}, rows = {} }, {}
        db_rows_for = {}
        for _i, b in ipairs(books) do
            local n, secs, last = 0, 0, 0
            for _j, r in ipairs(db_answer.rows) do
                if r.id_book == b.id then
                    n = n + 1; secs = secs + r.secs
                    last = math.max(last, r.last_seen or r.day or 0)
                end
            end
            local sig = table.concat({ b.title, tostring(b.pages), tostring(b.last_open),
                n .. ":" .. secs .. ":" .. last }, "|")
            out.books[#out.books + 1] = { id = b.id, title = b.title, pages = b.pages,
                last_open = b.last_open, sig = sig }
            if known[b.id] ~= sig then want[b.id] = true; db_rows_for[#db_rows_for + 1] = b.id end
        end
        for _j, r in ipairs(db_answer.rows) do
            if want[r.id_book] then out.rows[#out.rows + 1] = r end
        end
        return out
    end,
}
local Source = dofile("micromodules/atlas/source.lua")
package.loaded["atlas/source"] = Source

-- The real fingerprint logic, with prepare() counted, to prove where it runs.
local F = dofile("micromodules/atlas/fingerprint.lua")
local real_prepare = F.prepare
local prepare_calls = 0
local in_render = false
F.prepare = function(...)
    prepare_calls = prepare_calls + 1
    assert(not in_render, "prepare() must not run inside render")
    return real_prepare(...)
end
package.loaded["atlas/fingerprint"] = F
local real_analyze = F.analyze
local analyze_calls = 0
F.analyze = function(...)
    analyze_calls = analyze_calls + 1
    return real_analyze(...)
end

local FP = dofile("micromodules/atlas_fingerprint.lua")
local raw_render = FP.render
FP.render = function(c)
    in_render = true
    local ok, out = pcall(raw_render, c)
    in_render = false
    if not ok then error(out, 0) end
    return out
end

local function runScheduled()
    local q = scheduled
    scheduled = {}
    for i = 1, #q do q[i]() end
end

local function settle(ctx)
    Source.reset()
    scheduled = {}
    FP.render(ctx)
    runScheduled()
    return FP.render(ctx)
end

local function ctx(extra)
    local c = { width = 300, height = 400, scale = 100, refresh = function() end }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local DAY = 86400
local NOW = os.time()

-- A finished book with a re-read, and one in progress opened today.
local function sample()
    local rows = {}
    for p = 1, 100 do
        rows[#rows + 1] = { id_book = 1, page = p, total_pages = 100, day = 1, secs = 60 }
    end
    for p = 40, 45 do
        rows[#rows + 1] = { id_book = 1, page = p, total_pages = 100, day = 2, secs = 60 }
    end
    for p = 1, 50 do
        rows[#rows + 1] = { id_book = 2, page = p, total_pages = 200, day = 3, secs = 90 }
    end
    return {
        books = {
            { id = 1, title = "Dom Casmurro", pages = 100, last_open = NOW - 40 * DAY },
            { id = 2, title = "Ficciones", pages = 200, last_open = NOW },
        },
        rows = rows,
    }
end

-- The card's children for book i: title line, span, strip, note, span.
local function bookParts(card, i)
    local base = 2 + (i - 1) * 5
    return { line = card[base + 1], strip = card[base + 3], note = card[base + 4] }
end

-- ── tests ──────────────────────────────────────────────────────────────────
t.test("the module declares a frozen key and a summary", function()
    eq(FP.key, "atlas_fingerprint")
    assert(type(FP.summary) == "string" and #FP.summary > 0)
end)

t.test("the first render is the loading card and queries off the paint path", function()
    Source.reset()
    scheduled = {}
    db_calls = 0
    eq(FP.render(ctx()).value, "Reading…")
    eq(db_calls, 0, "the database must not be read inside render")
    eq(#scheduled, 1)
end)

t.test("no database is the No statistics card", function()
    db_answer = nil
    eq(settle(ctx()).value, "No statistics")
end)

t.test("a database with no book over ten minutes is its own card", function()
    db_answer = { books = {}, rows = {} }
    local card = settle(ctx())
    eq(card.value, "Not enough reading yet")
end)

t.test("the Add picker never starts the query", function()
    Source.reset()
    scheduled = {}
    db_calls = 0
    eq(FP.render(ctx{ preview = true }).value, "Reading…")
    eq(#scheduled, 0)
end)

t.test("with data: heading, then title, strip and note per book, then legend", function()
    db_answer = sample()
    local card = settle(ctx())
    eq(card.card, nil, "must not be a valueCard")
    eq(card[1].text, "Atlas fingerprint")
    local first = bookParts(card, 1)
    eq(first.line[1].text, "Ficciones", "most recently opened first")
    eq(first.line[2][1].text, "1 h 15 min · 25%")
    assert(first.strip.levels, "the strip widget sits under the title")
    eq(first.strip.width, 300)
    eq(card[#card].text, "darker = longer per page · bar below = re-read")
end)

t.test("a finished book shows its pages, its re-read and no status", function()
    db_answer = sample()
    local second = bookParts(settle(ctx()), 2)
    eq(second.line[1].text, "Dom Casmurro")
    eq(second.line[2][1].text, "1 h 46 min · 100 p.")
    eq(second.note.text, "lingered on p. 36–45 (16 min) · re-read p. 40–45")
    assert(#second.strip.rereads == 1, "one re-read bar")
end)

t.test("a look at the last page keeps a book in progress, with an honest percentage", function()
    db_answer = sample()
    -- Ficciones, read to page 50 of 200, plus one look at page 200.
    db_answer.rows[#db_answer.rows + 1] =
        { id_book = 2, page = 200, total_pages = 200, day = 3, secs = 10 }
    local first = bookParts(settle(ctx()), 1)
    eq(first.line[2][1].text, "1 h 15 min · 25%")
    assert(first.note.text:find("· reading$"), first.note.text)
end)

t.test("a book in progress says reading; an old one says paused since", function()
    db_answer = sample()
    db_answer.books[2].last_open = NOW - 60 * DAY
    local card = settle(ctx())
    local note = bookParts(card, 2).note.text
    assert(note:find("paused since ", 1, true), note)
    db_answer = sample()
    local note2 = bookParts(settle(ctx()), 1).note.text
    assert(note2:find("· reading$"), note2)
end)

t.test("a book paused in an earlier year names the year", function()
    db_answer = sample()
    local last_year = os.date("*t", NOW).year - 1
    db_answer.books[2].last_open = os.time{ year = last_year, month = 3, day = 15, hour = 12 }
    local note = bookParts(settle(ctx()), 2).note.text
    assert(note:find("paused since Mar " .. last_year, 1, true), note)
end)

t.test("a book paused earlier this year names only the month", function()
    local y = os.date("*t", NOW).year
    local jan = os.time{ year = y, month = 1, day = 1, hour = 12 }
    if NOW - jan < 30 * DAY then return end -- too early in the year to pause
    db_answer = sample()
    db_answer.books[2].last_open = jan
    local note = bookParts(settle(ctx()), 2).note.text
    assert(note:find("paused since Jan$"), note)
end)

t.test("the status follows the clock, not the time of the first render", function()
    local real_time = os.time
    local fake_now = NOW
    os.time = function(t) if t then return real_time(t) end return fake_now end
    local ok, err = pcall(function()
        db_answer = sample()
        db_answer.books[2].last_open = NOW - 29 * DAY
        local c = ctx()
        local first = settle(c)
        -- Ficciones, opened 29 days ago, still sorts first.
        assert(bookParts(first, 1).note.text:find("· reading$"), "29 days: reading")
        -- Same query result, two days later: no new query, but a new status.
        fake_now = NOW + 2 * DAY
        local later = FP.render(c)
        local note = bookParts(later, 1).note.text
        assert(note:find("paused since ", 1, true), note)
    end)
    os.time = real_time
    if not ok then error(err, 0) end
end)

t.test("the analysis runs in the deferred query, once, never in render", function()
    db_answer = sample()
    prepare_calls = 0
    local c = ctx()
    settle(c)
    FP.render(c)
    FP.render(ctx{ width = 200 })
    eq(prepare_calls, 1)
end)

t.test("a book with no last_open is never called paused", function()
    db_answer = sample()
    db_answer.books[2].last_open = nil
    local card = settle(ctx())
    local found
    for i = 1, 2 do
        local parts = bookParts(card, i)
        if parts.line[1].text == "Ficciones" then found = parts.note.text end
    end
    assert(found, "Ficciones is on the card")
    assert(not found:find("paused", 1, true), found)
    assert(found:find("· reading$"), found)
end)

t.test("an hourly refresh with nothing new reuses the analysis and repaints nothing", function()
    db_answer = sample()
    analyze_calls = 0
    local repaints = 0
    local real_time = os.time
    local fake_now = real_time()
    os.time = function(tt) if tt then return real_time(tt) end return fake_now end
    local ok, err = pcall(function()
        local c = ctx{ refresh = function() repaints = repaints + 1 end }
        local first = settle(c)
        eq(repaints, 1, "the first load paints once")
        eq(analyze_calls, 2, "two books analyzed once")
        fake_now = fake_now + 3600
        FP.render(c)
        runScheduled()
        eq(db_rows_for, {}, "no page rows read for books nobody read")
        eq(analyze_calls, 2, "same data, no new analysis")
        eq(repaints, 1, "and no repaint")
        eq(FP.render(c)[3] ~= nil, true)
        -- Now the reader reads a page: the next refresh does analyze again.
        db_answer = sample()
        db_answer.rows[#db_answer.rows + 1] =
            { id_book = 2, page = 51, total_pages = 200, day = 4, secs = 90 }
        fake_now = fake_now + 3600
        FP.render(c)
        runScheduled()
        eq(db_rows_for, { 2 }, "rows only for the book read since")
        eq(analyze_calls, 3, "and only that book analyzed again")
        eq(repaints, 2)
        local _ = first
    end)
    os.time = real_time
    if not ok then error(err, 0) end
end)

t.test("time and pages go through gettext", function()
    local seen = {}
    local gettext = package.loaded["lib/bookshelf_i18n"].gettext
    package.loaded["lib/bookshelf_i18n"].gettext = function(s) seen[s] = true; return s end
    package.loaded["atlas/fingerprint"] = F
    local Fresh = dofile("micromodules/atlas_fingerprint.lua")
    db_answer = sample()
    Source.reset()
    scheduled = {}
    Fresh.render(ctx())
    runScheduled()
    in_render = true
    Fresh.render(ctx())
    in_render = false
    package.loaded["lib/bookshelf_i18n"].gettext = gettext
    for _i, key in ipairs({ "%d h %02d min", "%d p.", "%d%%" }) do
        assert(seen[key], key .. " is not translatable")
    end
end)

t.test("a one-page range reads 'p. 12', never 'p. 12–12'", function()
    db_answer = {
        books = { { id = 9, title = "Tiny", pages = 30, last_open = NOW } },
        rows = { { id_book = 9, page = 1, total_pages = 30, day = 1, secs = 600 } },
    }
    local note = bookParts(settle(ctx()), 1).note.text
    assert(note:find("lingered on p. 1 (10 min)", 1, true), note)
    assert(not note:find("1–1", 1, true), note)
end)

t.test("the strip paints with the grid's greys: one table through the loader", function()
    db_answer = sample()
    local strip = bookParts(settle(ctx()), 1).strip
    local ink = package.loaded["atlas/ink"]
    assert(ink, "atlas/ink is loaded through the loader")
    assert(rawequal(strip.ink, ink), "the strip got the loader's table")
    eq(ink, dofile("micromodules/atlas/ink.lua"))
end)

t.test("too short for one book and the legend: the legend goes", function()
    db_answer = sample()
    -- heading 10 + span 6 + legend 10 = 26; one book is 55. 26 + 55 - 1 is
    -- one pixel short of a book with the legend, but room without it.
    local card = settle(ctx{ height = 26 + 55 - 1 })
    eq((#card - 2) / 5, 1, "one book")
    assert(card[#card].text ~= "darker = longer per page · bar below = re-read",
        "no legend")
end)

t.test("29 of 100 pages reads 29%, not 28%", function()
    db_answer = { books = { { id = 5, title = "B", pages = 100, last_open = NOW } }, rows = {} }
    for p = 1, 29 do
        db_answer.rows[#db_answer.rows + 1] = { id_book = 5, page = p, total_pages = 100, day = 1, secs = 60 }
    end
    local line = bookParts(settle(ctx()), 1).line[2][1].text
    assert(line:find("· 29%", 1, true), line)
end)

t.test("a book only skimmed names no stretch it lingered on", function()
    db_answer = { books = { { id = 6, title = "Skim", pages = 600, last_open = NOW } }, rows = {} }
    for p = 1, 600 do
        db_answer.rows[#db_answer.rows + 1] = { id_book = 6, page = p, total_pages = 600, day = 1, secs = 1 }
    end
    local note = bookParts(settle(ctx()), 1).note.text
    assert(not note:find("lingered", 1, true), note)
end)

t.test("a book turning 'paused' with no new data still repaints the card", function()
    local real_time = os.time
    local fake_now = real_time()
    os.time = function(tt) if tt then return real_time(tt) end return fake_now end
    local ok, err = pcall(function()
        db_answer = sample()
        db_answer.books[2].last_open = fake_now - 30 * DAY + 1800 -- 29 d 23.5 h
        local repaints = 0
        local c = ctx{ refresh = function() repaints = repaints + 1 end }
        local first = settle(c)
        assert(bookParts(first, 1).note.text:find("· reading$"), "still reading")
        eq(repaints, 1)
        fake_now = fake_now + 3600 -- past 30 days, nothing read
        FP.render(c)
        runScheduled()
        eq(repaints, 2, "the status changed, so the card is redrawn")
        local note = bookParts(FP.render(c), 1).note.text
        assert(note:find("paused since ", 1, true), note)
        eq(db_rows_for, {}, "and still no page rows were read")
    end)
    os.time = real_time
    if not ok then error(err, 0) end
end)

t.test("on 1 January a paused book's note gains the year, and the card repaints", function()
    local real_time = os.time
    local y = os.date("*t").year
    local fake_now = real_time{ year = y, month = 12, day = 31, hour = 12 }
    os.time = function(tt) if tt then return real_time(tt) end return fake_now end
    local ok, err = pcall(function()
        db_answer = sample()
        db_answer.books[2].last_open = real_time{ year = y, month = 3, day = 10, hour = 12 }
        local repaints = 0
        local c = ctx{ refresh = function() repaints = repaints + 1 end }
        settle(c)
        eq(repaints, 1)
        fake_now = real_time{ year = y + 1, month = 1, day = 1, hour = 13 }
        FP.render(c)
        runScheduled()
        eq(repaints, 2, "the note's text changed, so the card is redrawn")
        local found
        for i = 1, 2 do
            local n = bookParts(FP.render(c), i).note.text
            if n:find("paused since", 1, true) then found = n end
        end
        assert(found and found:find("Mar " .. y, 1, true), tostring(found))
    end)
    os.time = real_time
    if not ok then error(err, 0) end
end)

t.test("as many books as the height allows, at least one", function()
    db_answer = sample()
    -- heading 10 + span 6 + legend 10 = 26; a book is 10+2+20+2+4+10+7 = 55.
    local function books(card) return (#card - 3) / 5 end
    eq(books(settle(ctx{ height = 26 + 55 })), 1)
    eq(books(settle(ctx{ height = 26 + 110 })), 2)
    -- Far too short: one book, no legend, and the host shrinks the scale.
    eq((#settle(ctx{ height = 5 }) - 2) / 5, 1)
end)

t.test("rendering twice at the same width reuses the layout", function()
    db_answer = sample()
    local c = ctx()
    local a = settle(c)
    local b = FP.render(c)
    eq(bookParts(a, 1).strip.levels == bookParts(b, 1).strip.levels, true)
end)

t.done()
