local _raw = require("gettext")
local Branding = require("booklore_branding")

local function _(text)
    return Branding.apply(_raw(text))
end
return {
    name = "bookloresync",
    fullname = _("Booklore Sync"),
    description = _([[Sync your reading sessions to Booklore server.]]),
    version = "0.0.0-dev+179f0b9",
}
