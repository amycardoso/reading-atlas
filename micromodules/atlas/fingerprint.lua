-- The book's fingerprint: how each recent book was read, stretch by stretch.
--
-- Pure logic, no KOReader. Input is what db.fingerprintRows() returns:
--
--   { books = { { id, title, pages, last_open }, … },
--     rows  = { { id_book, page, total_pages, day, secs, last_seen }, … } }
--
-- where a row is the time spent on one page, in the layout of the moment
-- (total_pages), on one local day; last_seen is the row's latest start_time.
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
-- progress() looks for real reading in a window of this fraction of the book
-- (at least 5 pages) ending at a page.
M.PROGRESS_WINDOW = 0.02
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

-- Calls fn(k, fraction) for each of n equal buckets the span [a, b) overlaps,
-- with the fraction of the span that falls in bucket k. The fractions sum to 1.
local function spread(a, b, n, fn)
    local A, B = a * n, b * n
    local width = B - A
    if width <= 0 then return end
    local first = math.floor(A) + 1
    local last = math.min(n, math.ceil(B))
    for k = first, last do
        local overlap = math.min(B, k) - math.max(A, k - 1)
        if overlap > EPS then fn(k, overlap / width) end
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

-- Time spread over n buckets. Returns secs[k] (seconds spent in bucket k) and
-- read[k] (true when any row touched it).
function M.buckets(rows, n)
    local secs, read = {}, {}
    for k = 1, n do secs[k] = 0 end
    for i = 1, #rows do
        local r = rows[i]
        local a, b = rowSpan(r)
        if a then
            local s = r.secs or 0
            spread(a, b, n, function(k, f)
                secs[k] = secs[k] + s * f
                read[k] = true
            end)
        end
    end
    return secs, read
end

-- Seconds per page of each read bucket, in the book's current page count.
-- Dividing by the bucket's width in pages is what keeps a long book from
-- reading darker than a short one at the same pace.
function M.density(rows, n, pages)
    local secs, read = M.buckets(rows, n)
    local per_bucket = pages / n
    local out = {}
    for k = 1, n do
        if read[k] then out[k] = secs[k] / per_bucket end
    end
    return out
end

-- The furthest position any row touched, 0..1. Raw: one look at the last
-- page counts. Use progress() for how far the reader actually got.
function M.reach(rows)
    local far = 0
    for i = 1, #rows do
        local _a, b = rowSpan(rows[i])
        if b and b > far then far = b end
    end
    return far
end

