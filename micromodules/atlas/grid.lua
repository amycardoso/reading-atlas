-- Cell geometry for a cols x rows grid inside a box.
--
-- Integer pixels only: e-ink has no subpixels, and a fractional cell would
-- make neighbouring columns differ by a pixel in a way that reads as a wobble.
local M = {}

local DEFAULT_GAP_RATIO = 0.18

function M.layout(opts)
    local cols = math.max(1, opts.cols or 1)
    local rows = math.max(1, opts.rows or 1)
    local ratio = opts.gap_ratio or DEFAULT_GAP_RATIO
    local width = math.max(0, opts.width or 0)
    local height = math.max(0, opts.height or 0)

    -- Solve cell from each dimension independently, then take the tighter.
    -- With gap = cell * ratio: extent = cell * n + cell * ratio * (n - 1).
    local function cellFor(extent, n)
        local denom = n + ratio * (n - 1)
        return math.floor(extent / denom)
    end

    local cell = math.min(cellFor(width, cols), cellFor(height, rows))
    -- Never return an unpaintable cell. A 1px grid in a 10px box overflows
    -- the box, and that is correct: the host clips as its documented
    -- backstop, and a visible sliver beats an invisible card.
    if cell < 1 then cell = 1 end

    local gap = math.floor(cell * ratio)
    if cell > 2 and gap < 1 then gap = 1 end

    -- Only one cell means no gaps at all
    if cols == 1 and rows == 1 then
        gap = 0
    end

    return {
        cell = cell,
        gap  = gap,
        w    = cell * cols + gap * (cols - 1),
        h    = cell * rows + gap * (rows - 1),
    }
end

return M
