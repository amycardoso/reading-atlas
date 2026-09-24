-- Two things are testable off-device: the size contract, and that the object
-- is a real KOReader Widget.
--
-- The second one is here because its absence crashed a Kindle. The widget was
-- once a bare table with getSize/paintTo. It painted correctly -- every test
-- and every review passed -- and then the first event a container propagated
-- into it called a nil handleEvent, the error escaped the UI loop, and
-- KOReader died to the launcher. Painting correctly is not the same as being
-- a widget.
package.path = "./?.lua;./?/init.lua;" .. package.path

local H = dofile("tests/_helpers.lua")
local t = H.runner()
local eq = H.eq

-- Stub the two KOReader modules the widget pulls in at load.
package.loaded["ui/geometry"] = {
    new = function(_, o) return o end,
}
package.loaded["ffi/blitbuffer"] = {
    Color8 = function(v) return { v = v } end,
}
-- Mimics KOReader's Widget closely enough to matter: extend/new with
-- inheritance, init called on construction, and the protocol methods a
-- container will reach for.
local WidgetStub = {}
function WidgetStub:extend(subclass)
    subclass = subclass or {}
    setmetatable(subclass, { __index = self })
    return subclass
end
function WidgetStub:new(o)
    o = o or {}
    setmetatable(o, { __index = self })
    if o.init then o:init() end
    return o
end
function WidgetStub:handleEvent() return false end
function WidgetStub:free() end
function WidgetStub:onCloseWidget() end
package.loaded["ui/widget/widget"] = WidgetStub
-- TextWidget stub: every glyph is 6x10 at scale 1, and painting is recorded so
-- a test can assert which labels actually landed.
local painted = {}
package.loaded["ui/widget/textwidget"] = {
    new = function(_, o)
        o = o or {}
        o.getSize = function(self) return { w = #(self.text or "") * 6, h = 10 } end
        o.paintTo = function(self, _bb, x)
            painted[#painted + 1] = { text = self.text, x = x, max_width = self.max_width }
        end
        o.free = function() end
        return o
    end,
}
-- The real grid module, injected explicitly by the label tests below. An
-- earlier test installs a fake one through setGrid to prove per-instance
-- isolation, and that fake stays as the module default -- so any later test
-- that cares about real geometry must say so rather than inherit it.
local REAL_GRID = dofile("micromodules/atlas/grid.lua")

local function paintedLabels(w)
    painted = {}
    w:paintTo({ paintRect = function() end }, 0, 0)
    return painted
end

local GW = dofile("micromodules/atlas/gridwidget.lua")

t.test("getSize matches the grid extent", function()
    local Grid = dofile("micromodules/atlas/grid.lua")
    local want = Grid.layout{ width = 400, height = 200, cols = 10, rows = 5 }
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    local size = w:getSize()
    eq(size.w, want.w)
    eq(size.h, want.h)
end)

t.test("exposes one ink value per step, 0 through 4", function()
    for lv = 0, 4 do
        assert(GW.INK[lv] ~= nil, "no ink for level " .. lv)
    end
end)

t.test("ink darkens monotonically as the level rises", function()
    for lv = 1, 4 do
        assert(GW.INK[lv] < GW.INK[lv - 1],
            ("level %d should be darker than %d"):format(lv, lv - 1))
    end
end)

t.test("step 0 is grey, not white: an unread day stays part of the grid", function()
    assert(GW.INK[0] < 255, "level 0 must not be pure white")
end)

t.test("per-instance grid injection via opts.grid", function()
    local fakeGrid = {
        layout = function()
            return { cell = 10, gap = 2, w = 123, h = 45 }
        end
    }
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end,
                      grid = fakeGrid }
    local size = w:getSize()
    eq(size.w, 123)
    eq(size.h, 45)
end)

t.test("isolation: widget unaffected by setGrid after creation", function()
    local fakeGrid1 = {
        layout = function()
            return { cell = 10, gap = 2, w = 100, h = 50 }
        end
    }
    local fakeGrid2 = {
        layout = function()
            return { cell = 5, gap = 1, w = 200, h = 100 }
        end
    }
    GW.setGrid(fakeGrid1)
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    local size1 = w:getSize()
    eq(size1.w, 100)
    eq(size1.h, 50)

    GW.setGrid(fakeGrid2)
    local size2 = w:getSize()
    eq(size2.w, 100)
    eq(size2.h, 50)
end)

t.test("the returned object IS a Widget, not a bare table", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    -- These are inherited, never defined in gridwidget.lua. If someone goes
    -- back to returning a plain table, every one of them becomes nil and this
    -- test fails instead of the user's e-reader.
    for _, method in ipairs({ "handleEvent", "free", "onCloseWidget" }) do
        assert(type(w[method]) == "function",
            "widget is missing " .. method .. " -- is it still Widget:extend?")
    end
end)

t.test("a propagated event does not raise", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      level = function() return 0 end }
    local ok, err = pcall(function() return w:handleEvent({ handler = "onTap" }) end)
    assert(ok, "handleEvent raised: " .. tostring(err))
end)

