-- Reading Atlas: when do I actually read? Hours across, weekdays down.
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local rows = atlas("source").get(refresh)

    if rows == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading clock"), value = _("Reading…") }
    end
    if rows == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading clock"), value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local grid_data = atlas("aggregate").byHourWeekday(rows)
    local values = {}
    for wday = 1, 7 do
        for hour = 0, 23 do
            values[#values + 1] = grid_data[wday][hour]
        end
    end
    local Scale = atlas("scale")
    local thresholds = Scale.thresholds(values)

    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))

    return GW.new{
        width = width,
        height = ctx.height or math.floor(width / 3),
        cols = 24,
        rows = 7,
        -- col 1 is hour 0; row 1 is Sunday, matching os.date wday.
        level = function(col, row)
            return Scale.level(grid_data[row][col - 1], thresholds)
        end,
    }
end

return {
    key     = "atlas_clock",
    title   = _("Reading clock"),
    summary = _("From KOReader statistics. Works offline."),
    render  = render,
}
