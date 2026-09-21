-- Five intensity steps, 0..4.
--
-- Step 0 means "did not read". Steps 1..4 are quartiles of the values that
-- are > 0, so the scale is relative to the reader's own history. Absolute
-- minute thresholds were rejected in the design: they make a light reader's
-- year look empty and a heavy reader's look uniformly full.
local M = {}

-- Returns the three quartile cuts of the positive values, or nil when there
-- are none. Cuts are read off the sorted values by position, which needs no
-- interpolation and behaves sanely on tiny samples.
function M.thresholds(values)
    local pos = {}
    for i = 1, #values do
        if values[i] and values[i] > 0 then pos[#pos + 1] = values[i] end
    end
    if #pos == 0 then return nil end
    table.sort(pos)
    local function at(fraction)
        local idx = math.floor(#pos * fraction + 0.5)
        if idx < 1 then idx = 1 end
        if idx > #pos then idx = #pos end
        return pos[idx]
    end
    return { at(0.25), at(0.50), at(0.75) }
end

-- 0 for no reading; otherwise 1..4.
function M.level(value, thresholds)
    if not value or value <= 0 then return 0 end
    -- No thresholds but real reading: show the lowest INK level, never blank.
    -- Painting a day that had reading as empty is the one error a heatmap
    -- must not make.
    if not thresholds then return 1 end
    if value <= thresholds[1] then return 1 end
    if value <= thresholds[2] then return 2 end
    if value <= thresholds[3] then return 3 end
    return 4
end

return M