t.test("the label strip comes out of the height budget, not on top of it", function()
    -- This is the invariant that matters: whatever the caller stacks below the
    -- grid must still fit. Reporting grid + labels ABOVE the budget pushes the
    -- caller's own lines off the bottom of the card, which is how the clock
    -- card lost its context line on a real Kindle.
    local BUDGET = 200
    local bare = GW.new{ width = 400, height = BUDGET, cols = 10, rows = 5,
                         grid = REAL_GRID, level = function() return 0 end }
    local labelled = GW.new{ width = 400, height = BUDGET, cols = 10, rows = 5,
                             grid = REAL_GRID, level = function() return 0 end,
                             col_labels = { { col = 1, text = "jan" } },
                             face = "FACE" }
    assert(labelled:getSize().h <= BUDGET,
        "total height " .. labelled:getSize().h .. " exceeded the budget " .. BUDGET)
    assert(labelled.geom.h < bare.geom.h,
        "the grid must shrink to make room for the labels")
    -- The width may well shrink: cells are square, so a grid given less height
    -- gets smaller cells and therefore a narrower extent. What must never
    -- happen is exceeding the width it was given.
    assert(labelled:getSize().w <= 400,
        "width " .. labelled:getSize().w .. " exceeded the 400 it was given")
end)

t.test("labels are skipped rather than drawn on top of each other", function()
    -- Three labels one column apart in a grid whose cells are far narrower
    -- than the text: only the ones that clear the previous may be drawn.
    local w = GW.new{ width = 120, height = 120, cols = 40, rows = 7,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      col_labels = { { col = 1, text = "jan" },
                                     { col = 2, text = "fev" },
                                     { col = 3, text = "mar" } } }
    local got = paintedLabels(w)
    assert(#got < 3, "expected collisions to be skipped, drew " .. #got)
    assert(#got >= 1, "at least the first label should be drawn")
end)

t.test("a label that would overflow the grid's right edge is not drawn", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      col_labels = { { col = 10, text = "dezembro" } } }
    eq(#paintedLabels(w), 0, "label wider than the remaining room must be skipped")
end)

t.test("without labels nothing is painted as text", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      grid = REAL_GRID, level = function() return 0 end }
    eq(#paintedLabels(w), 0)
end)

t.test("when labels do not all fit, the drawn ones are a REGULAR subset", function()
    -- Twelve months across a grid too narrow for all of them. Dropping
    -- whichever ones happen to collide leaves ragged gaps that read as a bug
    -- (a real card showed Jan Feb _ Apr _ Jun _ Aug Sep _ Nov Dec). A regular
    -- stride reads as a deliberate choice instead.
    local labels = {}
    for m = 1, 12 do
        labels[m] = { col = 1 + (m - 1) * 4, text = ("M%d"):format(m) }
    end
    local w = GW.new{ width = 260, height = 160, cols = 48, rows = 7,
                      grid = REAL_GRID, level = function() return 0 end,
                      face = "FACE", col_labels = labels }
    local got = paintedLabels(w)
    assert(#got >= 2, "expected at least two labels, drew " .. #got)
    assert(#got < 12, "this case is supposed to be too narrow for all twelve")

    local idx = {}
    for _, painted_label in ipairs(got) do
        idx[#idx + 1] = tonumber(painted_label.text:match("%d+"))
    end
    local stride = idx[2] - idx[1]
    for i = 2, #idx do
        eq(idx[i] - idx[i - 1], stride,
            "labels must be evenly spaced, got stride " .. (idx[i] - idx[i - 1]))
    end
    eq(idx[1], 1, "a regular subset starts at the first label")
end)

-- Records every rect painted, so a test can see which cells were left blank.
local function paintedRects(w)
    local rects = {}
    w:paintTo({ paintRect = function(_, x, y, cw, ch, color)
        rects[#rects + 1] = { x = x, y = y, v = color.v }
    end }, 0, 0)
    return rects
end

t.test("level() returning nil leaves that cell unpainted", function()
    -- The territory map's blank separator columns depend on this: a blank
    -- must not paint as step 0, or it reads as an unread book.
    local w = GW.new{ width = 400, height = 200, cols = 3, rows = 1, grid = REAL_GRID,
                      level = function(col) if col == 2 then return nil end return 4 end }
    local rects = paintedRects(w)
    eq(#rects, 2, "only the two non-nil cells should paint")
    local step = w.geom.cell + w.geom.gap
    eq(rects[1].x, 0)
    eq(rects[2].x, 2 * step, "column 2 must be skipped, not shifted")
end)

t.test("level 0 still paints, as the lightest grey", function()
    local w = GW.new{ width = 400, height = 200, cols = 2, rows = 1, grid = REAL_GRID,
                      level = function() return 0 end }
    local rects = paintedRects(w)
    eq(#rects, 2, "step 0 is a real cell and must be painted")
    eq(rects[1].v, GW.INK[0])
end)

t.test("truncate mode draws every label, each capped at its own width", function()
    -- The same crowded strip that the default mode thins out: here nothing
    -- may be skipped, because a territory without a name is unreadable.
    local w = GW.new{ width = 120, height = 120, cols = 40, rows = 7,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      label_mode = "truncate",
                      col_labels = { { col = 1, text = "Portuguese", width = 20 },
                                     { col = 5, text = "English", width = 15 },
                                     { col = 9, text = "Spanish", width = 30 } } }
    local got = paintedLabels(w)
    eq(#got, 3, "truncate mode must never skip a label")
    eq(got[1].max_width, 20)
    eq(got[2].max_width, 15)
    eq(got[3].max_width, 30)
    local step = w.geom.cell + w.geom.gap
    eq(got[2].x, 4 * step, "a label sits at its own column")
end)

t.test("the default mode passes no max_width, so month labels are unchanged", function()
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      col_labels = { { col = 1, text = "jan" } } }
    local got = paintedLabels(w)
    eq(#got, 1)
    eq(got[1].max_width, nil)
end)

t.test("GW.labelHeight(face) matches the strip a labelled widget reserves", function()
    -- atlas_map solves its layout against (budget - GW.labelHeight(face)); if
    -- this drifts from what init() takes off, the map's plan and the painted
    -- grid disagree about the cell size.
    local w = GW.new{ width = 400, height = 200, cols = 10, rows = 5,
                      grid = REAL_GRID, level = function() return 0 end, face = "FACE",
                      col_labels = { { col = 1, text = "jan" } } }
    eq(GW.labelHeight("FACE"), w:labelHeight())
end)

t.done()
