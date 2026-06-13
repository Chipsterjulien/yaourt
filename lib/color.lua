-- color.lua — coloration ANSI, pilotée par la config.
--
-- Usage :
--   local C = require("lib.color").new(config.color)
--   print(C.red("erreur"), C.green("ok"))
-- Si la couleur est désactivée, les fonctions renvoient la chaîne telle quelle.

local color = {}

local CODES = {
    reset   = "0",
    bold    = "1",
    dim     = "2",
    red     = "31",
    green   = "32",
    yellow  = "33",
    blue    = "34",
    magenta = "35",
    cyan    = "36",
    white   = "37",
}

function color.new(enabled)
    local self = {}
    for name, code in pairs(CODES) do
        self[name] = function(s)
            if not enabled then return s end
            return "\27[" .. code .. "m" .. s .. "\27[0m"
        end
    end
    return self
end

return color
