-- The fingerprint's logic: where time goes along a book, re-reads, the slowest
-- stretch, status. Pure Lua; no KOReader stubs needed.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

local F = dofile("micromodules/atlas/fingerprint.lua")
local Scale = dofile("micromodules/atlas/scale.lua")

-- Everything goes through analyze(), the one entry point prepare() uses, so
-- these tests pin down what the card shows.
local function progress(rows, pages) return F.analyze(rows, pages).progress end
local function rereads(rows, pages) return F.analyze(rows, pages).rereads end
local function slowest(rows, pages) return F.analyze(rows, pages).slowest end

local DAY = 86400

local function row(page, total, day, secs, id)
    return { id_book = id or 1, page = page, total_pages = total, day = day, secs = secs }
end

local function near(got, want, msg)
    if math.abs(got - want) > 1e-6 then
        error(("%s: got %s, want %s"):format(msg or "near", tostring(got), tostring(want)), 0)
    end
end

-- ── buckets ────────────────────────────────────────────────────────────────
t.test("one page per bucket lands whole in its bucket", function()
    local secs, read = F.buckets({ row(3, 10, 0, 60) }, 10)
    eq(secs[3], 60)
    eq(read[3], true)
    eq(read[2], nil)
    eq(read[4], nil)
end)

t.test("a row wider than a bucket spreads evenly across the buckets it covers", function()
    -- page 1 of 2 is [0, .5): buckets 1..5 of 10, 20 s each.
    local secs = F.buckets({ row(1, 2, 0, 100) }, 10)
    for k = 1, 5 do near(secs[k], 20, "bucket " .. k) end
    eq(secs[6], 0)
end)

t.test("rows narrower than a bucket add up inside it", function()
    -- pages 1..4 of 40 all sit in bucket 1 of 10.
    local rows = {}
    for p = 1, 4 do rows[p] = row(p, 40, 0, 30) end
    local secs = F.buckets(rows, 10)
    eq(secs[1], 120)
    eq(secs[2], 0)
end)

t.test("a row straddling two buckets splits by overlap", function()
    -- page 2 of 3 is [1/3, 2/3); over 2 buckets that is half in each.
    local secs = F.buckets({ row(2, 3, 0, 90) }, 2)
    near(secs[1], 45)
    near(secs[2], 45)
end)

t.test("reflow: the same stretch read under two layouts lands in the same place", function()
    -- page 50 of 200 and page 75 of 300 are both [0.245, 0.25) and [0.2467, 0.25).
    local _a, ra = F.buckets({ row(50, 200, 0, 60) }, 100)
    local _b, rb = F.buckets({ row(75, 300, 0, 60) }, 100)
    eq(ra, rb)
end)

t.test("a row with no layout is ignored, not a crash", function()
    local secs, read = F.buckets({ row(5, 0, 0, 60), row(5, nil, 0, 60) }, 10)
    eq(read, {})
    eq(secs[1], 0)
end)

t.test("a page past the end of its layout is clamped to the last page", function()
    local _s, read = F.buckets({ row(12, 10, 0, 60) }, 10)
    eq(read[10], true)
end)

-- ── density ────────────────────────────────────────────────────────────────
t.test("seconds per page do not depend on how long the book is", function()
    -- Two books read at 60 s/page; one has 100 pages, the other 400.
    local short, long = {}, {}
    for p = 1, 100 do short[p] = row(p, 100, 0, 60) end
    for p = 1, 400 do long[p] = row(p, 400, 0, 60) end
    local ds = F.density(short, 50, 100)
    local dl = F.density(long, 50, 400)
    near(ds[25], 60)
    near(dl[25], 60)
end)

t.test("unread buckets have no density at all", function()
    local d = F.density({ row(1, 10, 0, 60) }, 10, 10)
    near(d[1], 60)
    eq(d[2], nil)
end)