-- ── Real reading ────────────────────────────────────────────────────────────
-- A tally of rows at page resolution (the book's current count), built up one
-- row at a time so the re-read rule can ask "how far had the reader really got
-- before this day?".
--
-- How far the reader really got is the furthest page that
--   * was read, not flipped past (SKIM_SECS a page or more), and
--   * ends a window of max(5 pages, PROGRESS_WINDOW of the book) in which at
--     least half the pages were read, coming from at least two different
--     pages of the book in whatever layout they were read.
-- The half rule keeps one look at the last page (the table of contents, an
-- endnote) from counting; the read-not-flipped rule keeps paging through to
-- the end from counting; the two-sources rule keeps one page of an old,
-- smaller-font layout -- which spans several current pages -- from counting.
-- Coverage alone would not do: a reader who skips an appendix still finished.
--
-- Every count in the tally only grows, so a page that qualifies stays
-- qualified and the frontier never moves back. That is what lets it be kept
-- incrementally: after new rows, only pages whose window touches what changed
-- are re-checked, instead of the whole book after every reading day.
local function newTally(pages)
    local st = {
        pages = pages, w = math.max(5, math.ceil(pages * M.PROGRESS_WINDOW)),
        secs = {}, starts = {}, spill = {}, seen = {}, best = 0,
    }
    for p = 1, pages do st.secs[p] = 0; st.starts[p] = 0; st.spill[p] = 0 end
    return st
end

-- Adds a row. Each distinct page of each layout counts once as a source, at
-- the first current page it covers; spill[q] counts the sources that started
-- before page q and still cover it, so the sources a window [lo, p] sees are
-- exactly the starts inside it plus spill[lo].
local function tallyRow(st, r)
    local a, b, page = rowSpan(r)
    if not a then return end
    local s = r.secs or 0
    local first, last
    spread(a, b, st.pages, function(p, f)
        st.secs[p] = st.secs[p] + s * f
        first = first or p
        last = p
    end)
    if not first then return end
    local key = page .. ":" .. r.total_pages
    if not st.seen[key] then
        st.seen[key] = true
        st.starts[first] = st.starts[first] + 1
        for q = first + 1, last do st.spill[q] = st.spill[q] + 1 end
    end
    if not st.lo or first < st.lo then st.lo = first end
    if not st.hi or last > st.hi then st.hi = last end
end

local function qualifies(st, p)
    if st.secs[p] < M.SKIM_SECS then return false end
    local lo = math.max(1, p - st.w + 1)
    local len = p - lo + 1
    local reads, sources = 0, st.spill[lo]
    for q = lo, p do
        if st.secs[q] >= M.SKIM_SECS then reads = reads + 1 end
        sources = sources + st.starts[q]
    end
    return reads >= math.ceil(len / 2) and sources >= math.min(2, len)
end

-- The frontier, 0..1, after the rows tallied so far.
local function frontier(st)
    if st.lo then
        local top = math.min(st.pages, st.hi + st.w - 1)
        for p = top, math.max(st.lo, st.best + 1), -1 do
            if qualifies(st, p) then st.best = p; break end
        end
        st.lo, st.hi = nil, nil
    end
    return st.best / st.pages
end

function M.progress(rows, pages)
    local st = newTally(pages)
    for i = 1, #rows do tallyRow(st, rows[i]) end
    return frontier(st)
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

-- Real progress, and the pages read again after the reader had been well past
-- them, as merged { from, to } intervals in the book's current page count.
-- One pass, one tally: the frontier after the last day IS the progress.
--
-- A page is re-read on day d when
--   * it was READ (not flipped past) on an earlier day -- an earlier skim
--     makes today's reading the first, not a second,
--   * it is read, not flipped past, again on d, and
--   * before d, the reader had REALLY got (the frontier, not the raw reach) at
--     least REREAD_LEAD further on.
-- The last condition keeps the page where one session ends and the next
-- begins from counting, and a look at the end of the book from turning every
-- later session start into a re-read.
function M.analyze(rows, pages)
    local by_day, days = byDay(rows)
    local st = newTally(pages)
    local first_day, marked = {}, {}
    local far_before = 0
    for _i, d in ipairs(days) do
        local list = by_day[d]
        local today = {}
        for _j, r in ipairs(list) do
            local a, b = rowSpan(r)
            if a then
                local s = r.secs or 0
                spread(a, b, pages, function(p, f) today[p] = (today[p] or 0) + s * f end)
            end
        end
        for p, s in pairs(today) do
            if s >= M.SKIM_SECS then
                if first_day[p] and first_day[p] < d
                        and far_before >= p / pages + M.REREAD_LEAD then
                    marked[p] = true
                end
                if not first_day[p] then first_day[p] = d end
            end
        end
        for _j, r in ipairs(list) do tallyRow(st, r) end
        far_before = frontier(st)
    end

    -- A re-read skips a page here and there, and a re-pagination makes a
    -- stretch land on every other page; gaps up to REREAD_BRIDGE of the book
    -- are bridged so one re-read is one bar, not a dashed line.
    local bridge = math.floor(pages * M.REREAD_BRIDGE)
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
    return { progress = far_before, rereads = out }
end

function M.rereads(rows, pages)
    return M.analyze(rows, pages).rereads
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

-- The stretch where the most time went: a window of max(10 pages, 2% of the
-- book), searched only over what was read. A book read less than one window
-- uses all of what was read. Returns { from, to, secs } in current pages, or
-- nil when nothing was read.
function M.slowest(rows, pages)
    local per_page = M.buckets(rows, pages)
    local read_to = math.min(pages, math.ceil(M.reach(rows) * pages - 1e-9))
    if read_to < 1 then return nil end
    local w = math.max(10, math.ceil(pages * 0.02))
    if w > read_to then w = read_to end
    local sum = 0
    for p = 1, w do sum = sum + per_page[p] end
    local best, at = sum, 1
    for p = w + 1, read_to do
        sum = sum + per_page[p] - per_page[p - w]
        if sum > best + 1e-9 then best, at = sum, p - w + 1 end
    end
    return { from = at, to = at + w - 1, secs = best }
end

-- "finished", "reading" or "paused", from the statistics alone. `progress` is
-- M.progress(), never the raw reach.
function M.status(progress, last_open, now)
    if progress >= M.FINISHED_AT then return "finished" end
    if last_open and now and now - last_open >= M.PAUSED_AFTER then return "paused" end
    return "reading"
end

-- Books with their rows, most recently opened first, at most MAX_BOOKS.
-- Everything that depends on neither the strip's width nor the clock is
-- computed here, once per query: progress, re-reads and the slowest stretch.
-- The status reads the clock, so the card asks status() at render time.
function M.prepare(data)
    local by_book = {}
    for i = 1, #(data.rows or {}) do
        local r = data.rows[i]
        local list = by_book[r.id_book]
        if not list then list = {}; by_book[r.id_book] = list end
        list[#list + 1] = r
    end
    local books = {}
    for _i, b in ipairs(data.books or {}) do
        local rows = by_book[b.id]
        if rows and #rows > 0 then
            local secs = 0
            for j = 1, #rows do secs = secs + (rows[j].secs or 0) end
            local pages = currentPages(b, rows)
            local an = M.analyze(rows, pages)
            books[#books + 1] = {
                id = b.id, title = b.title or "", last_open = b.last_open or 0,
                pages = pages, rows = rows, secs = secs, progress = an.progress,
                rereads = an.rereads, reread_pages = M.largest(an.rereads),
                slowest = M.slowest(rows, pages),
            }
        end
    end
    table.sort(books, function(x, y)
        if x.last_open ~= y.last_open then return x.last_open > y.last_open end
        return x.id < y.id
    end)
    while #books > M.MAX_BOOKS do table.remove(books) end
    return { books = books }
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
        local dens = M.density(b.rows, n, b.pages)
        strips[i] = { book = b, density = dens }
        for k = 1, n do
            local v = dens[k]
            if v and v >= M.SKIM_SECS then values[#values + 1] = v end
        end
    end
    local th = Scale.thresholds(values)
    for _i, s in ipairs(strips) do
        local levels = {}
        for k = 1, n do
            local v = s.density[k]
            if v ~= nil then
                levels[k] = (v < M.SKIM_SECS) and 0 or Scale.level(v, th)
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
