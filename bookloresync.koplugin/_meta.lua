local _raw = require("gettext")
local ok_branding, Branding = pcall(require, "booklore_branding")
if not ok_branding or type(Branding) ~= "table" then
    Branding = {
        apply = function(text)
            return text
        end,
    }
end

local function _(text)
    return Branding.apply(_raw(text))
end
return {
    name = "bookloresync",
    fullname = _("Booklore Sync"),
    description = _([[Sync your reading sessions to Booklore server.]]),
    version = "0.0.0-dev",
}
