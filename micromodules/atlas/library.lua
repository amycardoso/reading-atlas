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
