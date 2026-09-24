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
            -- Bookshelf may already have a real territory under this same
            -- name (its own "Unknown" language group, say) -- fold the
            -- unassigned books into it rather than drawing a duplicate.
            local into
            for _, t in ipairs(list) do
                if t.name == unassigned_name then into = t; break end
            end
            if into then
                local merged = {}
                for i, b in ipairs(into.books) do merged[i] = b end
                for _, b in ipairs(unassigned) do merged[#merged + 1] = b end
                into.books = merged
            else
                list[#list + 1] = { name = unassigned_name, books = unassigned }
            end
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

return M
