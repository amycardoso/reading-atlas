-- The book's fingerprint: how each recent book was read, stretch by stretch.
--
-- Pure logic, no KOReader. Input is what db.fingerprintRows() returns:
--
--   { books = { { id, title, pages, last_open }, … },
--     rows  = { { id_book, page, total_pages, day, secs }, … } }
--
-- where a row is the time spent on one page, in the layout of the moment
-- (total_pages), on one day.
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
-- Not touched for this long, and not finished: paused, not reading.
M.PAUSED_AFTER = 30 * DAY
-- The most books the card ever shows.
M.MAX_BOOKS = 6

local function rowSpan(row)
    local tp = row.total_pages
    if not tp or tp < 1 then return nil end
    local p = math.max(1, math.min(row.page or 1, tp))
    return (p - 1) / tp, p / tp
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
        if overlap > 0 then fn(k, overlap / width) end
    end
end

-- The book's page count now: what the reader sees, and what notes name. Falls
-- back to the layout of the most recent row when the book table has none.
local function currentPages(book, rows)
    if book.pages and book.pages > 0 then return book.pages end
    local best, day = nil, -1
    for i = 1, #rows do
        local r = rows[i]
        if r.total_pages and r.total_pages > 0 and (r.day or 0) >= day then
            best, day = r.total_pages, r.day or 0
        end
    end
    return best or 1
end

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

-- How far the reader actually got, 0..1: the furthest page with real reading
-- around it, meaning at least half of the PROGRESS_WINDOW pages ending there
-- were read. A look at the last page (the table of contents, an endnote, how
-- long the book is) touches one page in that window and does not count;
-- reading the ending does. Coverage alone would not do: a reader who skips
-- an appendix or a preface still finished the book.
function M.progress(rows, pages)
    local _secs, read = M.buckets(rows, pages)
    local w = math.max(5, math.ceil(pages * M.PROGRESS_WINDOW))
    local prefix = { [0] = 0 }
    for p = 1, pages do prefix[p] = prefix[p - 1] + (read[p] and 1 or 0) end
    local best = 0
    for p = 1, pages do
        if read[p] then
            -- Near the start the window is shorter, and so is the bar.
            local lo = math.max(1, p - w + 1)
            local len = p - lo + 1
            if prefix[p] - prefix[lo - 1] >= math.ceil(len / 2) then best = p end
        end
    end
    return best / pages
end

-- Buckets read again after the reader had been well past them, as merged
-- { from, to } intervals of bucket indexes.
--
-- A bucket is re-read on day d when it was already read on an earlier day AND,
-- before d, the reader had reached at least REREAD_LEAD further on than the
-- page now being read. The second condition is what keeps the page where one
-- session ends and the next begins from counting: it shows up on two days, but
-- nobody had gone past it.
function M.rereads(rows, n)
    local by_day, days = {}, {}
    for i = 1, #rows do
        local r = rows[i]
        local d = r.day or 0
        if not by_day[d] then by_day[d] = {}; days[#days + 1] = d end
        local list = by_day[d]
        list[#list + 1] = r
    end
    table.sort(days)

    local first_day, marked = {}, {}
    local far_before = 0
    for _i, d in ipairs(days) do
        local list = by_day[d]
        local far_today = far_before
        -- Judge the whole day against the state before it, then fold it in.
        for _j, r in ipairs(list) do
            local a, b = rowSpan(r)
            if a then
                if far_before >= b + M.REREAD_LEAD then
                    spread(a, b, n, function(k)
                        if first_day[k] and first_day[k] < d then marked[k] = true end
                    end)
                end
                if b > far_today then far_today = b end
            end
        end
        for _j, r in ipairs(list) do
            local a, b = rowSpan(r)
            if a then
                spread(a, b, n, function(k)
                    if not first_day[k] then first_day[k] = d end
                end)
            end
        end
        far_before = far_today
    end

    -- A re-read skips a page here and there, and a re-pagination makes a
    -- stretch land on every other bucket; gaps up to REREAD_BRIDGE of the
    -- book are bridged so one re-read is one bar, not a dashed line.
    local bridge = math.floor(n * M.REREAD_BRIDGE)
    local out, k = {}, 1
    while k <= n do
        if marked[k] then
            local from, to = k, k
            local j = k + 1
            while j <= n and j - to - 1 <= bridge do
                if marked[j] then to = j end
                j = j + 1
            end
            out[#out + 1] = { from = from, to = to }
            k = to
        end
        k = k + 1
    end
    return out
end

-- The largest interval, or nil. Ties go to the first.
function M.largest(intervals)
    local best
    for _i, iv in ipairs(intervals) do
        if not best or (iv.to - iv.from) > (best.to - best.from) then best = iv end
    end
    return best
end

-- Bucket interval -> page interval in the current count.
function M.toPages(iv, n, pages)
    local from = math.floor((iv.from - 1) * pages / n) + 1
    local to = math.max(from, math.ceil(iv.to * pages / n))
    return from, math.min(to, pages)
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
-- Width-independent: everything here is computed once per query.
function M.prepare(data, now)
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
            local progress = M.progress(rows, pages)
            books[#books + 1] = {
                id = b.id, title = b.title or "", last_open = b.last_open or 0,
                pages = pages, rows = rows, secs = secs,
                progress = progress, status = M.status(progress, b.last_open, now),
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

-- Per-book strips at n buckets, with one scale shared by every book on the
-- card so they compare: a hard book reads darker than an easy one, not just
-- different inside. Level per bucket: nil = not read, 0 = skimmed, 1..4 =
-- quartiles of seconds per page.
function M.layout(prep, n, Scale)
    local strips, values = {}, {}
    for i, b in ipairs(prep.books) do
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
        s.rereads = M.rereads(s.book.rows, n)
        -- The note's re-read names pages, so it is measured in pages, not in
        -- buckets of this particular width.
        s.reread_pages = M.largest(M.rereads(s.book.rows, s.book.pages))
        s.slowest = M.slowest(s.book.rows, s.book.pages)
    end
    return strips
end

return M
