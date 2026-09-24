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
