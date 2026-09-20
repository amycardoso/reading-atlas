-- Reading Atlas: a year of reading as a grid of days.
--
-- Drop this file, atlas_clock.lua and the atlas/ directory into
-- <koreader settings>/bookshelf/micromodules/ .
local DIR = debug.getinfo(1, "S").source:match("^@(.+/)") or "./"
local atlas = dofile(DIR .. "atlas/loader.lua").make(DIR)

local Kit = require("lib/bookshelf_module_kit")
local _ = require("lib/bookshelf_i18n").gettext

local function render(ctx)
    local width, scale_pct, refresh = ctx.width, ctx.scale, ctx.refresh
    local rows = atlas("source").get(refresh)

    if rows == nil then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading year"), value = _("Reading…") }
    end
    if rows == false then
        return Kit.valueCard{ width = width, scale_pct = scale_pct,
            heading = _("Reading year"), value = _("No statistics"),
            sub = _("KOReader's statistics plugin has no data yet.") }
    end

    local year = tonumber(os.date("%Y"))
    local by_day = atlas("aggregate").byDay(rows)
    local values = {}
    for _k, v in pairs(by_day) do values[#values + 1] = v end
    local Scale = atlas("scale")
    local thresholds = Scale.thresholds(values)

    local cal = atlas("calendar").columns(year)
    local GW = atlas("gridwidget")
    GW.setGrid(atlas("grid"))

    return GW.new{
        width = width,
        height = ctx.height or math.floor(width / 7),
        cols = cal.weeks,
        rows = 7,
        level = function(col, row)
            local key = cal.dayKey(col, row)
            if not key then return 0 end
            return Scale.level(by_day[key], thresholds)
        end,
    }
end

return {
    key     = "atlas_heatmap",
    title   = _("Reading year"),
    summary = _("From KOReader statistics. Works offline."),
    render  = render,
}
