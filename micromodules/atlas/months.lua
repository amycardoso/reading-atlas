-- Month abbreviations through bookshelf's gettext, shared by every card.
--
-- Not os.date("%b"): KOReader leaves LC_TIME in the C locale, so os.date
-- answers "Oct" whatever the UI language, and a Portuguese card would mix
-- "Out" in one place with "Oct" in another.
local _ = require("lib/bookshelf_i18n").gettext

return { _("Jan"), _("Feb"), _("Mar"), _("Apr"), _("May"), _("Jun"),
    _("Jul"), _("Aug"), _("Sep"), _("Oct"), _("Nov"), _("Dec") }
