-- The book's fingerprint: how each recent book was read, stretch by stretch.
--
-- Pure logic, no KOReader. Input is what db.fingerprintRows() returns:
--
--   { books = { { id, title, pages, last_open }, … },
--     rows  = { { id_book, page, total_pages, day, secs, visits, last_seen }, … } }
--
-- where a row is the time spent on one page, in the layout of the moment
-- (total_pages), on one local day, over `visits` separate visits; last_seen
-- is the row's latest start_time.
--
-- ── WHY POSITIONS, NOT PAGES ────────────────────────────────────────────────
-- Changing the font or margins of an EPUB re-paginates it: page 120 of 300
-- before is not page 120 of 450 after. Every row is therefore turned into the
-- stretch of the book it covers, [(page - 1) / total_pages, page / total_pages),
-- and only converted back to a page number -- in the book's CURRENT count --
-- when the note names one. KOReader's own page_stat view does the same
-- rescaling, but with a JOIN that multiplies rows; too slow for an e-reader.
local M = {}

local DAY = 86400

-- Below this many seconds per page, a stretch was flipped past, not read.
M.SKIM_SECS = 5
-- How much further on the reader must already have been for a return to
-- count as a re-read.
M.REREAD_LEAD = 0.05
-- Re-read stretches closer than this (a fraction of the book) are one re-read.
M.REREAD_BRIDGE = 0.01
-- Finished at 97%: the last pages are often notes, acknowledgements, ads.
M.FINISHED_AT = 0.97
-- Real progress looks for reading in a window of this fraction of the book
-- (at least 5 pages) ending at a page.
M.PROGRESS_WINDOW = 0.02
-- A page counts as read at this fraction of the book's median pace or more;
-- below it, it was looked up (an endnote) or flipped past.
M.LOOKUP_FRACTION = 0.25
-- Overlaps below this (in buckets) are floating-point noise, not reading:
-- (page - 1) / total_pages * n can land a hair past a bucket edge.
local EPS = 1e-9
-- Not touched for this long, and not finished: paused, not reading.
M.PAUSED_AFTER = 30 * DAY
-- The most books the card ever shows.
M.MAX_BOOKS = 6

-- The stretch [a, b) of the book a row covers, and its page clamped into
-- the row's layout (page 0, nil or past the end all mean an edge page).
local function rowSpan(row)
    local tp = row.total_pages
    if not tp or tp < 1 then return nil end
    local p = math.max(1, math.min(row.page or 1, tp))
    return (p - 1) / tp, p / tp, p
end

-- Calls fn(k, fraction, x, y, z, w) for each of n equal buckets the span [a, b)
-- overlaps, with the fraction of the span that falls in bucket k; the
-- fractions sum to 1. State goes in x, y, z, w rather than a closure, so the
-- hot loops over thousands of rows allocate no function per row.
local function spread(a, b, n, fn, x, y, z, w)
    local A, B = a * n, b * n
    local width = B - A
    if width <= 0 then return end
    local first = math.floor(A) + 1
    local last = math.min(n, math.ceil(B))
    for k = first, last do
        local overlap = math.min(B, k) - math.max(A, k - 1)
        if overlap > EPS then fn(k, overlap / width, x, y, z, w) end
    end
end

-- The book's page count now: what the reader sees, and what notes name. Falls
-- back to the layout of the most recent row when the book table has none.
-- "Most recent" is by start time, not by day: a font change today leaves two
-- layouts on the same day, and row order from SQL is not defined.
local function currentPages(book, rows)
    if book.pages and book.pages > 0 then return book.pages end
    local best, seen = nil, nil
    for i = 1, #rows do
        local r = rows[i]
        if r.total_pages and r.total_pages > 0 then
            local s = r.last_seen or r.day or 0
            if not seen or s > seen then best, seen = r.total_pages, s end
        end
    end
    return best or 1
end
M.currentPages = currentPages

