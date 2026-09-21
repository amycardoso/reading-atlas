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
