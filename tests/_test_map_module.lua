-- atlas_map.lua is composition -- states, the heading and context line, the
-- settings dialog -- over helpers tested on their own. It runs here against
-- stubs of bookshelf's Kit and KOReader's widgets, which catches what the
-- other suites cannot: a typo, a nil, a state wired to the wrong card. The
-- painting and the real host are verified on the device.
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
package.loaded["ffi/blitbuffer"] = { Color8 = function(v) return { v = v } end }
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

local scheduled = {}
local shown_dialog
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, _secs, fn) scheduled[#scheduled + 1] = fn end,
    show = function(_, d) shown_dialog = d end,
    close = function() end,
}
package.loaded["ui/widget/buttondialog"] = ctor()

package.loaded["lib/bookshelf_i18n"] = { gettext = function(s) return s end }
package.loaded["lib/bookshelf_module_kit"] = {
    COLOR_MUTED = "muted",
    sc = function() return function(n) return n end end,
    face = function() return "FACE", false end,
    valueCard = function(o) return { card = true, heading = o.heading, value = o.value, sub = o.sub } end,
    radioRow = function(o) return { text = (o.active and "* " or "  ") .. o.label, pick = o.on_pick } end,
    settingsReopen = function() end,
}

-- The library is faked through the loader's memo: atlas("library") returns
-- whatever sits in package.loaded["atlas/library"].
local library_answer, library_axis
package.loaded["atlas/library"] = {
    territories = function(axis)
        library_axis = axis
        return library_answer
    end,
}

-- Pre-seeded under the loader's key, so the module and this suite share one
-- instance and a test can reset it.
local Source = dofile("micromodules/atlas/source.lua")
package.loaded["atlas/source"] = Source

local Map = dofile("micromodules/atlas_map.lua")

local function runScheduled()
    local q = scheduled
    scheduled = {}
    for i = 1, #q do q[i]() end
end

local function config(values)
    values = values or {}
    return {
        get = function(_, k, default) if values[k] == nil then return default end return values[k] end,
        set = function(_, k, v) values[k] = v end,
        values = values,
    }
end

-- Renders once to kick off the query, lets it land, renders again.
local function settle(ctx)
    Source.reset()
    scheduled = {}
    Map.render(ctx)
    runScheduled()
    return Map.render(ctx)
end

local function ctx(extra)
    local c = { width = 400, height = 160, scale = 100, refresh = function() end,
                config = config() }
    for k, v in pairs(extra or {}) do c[k] = v end
    return c
end

local function lib(territories, unassigned)
    return { territories = territories, unassigned = unassigned or {} }
end

local function book(path, status) return { path = path, status = status } end

-- ── tests ──────────────────────────────────────────────────────────────────

t.test("the module declares a frozen key, a summary and settings", function()
    eq(Map.key, "atlas_map")
    assert(type(Map.summary) == "string" and #Map.summary > 0)
    assert(type(Map.render) == "function")
    assert(type(Map.show_settings) == "function")
end)

t.test("the first render is the loading card and queries off the paint path", function()
    Source.reset()
    scheduled = {}
    library_axis = nil
    local card = Map.render(ctx())
    eq(card.value, "Reading…")
    eq(library_axis, nil, "the library must not be read inside render")
    eq(#scheduled, 1)
end)

t.test("a bookshelf that cannot answer is the Unavailable card", function()
    library_answer = nil
    local card = settle(ctx())
    eq(card.value, "Unavailable")
end)

t.test("an empty library is the No books card", function()
    library_answer = lib({}, {})
    eq(settle(ctx()).value, "No books")
end)

t.test("books with no genre at all get the axis's own empty card", function()
    library_answer = lib({}, { book("/a", nil) })
    local card = settle(ctx{ config = config{ axis = "genre" } })
    eq(card.value, "No genres")
    eq(card.heading, "Atlas map · Genres")
end)

t.test("with data, the card is heading, grid and context line", function()
    library_answer = lib({
        { name = "English", books = { book("/a", "finished"), book("/b", "reading") } },
        { name = "Portuguese", books = { book("/c", nil) } },
    })
    local card = settle(ctx())
    eq(card.card, nil, "must not be a valueCard")
    eq(card[1].text, "Atlas map · Languages")
    eq(card[5].text, "3 books · 1 finished · 2 languages")
    local grid = card[3]
    assert(grid.level, "the middle child should be the grid widget")
    eq(grid.label_mode, "truncate")
    eq(grid.level(1, 1), 4, "English's finished book comes first")
end)

t.test("the series axis says how many books were left out", function()
    library_answer = lib({ { name = "Discworld", books = { book("/a", "finished") } } },
        { book("/x"), book("/y") })
    local card = settle(ctx{ config = config{ axis = "series" } })
    eq(card[5].text, "1 book · 1 finished · 1 series · 2 not in a series")
end)

t.test("counts of one are singular", function()
    library_answer = lib({ { name = "English", books = { book("/a", "reading") } } })
    eq(settle(ctx())[5].text, "1 book · 0 finished · 1 language")
end)

t.test("an unknown stored axis falls back to languages", function()
    library_answer = lib({}, {})
    settle(ctx{ config = config{ axis = "planets" } })
    eq(library_axis, "language")
end)

t.test("the Add picker has no config and still renders", function()
    library_answer = lib({ { name = "English", books = { book("/a", "reading") } } })
    local c = ctx()
    c.config = nil
    local card = settle(c)
    eq(card[1].text, "Atlas map · Languages")
end)

t.test("each axis has its own cache", function()
    library_answer = lib({ { name = "English", books = { book("/a", "reading") } } })
    settle(ctx())
    scheduled = {}
    local card = Map.render(ctx{ config = config{ axis = "author" } })
    eq(card.value, "Reading…", "switching axis must query again")
end)

t.test("settings list the four axes and a pick stores the axis", function()
    shown_dialog = nil
    local c = ctx()
    Map.show_settings(c)
    assert(shown_dialog, "a dialog should be shown")
    eq(#shown_dialog.buttons, 4)
    eq(shown_dialog.buttons[1][1].text, "* Languages", "the current axis is checked")
    shown_dialog.buttons[3][1].pick()
    eq(c.config.values.axis, "series")
end)

t.test("settings without a config do nothing rather than raise", function()
    local c = ctx()
    c.config = nil
    Map.show_settings(c)
end)

t.done()
