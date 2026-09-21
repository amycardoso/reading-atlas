-- A cols x rows grid of filled cells, painted straight into the blitbuffer.
--
-- Follows bookshelf's analogue_clock: a plain table with getSize() and
-- paintTo(bb, x, y). There is no polygon fill in KOReader, and none is
-- needed -- every cell is a rectangle.
--
-- The caller supplies level(col, row) -> 0..4 rather than a data table, so
-- this one widget paints both the day heatmap and the hour x weekday clock.
local Geom = require("ui/geometry")
local Blitbuffer = require("ffi/blitbuffer")

local Grid = nil  -- injected below by the spec files' loader, or dofile'd

local M = {}

-- Luminance per step, light to dark. Five steps is the ceiling for what is
-- reliably distinguishable on e-ink at this cell size; step 0 is a light grey
-- rather than white so a day without reading still reads as a cell.
M.INK = { [0] = 0xE0, [1] = 0xB0, [2] = 0x80, [3] = 0x50, [4] = 0x20 }

-- `grid_mod` lets callers hand in the already-loaded Grid helper. Falls back
-- to a sibling dofile so this file also works standalone in tests.
function M.setGrid(grid_mod) Grid = grid_mod end

local function resolveGrid(opts)
    -- Per-instance resolution: opts.grid takes precedence, then module-level
    -- default (set by setGrid), then sibling dofile fallback.
    if opts.grid then return opts.grid end
    if Grid then return Grid end
    local dir = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
    return dofile(dir .. "grid.lua")
end

function M.new(opts)
    local gridMod = resolveGrid(opts)
    local g = gridMod.layout{
        width = opts.width, height = opts.height,
        cols = opts.cols, rows = opts.rows,
        gap_ratio = opts.gap_ratio,
    }
    local w = {
        cols = opts.cols, rows = opts.rows,
        level = opts.level,
        grid = gridMod,
        geom = g,
        dimen = Geom:new{ w = g.w, h = g.h },
    }
    function w:getSize() return Geom:new{ w = g.w, h = g.h } end
    function w:paintTo(bb, x, y)
        self.dimen = Geom:new{ x = x, y = y, w = g.w, h = g.h }
        local step = g.cell + g.gap
        for col = 1, self.cols do
            for row = 1, self.rows do
                local lv = self.level(col, row) or 0
                bb:paintRect(x + (col - 1) * step, y + (row - 1) * step,
                    g.cell, g.cell, Blitbuffer.Color8(M.INK[lv] or M.INK[0]))
            end
        end
    end
    return w
end

return M