-- Time spread over n buckets. Returns secs[k] (seconds spent in bucket k),
-- read[k] (true when any row touched it) and cover[k] (how much of bucket k
-- the book's pages cover, in buckets). Coverage counts each page of each
-- layout once: rows are per page PER DAY, and a page read on three days is
-- still one page -- its time goes to secs three times, its width to cover once.
local function addToBucket(k, f, acc, s, width)
    acc.secs[k] = acc.secs[k] + s * f
    acc.read[k] = true
    if width then acc.cover[k] = math.min(1, acc.cover[k] + f * width) end
end

function M.buckets(rows, n)
    local acc = { secs = {}, read = {}, cover = {} }
    local seen = {}
    for k = 1, n do acc.secs[k] = 0; acc.cover[k] = 0 end
    for i = 1, #rows do
        local r = rows[i]
        local a, b, page = rowSpan(r)
        if a then
            local key = page .. ":" .. r.total_pages
            local width = nil
            if not seen[key] then seen[key] = true; width = (b - a) * n end
            spread(a, b, n, addToBucket, acc, r.secs or 0, width)
        end
    end
    return acc.secs, acc.read, acc.cover
end

-- Seconds per page of each read bucket, in the book's current page count:
-- the bucket's time over the pages in it that were read. Measuring per page is
-- what keeps a long book from reading darker than a short one at the same
-- pace; dividing by the pages READ, not the bucket's full width, keeps a
-- bucket at the edge of a skipped stretch from paling into "flipped past".
function M.density(rows, n, pages)
    local secs, read, cover = M.buckets(rows, n)
    local per_bucket = pages / n
    local out = {}
    for k = 1, n do
        if read[k] then out[k] = secs[k] / (cover[k] * per_bucket) end
    end
    return out
end

-- ── Real reading ────────────────────────────────────────────────────────────
-- A tally of rows at page resolution (the book's current count), built up one
-- day at a time so the re-read rule can ask "how far had the reader really
-- got before this day?".
--
-- A page was READ when it got at least the book's reading threshold: a
-- quarter of the reader's median seconds per page in this book, and never
-- less than SKIM_SECS. Relative, because what tells reading from a look-up
-- is the pace: an endnote checked for ten seconds in a book read at a minute a
-- page is a look-up, not a page read.
--
-- How far the reader really got is the furthest page that
--   * was read, and
--   * ends a window of max(5 pages, PROGRESS_WINDOW of the book) in which at
--     least half the pages were read, coming from at least two different
--     pages of the book in whatever layout they were read.
-- The half rule keeps one look at the last page (the table of contents, an
-- endnote) from counting; the threshold keeps paging through to the end, and
-- runs of endnote look-ups, from counting; the two-sources rule keeps one page
-- of an old, smaller-font layout -- which spans several current pages -- from
-- counting. Coverage alone would not do: a reader who skips an appendix still
-- finished.
--
-- The threshold is fixed for the whole analysis and every count only grows,
-- so a page that qualifies stays qualified and the frontier never moves back.
-- That is what lets it be kept incrementally: after a day, only the windows
-- that contain one of that day's pages are re-checked, each in O(log pages)
-- through two Fenwick trees (pages read, sources started).

-- The reading threshold for a book, in seconds per current page. Uses each
-- row's own pace (its time over the current pages it spans), so it needs no
-- spread and no second pass over the pages.
--
-- The median is weighted by time: the pace at which half the book's reading
-- TIME was spent. A plain median counts rows, and in a book read for 100 pages
-- and flipped through for 200, the flips would set the pace -- 3 s a page --
-- and every flip would then count as reading.
function M.threshold(rows, pages)
    local paces, total = {}, 0
    for i = 1, #rows do
        local r = rows[i]
        local s = r.secs or 0
        if r.total_pages and r.total_pages > 0 and s > 0 then
            paces[#paces + 1] = { pace = s * r.total_pages / pages, secs = s }
            total = total + s
        end
    end
    if #paces == 0 then return M.SKIM_SECS end
    table.sort(paces, function(x, y) return x.pace < y.pace end)
    local acc, median = 0, paces[#paces].pace
    for i = 1, #paces do
        acc = acc + paces[i].secs
        if acc >= total / 2 then median = paces[i].pace; break end
    end
    return math.max(M.SKIM_SECS, median * M.LOOKUP_FRACTION)
end

local function newTally(pages, thr)
    local st = {
        pages = pages, thr = thr,
        w = math.max(5, math.ceil(pages * M.PROGRESS_WINDOW)),
        secs = {}, rsecs = {}, isread = {}, spill = {}, seen = {}, best = 0, top = 0,
        reads = {}, starts = {}, -- Fenwick trees
    }
    for p = 1, pages do
        st.secs[p] = 0; st.rsecs[p] = 0; st.spill[p] = 0; st.reads[p] = 0; st.starts[p] = 0
    end
    return st
end

-- Fenwick tree helpers: point add, prefix sum. KOReader's LuaJIT has the
-- `bit` module, and band(i, -i) is the lowest set bit; a plain Lua 5.1
-- running the suites does not, so it falls back to finding it arithmetically.
local has_bit, bit = pcall(require, "bit")
local lowbit
if has_bit and bit and bit.band then
    lowbit = function(i) return bit.band(i, -i) end
else
    lowbit = function(i)
        local b = 1
        while i % (2 * b) == 0 do b = 2 * b end
        return b
    end
end
local function fadd(tree, n, i, v)
    while i <= n do tree[i] = tree[i] + v; i = i + lowbit(i) end
end
local function fsum(tree, i)
    local s = 0
    while i > 0 do s = s + tree[i]; i = i - lowbit(i) end
    return s
end

-- Adds a row, and its seconds per page to `today`. Each distinct page of each
-- layout counts once as a source, at the first current page it covers;
-- spill[q] counts the sources that started before page q and still cover it,
-- so the sources a window [lo, p] sees are the starts inside it plus spill[lo].
-- st.secs is all the time spent on a page (for the slowest stretch); st.rsecs
-- only the time of visits long enough to be reading (SKIM_SECS a visit or
-- more), which is what decides whether a page was read. Without that split,
-- paging to the end and back, or on two days, adds 4 s + 4 s of flipping up
-- to a page "read". today[p] is the day's reading time; every page a row
-- touches gets a key, so its windows are re-checked.
local function addToTally(p, f, st, today, s, reading)
    st.secs[p] = st.secs[p] + s * f
    local rs = reading and s * f or 0
    st.rsecs[p] = st.rsecs[p] + rs
    today[p] = (today[p] or 0) + rs
    if not st.isread[p] and st.rsecs[p] >= st.thr then
        st.isread[p] = true
        fadd(st.reads, st.pages, p, 1)
    end
    st.first = st.first or p
    st.last = p
end

local function tallyRow(st, r, today)
    local a, b, page = rowSpan(r)
    if not a then return end
    local s = r.secs or 0
    local reading = s / math.max(1, r.visits or 1) >= M.SKIM_SECS
    st.first, st.last = nil, nil
    spread(a, b, st.pages, addToTally, st, today, s, reading)
    local first, last = st.first, st.last
    if not first then return end
    local key = page .. ":" .. r.total_pages
    if not st.seen[key] then
        st.seen[key] = true
        fadd(st.starts, st.pages, first, 1)
        for q = first + 1, last do st.spill[q] = st.spill[q] + 1 end
    end
    if last > st.top then st.top = last end
end

local function qualifies(st, p)
    if not st.isread[p] then return false end
    local lo = math.max(1, p - st.w + 1)
    local len = p - lo + 1
    local reads = fsum(st.reads, p) - fsum(st.reads, lo - 1)
    local sources = fsum(st.starts, p) - fsum(st.starts, lo - 1) + st.spill[lo]
    return reads >= math.ceil(len / 2) and sources >= math.min(2, len)
end

-- The frontier, 0..1, after a day whose pages are the keys of `today`. Only
-- the windows ending in [c, c + w - 1] for one of those pages c can have
-- changed; those ranges are merged and scanned once, from the top down, and
-- the first page that qualifies is the new frontier. Pages at or below the old
-- frontier are never re-checked: it cannot move back.
local function frontier(st, today)
    local cs = {}
    for c in pairs(today) do cs[#cs + 1] = c end
    table.sort(cs, function(x, y) return x > y end)
    local best, w, pages = st.best, st.w, st.pages
    local i = 1
    while i <= #cs do
        -- One merged range [lo, hi] of window ends, highest first.
        local hi = math.min(pages, cs[i] + w - 1)
        local lo = cs[i]
        while i + 1 <= #cs and cs[i + 1] + w - 1 >= lo - 1 do
            i = i + 1
            lo = cs[i]
        end
        if hi <= best then break end
        for p = hi, math.max(lo, best + 1), -1 do
            if qualifies(st, p) then
                st.best = p
                return p / pages
            end
        end
        i = i + 1
    end
    return best / pages
end

-- The stretch where the most time went: a window of max(10 pages, 2% of the
-- book), searched only up to the furthest page touched. A book read less than
-- one window uses all of what was read. { from, to, secs } in current pages,
-- or nil when nothing was read.
local function slowest(st)
    local read_to = st.top
    if read_to < 1 then return nil end
    local per_page = st.secs
    local w = math.min(read_to, math.max(10, math.ceil(st.pages * 0.02)))
    local sum = 0
    for p = 1, w do sum = sum + per_page[p] end
    local best, at = sum, 1
    for p = w + 1, read_to do
        sum = sum + per_page[p] - per_page[p - w]
        if sum > best + 1e-9 then best, at = sum, p - w + 1 end
    end
    return { from = at, to = at + w - 1, secs = best }
end

local function byDay(rows)
    local by_day, days = {}, {}
    for i = 1, #rows do
        local r = rows[i]
        local d = r.day or 0
        if not by_day[d] then by_day[d] = {}; days[#days + 1] = d end
        local list = by_day[d]
        list[#list + 1] = r
    end
    table.sort(days)
    return by_day, days
end

-- Everything about one book that depends on neither the strip's width nor the
-- clock, in one pass over its rows, one spread per row:
--
--   progress  how far the reader really got, 0..1 (the frontier above)
--   rereads   pages read again after the reader had been well past them, as
--             merged { from, to } intervals in the book's current page count
--   slowest   the stretch where the most time went
--
-- A page is re-read on day d when
--   * it was READ (at the threshold, not flipped past or looked up) on an
--     earlier day -- an earlier skim makes today's reading the first,
--   * it is read again on d, and
--   * before d, the reader had REALLY got (the frontier, not the furthest page
--     touched) at least REREAD_LEAD further on.
-- The last condition keeps the page where one session ends and the next
-- begins from counting, and a look at the end of the book from turning every
-- later session start into a re-read.
function M.analyze(rows, pages)
    local by_day, days = byDay(rows)
    local thr = M.threshold(rows, pages)
    local st = newTally(pages, thr)
    local first_day, marked = {}, {}
    local far_before = 0
    for _i, d in ipairs(days) do
        local today = {}
        for _j, r in ipairs(by_day[d]) do tallyRow(st, r, today) end
        -- Days run in order and first_day is only set below, so a page with a
        -- first_day was first read on an earlier day. A page's first day is
        -- the day it became read in total -- two short sessions on one page
        -- add up -- and a re-read is a day that reads it again in full.
        for p, s in pairs(today) do
            if first_day[p] then
                if s >= thr and far_before >= p / pages + M.REREAD_LEAD then
                    marked[p] = true
                end
            elseif st.isread[p] then
                first_day[p] = d
            end
        end
        far_before = frontier(st, today)
    end

    -- A re-read skips a page here and there, and a re-pagination makes a
    -- stretch land on every other page; gaps up to REREAD_BRIDGE of the book
    -- are bridged so one re-read is one bar, not a dashed line.
    -- At least one page, or a book under 100 pages would bridge nothing.
    local bridge = math.max(1, math.floor(pages * M.REREAD_BRIDGE))
    local out, k = {}, 1
    while k <= pages do
        if marked[k] then
            local from, to = k, k
            local j = k + 1
            while j <= pages and j - to - 1 <= bridge do
                if marked[j] then to = j end
                j = j + 1
            end
            out[#out + 1] = { from = from, to = to }
            k = to
        end
        k = k + 1
    end
    return { progress = far_before, rereads = out, slowest = slowest(st), threshold = thr }
end

-- The largest interval, or nil. Ties go to the first.
function M.largest(intervals)
    local best
    for _i, iv in ipairs(intervals) do
        if not best or (iv.to - iv.from) > (best.to - best.from) then best = iv end
    end
    return best
end

-- Page interval (current count) -> bucket interval of an n-wide strip.
function M.toBuckets(iv, pages, n)
    local from = math.floor((iv.from - 1) * n / pages + EPS) + 1
    local to = math.max(from, math.ceil(iv.to * n / pages - EPS))
    return { from = from, to = math.min(to, n) }
end

-- "finished", "reading" or "paused", from the statistics alone. `progress` is
-- analyze()'s, never the furthest page touched. A book with no last_open is
-- never called paused: nothing says when it was last read.
function M.status(progress, last_open, now)
    if progress >= M.FINISHED_AT then return "finished" end
    if last_open and now and now - last_open >= M.PAUSED_AFTER then return "paused" end
    return "reading"
end

-- Books with their analysis, in the order db.fingerprintRows gives them (it
-- owns the order and the cap). Runs inside the query, off the paint path: this
-- is the heavy part. The status reads the clock, so the card asks status() at
-- render time.
--
-- `old` is the previous answer, if any. A book whose sig is unchanged was not
-- read since and came without rows; its earlier entry is reused as it is. When
-- every book is reused, in the same order, `old` itself comes back, which tells
-- source.lua that nothing changed and the card need not be repainted.
function M.prepare(data, old)
    local by_book = {}
    for i = 1, #(data.rows or {}) do
        local r = data.rows[i]
        local list = by_book[r.id_book]
        if not list then list = {}; by_book[r.id_book] = list end
        list[#list + 1] = r
    end
    local before = {}
    for _i, b in ipairs(old and old.books or {}) do before[b.id] = b end
    local books, same = {}, old ~= nil
    for _i, b in ipairs(data.books or {}) do
        local rows = by_book[b.id]
        local prev = before[b.id]
        if not rows and prev and b.sig ~= nil and prev.sig == b.sig then
            books[#books + 1] = prev
        elseif rows and #rows > 0 then
            same = false
            local secs = 0
            for j = 1, #rows do secs = secs + (rows[j].secs or 0) end
            local pages = currentPages(b, rows)
            local an = M.analyze(rows, pages)
            books[#books + 1] = {
                -- last_open stays nil when the database has none; 0 would read
                -- as "paused since 1970".
                id = b.id, title = b.title or "", last_open = b.last_open,
                pages = pages, rows = rows, secs = secs, progress = an.progress,
                threshold = an.threshold,
                rereads = an.rereads, reread_pages = M.largest(an.rereads),
                slowest = an.slowest, sig = b.sig,
            }
        end
    end
    if same and #books == #old.books then
        for i = 1, #books do
            if books[i] ~= old.books[i] then same = false; break end
        end
        if same then return old end
    end
    return { books = books }
end

-- density() per book table and width. An unchanged book keeps its table across
-- refreshes (prepare reuses it), so when only the book being read changed,
-- only its strip is spread again.
local _density_memo = setmetatable({}, { __mode = "k" })
local function densityOf(b, n)
    local by_n = _density_memo[b]
    if not by_n then by_n = {}; _density_memo[b] = by_n end
    if not by_n[n] then by_n[n] = M.density(b.rows, n, b.pages) end
    return by_n[n]
end

-- Strips for the first `count` books at n buckets, with one scale shared by
-- the books on the card so they compare: a hard book reads darker than an
-- easy one, not just different inside. Level per bucket: nil = not read,
-- 0 = flipped past, 1..4 = quartiles of seconds per page. Only what depends
-- on the width is computed here; the rest comes from prepare().
function M.layout(prep, n, Scale, count)
    count = math.min(count or #prep.books, #prep.books)
    local strips, values = {}, {}
    for i = 1, count do
        local b = prep.books[i]
        local dens = densityOf(b, n)
        strips[i] = { book = b, density = dens }
        local thr = b.threshold or M.SKIM_SECS
        for k = 1, n do
            local v = dens[k]
            if v and v >= thr then values[#values + 1] = v end
        end
    end
    local th = Scale.thresholds(values)
    for _i, s in ipairs(strips) do
        -- Step 0 is "touched, not read", by the same threshold as progress:
        -- the strip must not ink as read what the percentage says was not.
        local thr = s.book.threshold or M.SKIM_SECS
        local levels = {}
        for k = 1, n do
            local v = s.density[k]
            if v ~= nil then
                levels[k] = (v < thr) and 0 or Scale.level(v, th)
            end
        end
        s.levels = levels
        s.density = nil
        local bars = {}
        for j, iv in ipairs(s.book.rereads) do bars[j] = M.toBuckets(iv, s.book.pages, n) end
        s.rereads = bars
        s.reread_pages = s.book.reread_pages
        s.slowest = s.book.slowest
    end
    return strips
end

return M
