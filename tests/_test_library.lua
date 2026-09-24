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
        progressFor = o.progressFor,
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

t.test("progressFor is preferred over readProgress when both exist", function()
    local read_calls = 0
    local repo = fakeRepo{
        readProgress = function(path)
            read_calls = read_calls + 1
            return 1.0, "finished"
        end,
        progressFor = function(path)
            if path == "/b/a.epub" then return 1.0, "reading" end
            return nil, nil
        end,
    }
    local got = byName(Library.territories("language", repo))
    eq(got.English.books[1].status, "reading", "progressFor's status wins")
    eq(read_calls, 0, "readProgress must not be called when progressFor exists")
end)

t.test("without progressFor, readProgress is used as before", function()
    local repo = fakeRepo{ progressFor = nil }
    local got = byName(Library.territories("language", repo))
    eq(got.English.books[1].status, "finished")
end)

t.test("a repository with progressFor but no readProgress is available", function()
    local repo = fakeRepo{
        readProgress = nil,
        progressFor = function(path)
            if path == "/b/a.epub" then return 1.0, "finished" end
            return nil, nil
        end,
    }
    local got = byName(Library.territories("language", repo))
    eq(got.English.books[1].status, "finished")
end)

t.test("a repository with neither progressFor nor readProgress is unavailable", function()
    local repo = fakeRepo()
    repo.readProgress = nil
    repo.progressFor = nil
    eq(Library.territories("language", repo), nil)
end)

t.test("a progressFor that raises for one file leaves that book unread, rest intact", function()
    local repo = fakeRepo{
        progressFor = function(path)
            if path == "/b/b.epub" then error("sidecar stat failed") end
            return 1.0, "finished"
        end,
    }
    local got = byName(Library.territories("language", repo))
    eq(got.English.books[1].status, "finished")
    eq(got.English.books[2].status, nil, "the broken one is unread")
    eq(got.Portuguese.books[1].status, "finished", "the rest are intact")
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