-- ── rereads ────────────────────────────────────────────────────────────────
t.test("going back to an earlier stretch on a later day is a re-read", function()
    local rows = {}
    for p = 1, 100 do rows[#rows + 1] = row(p, 100, 1, 60) end
    -- Day 2: back to pages 20..29.
    for p = 20, 29 do rows[#rows + 1] = row(p, 100, 2, 60) end
    eq(rereads(rows, 100), { { from = 20, to = 29 } })
end)

t.test("the page where one session ends and the next begins is not a re-read", function()
    local rows = {}
    for p = 1, 30 do rows[#rows + 1] = row(p, 100, 1, 60) end
    for p = 30, 60 do rows[#rows + 1] = row(p, 100, 2, 60) end
    eq(rereads(rows, 100), {})
end)

t.test("coming back from less than the lead is not a re-read", function()
    local rows = {}
    for p = 1, 33 do rows[#rows + 1] = row(p, 100, 1, 60) end
    -- Back 3 pages (3%): flipping back to check a name.
    for p = 30, 40 do rows[#rows + 1] = row(p, 100, 2, 60) end
    eq(rereads(rows, 100), {})
end)

t.test("a stretch jumped past but never read is not re-read when first read", function()
    local rows = {}
    for p = 1, 10 do rows[#rows + 1] = row(p, 100, 1, 60) end
    -- Day 1 also peeks at the last page (endnotes), far ahead.
    rows[#rows + 1] = row(100, 100, 1, 20)
    -- Day 2 reads on from 11 for the first time.
    for p = 11, 30 do rows[#rows + 1] = row(p, 100, 2, 60) end
    eq(rereads(rows, 100), {})
end)

t.test("neighbouring re-read buckets merge into one interval", function()
    local rows = {}
    for p = 1, 100 do rows[#rows + 1] = row(p, 100, 1, 60) end
    for p = 10, 14 do rows[#rows + 1] = row(p, 100, 2, 60) end
    for p = 15, 19 do rows[#rows + 1] = row(p, 100, 3, 60) end
    for p = 50, 52 do rows[#rows + 1] = row(p, 100, 3, 60) end
    eq(rereads(rows, 100), { { from = 10, to = 19 }, { from = 50, to = 52 } })
end)

t.test("a re-read with a page skipped is still one re-read", function()
    local rows = {}
    for p = 1, 100 do rows[#rows + 1] = row(p, 100, 1, 60) end
    -- Back to 20..30 on day 2, skipping 25: 1% of a 100-page book is bridged.
    for p = 20, 30 do
        if p ~= 25 then rows[#rows + 1] = row(p, 100, 2, 60) end
    end
    eq(rereads(rows, 100), { { from = 20, to = 30 } })
end)

t.test("a gap wider than the bridge keeps two re-reads apart", function()
    local rows = {}
    for p = 1, 100 do rows[#rows + 1] = row(p, 100, 1, 60) end
    for p = 20, 30 do
        if p ~= 25 and p ~= 26 then rows[#rows + 1] = row(p, 100, 2, 60) end
    end
    eq(rereads(rows, 100), { { from = 20, to = 24 }, { from = 27, to = 30 } })
end)

t.test("largest picks the widest interval, the first on a tie", function()
    eq(F.largest({ { from = 1, to = 3 }, { from = 10, to = 20 }, { from = 30, to = 40 } }),
        { from = 10, to = 20 })
    eq(F.largest({}), nil)
end)

t.test("toBuckets converts page intervals to strip buckets", function()
    eq(F.toBuckets({ from = 11, to = 30 }, 100, 10), { from = 2, to = 3 })
    eq(F.toBuckets({ from = 1, to = 1 }, 100, 1000), { from = 1, to = 10 })
    eq(F.toBuckets({ from = 100, to = 100 }, 100, 10), { from = 10, to = 10 })
end)

-- ── review findings (PR #5) ────────────────────────────────────────────────
t.test("a look at the end of the book does not turn session starts into re-reads", function()
    -- Day 1: pages 1..50 of 300, and a glance at page 300 (the contents).
    local rows = {}
    for p = 1, 50 do rows[#rows + 1] = row(p, 300, 1, 60) end
    rows[#rows + 1] = row(300, 300, 1, 20)
    -- Day 2: resumes at page 50 and reads on.
    for p = 50, 120 do rows[#rows + 1] = row(p, 300, 2, 60) end
    eq(rereads(rows, 300), {})
end)

t.test("flipping back past pages is not re-reading them", function()
    local rows = {}
    for p = 1, 100 do rows[#rows + 1] = row(p, 100, 1, 60) end
    -- Day 2: pages back to 20 at a second each, looking for a passage.
    for p = 20, 40 do rows[#rows + 1] = row(p, 100, 2, 1) end
    eq(rereads(rows, 100), {})
end)

t.test("paging through to the end at a second a page does not finish a book", function()
    local rows = {}
    for p = 1, 120 do rows[#rows + 1] = row(p, 300, 1, 60) end
    for p = 121, 300 do rows[#rows + 1] = row(p, 300, 1, 1) end
    near(progress(rows, 300), 120 / 300)
    eq(F.status(progress(rows, 300), 0, 0), "reading")
end)

t.test("floating point does not spill a page into its neighbours", function()
    -- (7 - 1) / 25 * 25 and 7 / 25 * 25 are not exact in binary.
    local _s, read = F.buckets({ row(7, 25, 0, 60) }, 25)
    eq(read, { [7] = true })
    local _s2, read2 = F.buckets({ row(27, 46, 0, 60) }, 46)
    eq(read2, { [27] = true })
    near(progress({ row(1, 46, 0, 60), row(27, 46, 0, 60) }, 46), 1 / 46)
end)

t.test("no page of any size spills into a neighbour", function()
    for tp = 1, 400 do
        for p = 1, tp do
            local _s, read = F.buckets({ row(p, tp, 0, 60) }, tp)
            local n = 0
            for _k in pairs(read) do n = n + 1 end
            if n ~= 1 or not read[p] then
                error(("page %d of %d touched %d buckets"):format(p, tp, n), 0)
            end
        end
    end
end)

t.test("one page of an older, smaller-font layout does not finish a book", function()
    -- Read 1..200 of the current 450 pages, then one look at the last page
    -- of the old 100-page layout, which spans current pages 446..450.
    local rows = {}
    for p = 1, 200 do rows[#rows + 1] = row(p, 450, 1, 60) end
    rows[#rows + 1] = row(100, 100, 2, 60)
    near(progress(rows, 450), 200 / 450)
end)

t.test("the ending read in an older layout still finishes the book", function()
    local rows = {}
    for p = 1, 98 do rows[#rows + 1] = row(p, 100, 1, 120) end
    rows[#rows + 1] = row(99, 100, 2, 120)
    rows[#rows + 1] = row(100, 100, 2, 120)
    near(progress(rows, 450), 1)
end)

t.test("with no page count, the newest layout wins even within one day", function()
    local book = { id = 1, pages = 0 }
    local a = { page = 1, total_pages = 300, day = 5, last_seen = 1000 }
    local b = { page = 1, total_pages = 450, day = 5, last_seen = 2000 }
    eq(F.currentPages(book, { a, b }), 450)
    eq(F.currentPages(book, { b, a }), 450)
end)

t.test("prepare computes re-reads and the slowest stretch once, outside layout", function()
    local d = { books = { { id = 1, title = "B", pages = 100, last_open = 0 } }, rows = {} }
    for p = 1, 100 do d.rows[#d.rows + 1] = row(p, 100, 1, 60) end
    for p = 40, 45 do d.rows[#d.rows + 1] = row(p, 100, 2, 60) end
    local b = F.prepare(d).books[1]
    eq(b.rereads, { { from = 40, to = 45 } })
    eq(b.reread_pages, { from = 40, to = 45 })
    assert(b.slowest, "slowest computed in prepare")
end)

t.test("layout lays out only the books the card shows", function()
    local d = { books = {}, rows = {} }
    for i = 1, 4 do
        d.books[i] = { id = i, title = "B" .. i, pages = 10, last_open = i }
        d.rows[#d.rows + 1] = row(1, 10, 0, 60, i)
    end
    local prep = F.prepare(d)
    eq(#F.layout(prep, 10, Scale, 2), 2)
    eq(#F.layout(prep, 10, Scale), 4)
end)

-- ── slowest ────────────────────────────────────────────────────────────────
t.test("the slowest window is found where the time went", function()
    local rows = {}
    for p = 1, 200 do
        local s = (p >= 61 and p <= 70) and 300 or 60
        rows[p] = row(p, 200, 0, s)
    end
    local s = slowest(rows, 200)
    eq(s.from, 61)
    eq(s.to, 70)
    near(s.secs, 3000)
end)

t.test("the window is 2% of a long book", function()
    local rows = {}
    for p = 1, 1000 do rows[p] = row(p, 1000, 0, 60) end
    local s = slowest(rows, 1000)
    eq(s.to - s.from + 1, 20)
    eq(s.from, 1, "a flat book ties everywhere; the first wins")
end)

t.test("a book read less than one window uses what was read", function()
    local s = slowest({ row(1, 300, 0, 60), row(2, 300, 0, 60), row(3, 300, 0, 60) }, 300)
    eq(s.from, 1)
    eq(s.to, 3)
    near(s.secs, 180)
end)

t.test("the window never reaches into unread pages", function()
    local rows = {}
    for p = 1, 50 do rows[p] = row(p, 100, 0, 60) end
    local s = slowest(rows, 100)
    assert(s.to <= 50, "window ends at " .. s.to)
end)

t.test("nothing read, no slowest window", function()
    eq(slowest({}, 100), nil)
end)

-- ── status ─────────────────────────────────────────────────────────────────
t.test("finished from 97% on, whatever the date", function()
    eq(F.status(0.97, 0, 100 * DAY), "finished")
    eq(F.status(1.0, 0, 100 * DAY), "finished")
end)

t.test("not finished: reading within 30 days, paused after", function()
    local now = 100 * DAY
    eq(F.status(0.5, now - 29 * DAY, now), "reading")
    eq(F.status(0.5, now - 30 * DAY, now), "paused")
end)

-- ── prepare ────────────────────────────────────────────────────────────────
-- In the order db.fingerprintRows returns books: last_open DESC.
local function data()
    return {
        books = {
            { id = 2, title = "New", pages = 0, last_open = 50 * DAY, sig = "n1" },
            { id = 1, title = "Old", pages = 100, last_open = 10 * DAY, sig = "o1" },
            { id = 3, title = "No rows", pages = 100, last_open = 5 * DAY, sig = "x1" },
        },
        rows = {
            row(1, 100, 1, 60, 1), row(100, 100, 2, 60, 1),
            row(10, 80, 3, 120, 2), row(20, 200, 4, 30, 2),
        },
    }
end

t.test("prepare keeps the database's order and drops books without rows", function()
    local p = F.prepare(data())
    eq(#p.books, 2)
    eq(p.books[1].title, "New")
    eq(p.books[2].title, "Old")
end)

t.test("prepare totals the time; page 1 and a look at the last page is not finished", function()
    local p = F.prepare(data())
    local old = p.books[2]
    eq(old.secs, 120)
    near(old.progress, 0.01)
    eq(F.status(old.progress, old.last_open, 60 * DAY), "paused",
        "opened 50 days ago and only started")
end)

-- ── progress ───────────────────────────────────────────────────────────────
local function readPages(from, to, total, day)
    local rows = {}
    for p = from, to do rows[#rows + 1] = row(p, total, day or 0, 60) end
    return rows
end

t.test("progress: reading to the end finishes the book", function()
    local rows = readPages(1, 100, 100)
    near(progress(rows, 100), 1)
    eq(F.status(progress(rows, 100), 0, 0), "finished")
end)

t.test("progress: one look at the last page does not move it", function()
    local rows = readPages(1, 30, 100)
    rows[#rows + 1] = row(100, 100, 0, 15)
    near(progress(rows, 100), 0.30)
end)

t.test("progress: a few pages peeked at the back do not count either", function()
    local rows = readPages(1, 40, 500)
    -- Endnotes: pages 480, 482 and 490.
    rows[#rows + 1] = row(480, 500, 0, 30)
    rows[#rows + 1] = row(482, 500, 0, 30)
    rows[#rows + 1] = row(490, 500, 0, 30)
    near(progress(rows, 500), 40 / 500)
end)

t.test("progress: skipping an appendix still finishes the book", function()
    -- Read 1..80, skip 81..95, read 96..100: not 80% coverage of the end,
    -- but the ending was read.
    local rows = readPages(1, 80, 100)
    for _i, r in ipairs(readPages(96, 100, 100)) do rows[#rows + 1] = r end
    near(progress(rows, 100), 1)
end)

t.test("progress: a short start counts from the first page", function()
    near(progress(readPages(1, 2, 100), 100), 0.02)
    eq(progress({}, 100), 0)
end)

t.test("progress: works across a re-pagination", function()
    -- First half at 200 pages, second half after a font change at 300.
    local rows = readPages(1, 100, 200)
    for _i, r in ipairs(readPages(151, 300, 300)) do rows[#rows + 1] = r end
    near(progress(rows, 300), 1)
end)

t.test("prepare keeps a missing last_open as nil", function()
    local d = data()
    d.books[2].last_open = nil
    local p = F.prepare(d)
    eq(p.books[2].title, "Old")
    eq(p.books[2].last_open, nil)
    eq(F.status(p.books[2].progress, p.books[2].last_open, 60 * DAY), "reading")
end)

t.test("a book with no page count takes its most recent layout", function()
    local p = F.prepare(data())
    eq(p.books[1].pages, 200)
end)

t.test("prepare does not re-sort or re-cap: the query owns both", function()
    local d = { books = {}, rows = {} }
    for i = 1, 8 do
        d.books[i] = { id = i, title = "B" .. i, pages = 10, last_open = i }
        d.rows[i] = row(1, 10, 0, 60, i)
    end
    local p = F.prepare(d)
    eq(#p.books, 8)
    eq(p.books[1].title, "B1")
end)

-- ── reuse across refreshes ─────────────────────────────────────────────────
t.test("an unchanged book without rows reuses its earlier analysis", function()
    local first = F.prepare(data())
    local again = { books = data().books, rows = {} } -- nobody read since
    local p = F.prepare(again, first)
    assert(rawequal(p, first), "nothing changed: the old answer itself comes back")
end)

t.test("a changed book is analyzed again, the rest reused", function()
    local first = F.prepare(data())
    local d = data()
    d.books[1].sig = "n2" -- "New" was read
    d.rows = { row(10, 80, 3, 120, 2), row(20, 200, 4, 30, 2), row(21, 200, 5, 60, 2) }
    local p = F.prepare(d, first)
    assert(not rawequal(p, first))
    assert(not rawequal(p.books[1], first.books[1]), "New analyzed again")
    assert(rawequal(p.books[2], first.books[2]), "Old reused as is")
    eq(p.books[1].secs, 210)
end)

t.test("a book without a sig is never taken for unchanged", function()
    local d = data()
    for _i, b in ipairs(d.books) do b.sig = nil end
    local first = F.prepare(d)
    local again = { books = d.books, rows = {} }
    eq(#F.prepare(again, first).books, 0, "no rows and no sig: nothing to show")
end)

-- ── layout ─────────────────────────────────────────────────────────────────
t.test("layout shares one scale across books, so a slow book reads darker", function()
    local d = { books = {
        { id = 1, title = "Easy", pages = 100, last_open = 2 },
        { id = 2, title = "Hard", pages = 100, last_open = 1 },
    }, rows = {} }
    for p = 1, 100 do
        d.rows[#d.rows + 1] = row(p, 100, 0, 30 + p % 7, 1)
        d.rows[#d.rows + 1] = row(p, 100, 0, 300 + p % 7, 2)
    end
    local strips = F.layout(F.prepare(d), 50, Scale)
    local easy, hard = strips[1].levels, strips[2].levels
    for k = 1, 50 do
        assert(easy[k] <= 2, "easy bucket " .. k .. " is " .. tostring(easy[k]))
        assert(hard[k] >= 3, "hard bucket " .. k .. " is " .. tostring(hard[k]))
    end
end)

t.test("layout: flipped-past stretches are step 0, unread are nil", function()
    local d = { books = { { id = 1, title = "B", pages = 10, last_open = 0 } }, rows = {
        row(1, 10, 0, 60), row(2, 10, 0, 2), row(3, 10, 0, 60),
    } }
    local s = F.layout(F.prepare(d), 10, Scale)[1]
    eq(s.levels[2], 0)
    assert(s.levels[1] >= 1)
    eq(s.levels[4], nil)
end)

t.test("layout names the re-read in pages and the slowest stretch", function()
    local d = { books = { { id = 1, title = "B", pages = 100, last_open = 0 } }, rows = {} }
    for p = 1, 100 do d.rows[#d.rows + 1] = row(p, 100, 1, 60) end
    for p = 40, 45 do d.rows[#d.rows + 1] = row(p, 100, 2, 60) end
    local s = F.layout(F.prepare(d), 50, Scale)[1]
    eq(s.reread_pages, { from = 40, to = 45 })
    eq(s.rereads, { { from = 20, to = 23 } })
    eq(s.slowest.from, 36, "the re-read stretch is where the most time went")
end)

-- ── review findings, round 2 ───────────────────────────────────────────────
t.test("a stretch skimmed first and read properly later is not a re-read", function()
    local rows = {}
    -- Day 1: flips through 51..69 (skipping a chapter), reads 1..50 and 70..200.
    for p = 1, 50 do rows[#rows + 1] = row(p, 200, 1, 60) end
    for p = 51, 69 do rows[#rows + 1] = row(p, 200, 1, 1) end
    for p = 70, 200 do rows[#rows + 1] = row(p, 200, 1, 60) end
    -- Day 5: goes back and reads 51..69 for the first time.
    for p = 51, 69 do rows[#rows + 1] = row(p, 200, 5, 60) end
    eq(rereads(rows, 200), {})
end)

t.test("an out-of-range page is the same source as the page it clamps to", function()
    -- In an old 60-page layout, page 60 covers current pages 296..300 of 300,
    -- so it fills the half rule alone; recorded again as page 61 (clamped to
    -- 60), it must still be ONE source, and one look must not finish a book.
    local rows = {}
    for p = 1, 100 do rows[#rows + 1] = row(p, 300, 1, 60) end
    rows[#rows + 1] = row(60, 60, 2, 300)
    rows[#rows + 1] = row(61, 60, 3, 300)
    near(progress(rows, 300), 100 / 300)
end)

-- A brute-force frontier, straight from the definition, to hold the
-- incremental one to.
local function bruteProgress(rows, pages)
    local secs, starts, spans, seen = {}, {}, {}, {}
    for p = 1, pages do secs[p] = 0; starts[p] = 0 end
    for _i, r in ipairs(rows) do
        local tp = r.total_pages
        local pg = math.max(1, math.min(r.page, tp))
        local a, b = (pg - 1) / tp * pages, pg / tp * pages
        local first, last
        for k = math.floor(a) + 1, math.min(pages, math.ceil(b)) do
            local ov = math.min(b, k) - math.max(a, k - 1)
            if ov > 1e-9 then
                -- Only visits long enough to be reading count toward "read".
                if r.secs / (r.visits or 1) >= F.SKIM_SECS then
                    secs[k] = secs[k] + r.secs * ov / (b - a)
                end
                first = first or k; last = k
            end
        end
        local key = pg .. ":" .. tp
        if first and not seen[key] then
            seen[key] = true
            starts[first] = starts[first] + 1
            spans[#spans + 1] = { first, last }
        end
    end
    local w = math.max(5, math.ceil(pages * F.PROGRESS_WINDOW))
    local thr = F.threshold(rows, pages)
    local best = 0
    for p = 1, pages do
        if secs[p] >= thr then
            local lo = math.max(1, p - w + 1)
            local reads, sources = 0, 0
            for q = lo, p do if secs[q] >= thr then reads = reads + 1 end end
            for _i, sp in ipairs(spans) do
                if sp[1] <= p and sp[2] >= lo then sources = sources + 1 end
            end
            if reads >= math.ceil((p - lo + 1) / 2) and sources >= math.min(2, p - lo + 1) then
                best = p
            end
        end
    end
    return best / pages
end

t.test("the incremental frontier matches the definition, day after day", function()
    math.randomseed(7)
    for trial = 1, 40 do
        local pages = math.random(20, 400)
        local rows = {}
        for d = 1, math.random(1, 25) do
            local tp = (math.random() < 0.3) and math.random(10, 600) or pages
            local from = math.random(1, tp)
            for p = from, math.min(tp, from + math.random(0, 30)) do
                local paces = { 2, 4, 8, 12, 20, 60, 90, 150 }
                local r = row(p, tp, d, paces[math.random(1, #paces)])
                if math.random() < 0.2 then r.visits = math.random(2, 4) end
                rows[#rows + 1] = r
            end
            -- The incremental pass sees days in order; check it each day.
            local got = F.analyze(rows, pages).progress
            local want = bruteProgress(rows, pages)
            if math.abs(got - want) > 1e-9 then
                error(("trial %d day %d: got %s, want %s"):format(trial, d, got, want), 0)
            end
        end
    end
end)

-- ── review findings, round 4 ───────────────────────────────────────────────
t.test("a run of endnote look-ups does not move progress", function()
    -- 400 pages read at a minute a page; on day 1, pages 1..40, plus eight
    -- endnote look-ups of 10 s landing on 350..354.
    local rows = {}
    for p = 1, 40 do rows[#rows + 1] = row(p, 400, 1, 60) end
    for _i, p in ipairs({ 350, 351, 351, 352, 353, 353, 354, 354 }) do
        rows[#rows + 1] = row(p, 400, 1, 10)
    end
    -- Day 2 resumes at page 40.
    for p = 40, 80 do rows[#rows + 1] = row(p, 400, 2, 60) end
    local an = F.analyze(rows, 400)
    near(an.progress, 80 / 400)
    eq(an.rereads, {}, "resuming is not re-reading")
end)

t.test("the threshold follows the reader's pace, never below SKIM_SECS", function()
    local slow, fast = {}, {}
    for p = 1, 50 do slow[p] = row(p, 50, 0, 120) end
    for p = 1, 50 do fast[p] = row(p, 50, 0, 8) end
    near(F.threshold(slow, 50), 30)
    near(F.threshold(fast, 50), F.SKIM_SECS)
    -- The pace is per CURRENT page: a row of an old 25-page layout spans two.
    near(F.threshold({ row(1, 25, 0, 240) }, 50), 120 * F.LOOKUP_FRACTION)
end)

t.test("a bucket half read is measured over the page read, not its width", function()
    -- 10 pages over 6 buckets: bucket 1 is pages [0, 1.67). Only page 1 read,
    -- at 6 s: 6 s per page, not 6 / 1.67.
    local d = F.density({ row(1, 10, 0, 6) }, 6, 10)
    near(d[1], 6)
end)

t.test("a re-read page is darker, not diluted, at the same width", function()
    local d = F.density({ row(1, 10, 0, 30), row(1, 10, 1, 30) }, 10, 10)
    near(d[1], 60)
end)

t.test("a look-up near the end every day does not rescan the book", function()
    local rows = {}
    for d = 1, 300 do
        for p = (d - 1) * 4 + 1, d * 4 do rows[#rows + 1] = row(p, 1500, d, 60) end
        rows[#rows + 1] = row(1400 + d % 90, 1500, d, 10)
    end
    local t0 = os.clock()
    F.analyze(rows, 1500)
    local spent = os.clock() - t0
    assert(spent < 0.5, ("took %.3f s"):format(spent))
end)

-- ── review findings, round 5 ───────────────────────────────────────────────
t.test("the strip calls 'read' what progress calls read, by the book's threshold", function()
    -- Read 1..70 at 80 s a page (median 80, threshold 20 s), then paged to
    -- the end at 10 s: above SKIM_SECS, below this reader's threshold.
    local d = { books = { { id = 1, title = "B", pages = 100, last_open = 0 } }, rows = {} }
    for p = 1, 70 do d.rows[#d.rows + 1] = row(p, 100, 1, 80) end
    for p = 71, 100 do d.rows[#d.rows + 1] = row(p, 100, 1, 10) end
    local s = F.layout(F.prepare(d), 100, Scale)[1]
    near(s.book.threshold, 20)
    near(s.book.progress, 0.70)
    for k = 71, 100 do eq(s.levels[k], 0, "bucket " .. k .. " is only touched") end
    assert(s.levels[20] >= 1)
end)

t.test("a page read over two short sessions counts as read, and its re-read shows", function()
    -- Threshold 15 s (median 60). Page 40 gets 10 s on day 1 and 10 s on
    -- day 2: read in total. The reader moves on, then re-reads 40..45 on day 30.
    local rows = {}
    for p = 1, 39 do rows[#rows + 1] = row(p, 100, 1, 60) end
    rows[#rows + 1] = row(40, 100, 1, 10)
    rows[#rows + 1] = row(40, 100, 2, 10)
    for p = 41, 80 do rows[#rows + 1] = row(p, 100, 2, 60) end
    for p = 40, 45 do rows[#rows + 1] = row(p, 100, 30, 60) end
    eq(rereads(rows, 100), { { from = 40, to = 45 } })
end)

-- ── review findings, round 6 ───────────────────────────────────────────────
t.test("flipping through the rest twice does not finish a book", function()
    -- 300 pages: 1..100 read at 60 s; 101..300 flipped at 3 s on day 2 and
    -- again on day 3. Flips are most of the rows but little of the time.
    local rows = {}
    for p = 1, 100 do rows[#rows + 1] = row(p, 300, 1, 60) end
    for d = 2, 3 do
        for p = 101, 300 do rows[#rows + 1] = row(p, 300, d, 3) end
    end
    near(F.threshold(rows, 300), 15, "the pace where the time went: 60 s")
    local an = F.analyze(rows, 300)
    near(an.progress, 100 / 300)
    eq(F.status(an.progress, 0, 0), "reading")
end)

t.test("a short book bridges a re-read that skips every other page", function()
    -- 80 pages: bridge is at least one page, not floor(0.8) = 0.
    local rows = {}
    for p = 1, 80 do rows[#rows + 1] = row(p, 80, 1, 60) end
    for p = 10, 30, 2 do rows[#rows + 1] = row(p, 80, 2, 60) end
    eq(rereads(rows, 80), { { from = 10, to = 30 } })
end)

-- ── review findings, round 8 ───────────────────────────────────────────────
t.test("a page read on three days covers one page, not three", function()
    -- 100 pages on 10 buckets: page 1 read 60 s on each of 3 days is 180 s
    -- on one page -- the same as one 180 s row.
    local three = { row(1, 100, 1, 60), row(1, 100, 2, 60), row(1, 100, 3, 60) }
    near(F.density(three, 10, 100)[1], 180)
    near(F.density({ row(1, 100, 1, 180) }, 10, 100)[1], 180)
end)

t.test("skims below SKIM_SECS a visit never add up to a page read", function()
    -- Pages 1..30 read at 30 s (threshold 7.5). Pages 31..100 paged through
    -- at 4 s on two days: 8 s a page in total, but no visit was reading.
    local rows = {}
    for p = 1, 30 do rows[#rows + 1] = row(p, 100, 1, 30) end
    for d = 2, 3 do
        for p = 31, 100 do rows[#rows + 1] = row(p, 100, d, 4) end
    end
    near(F.analyze(rows, 100).progress, 0.30)
end)

t.test("paging to the end and back on the same day is two flips, not a read", function()
    local rows = {}
    for p = 1, 30 do rows[#rows + 1] = row(p, 100, 1, 30) end
    for p = 31, 100 do
        local r = row(p, 100, 1, 8)
        r.visits = 2
        rows[#rows + 1] = r
    end
    near(F.analyze(rows, 100).progress, 0.30)
end)

t.test("two real visits on one day still add up", function()
    -- 20 s over two visits of 10 s is reading (10 >= SKIM_SECS).
    local rows = {}
    for p = 1, 50 do
        local r = row(p, 100, 1, 20)
        r.visits = 2
        rows[#rows + 1] = r
    end
    near(F.analyze(rows, 100).progress, 0.50)
end)

t.test("after a refresh, only the changed book's strip is spread again", function()
    local first = F.prepare(data())
    F.layout(first, 50, Scale)
    local d = data()
    d.books[1].sig = "n2"
    d.rows = { row(10, 80, 3, 120, 2), row(20, 200, 4, 30, 2), row(21, 200, 5, 60, 2) }
    local second = F.prepare(d, first)
    local real, calls = F.density, 0
    F.density = function(...) calls = calls + 1; return real(...) end
    F.layout(second, 50, Scale)
    F.density = real
    eq(calls, 1, "Old is reused, its strip too")
end)

t.test("ten quick flips on a page touch it but never ink it as read", function()
    local r = row(5, 10, 1, 30)
    r.visits = 10
    local d = F.density({ row(1, 10, 1, 60), r }, 10, 10)
    eq(d[5], 0, "touched: step 0, no reading seconds")
    near(d[1], 60)
end)

t.test("a long book read over many days analyzes quickly", function()
    local rows = {}
    -- 1500 pages over 300 days, five pages a day.
    for d = 1, 300 do
        for p = (d - 1) * 5 + 1, d * 5 do rows[#rows + 1] = row(p, 1500, d, 60) end
    end
    local t0 = os.clock()
    local an = F.analyze(rows, 1500)
    local spent = os.clock() - t0
    near(an.progress, 1)
    assert(spent < 0.5, ("took %.3f s"):format(spent))
end)

t.done()
