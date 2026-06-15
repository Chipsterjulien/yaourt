-- color.lua — coloration ANSI, pilotée par la config.
--
-- Usage :
--   local C = require("lib.color").new(config.color)
--   print(C.red("erreur"), C.green("ok"))
--   print(C.badge("43", "30", " 48 "))  -- texte noir sur fond jaune (combiné)
-- Si la couleur est désactivée, les fonctions renvoient la chaîne telle quelle.
--
-- Deux familles :
--   * les fonctions de style/couleur (C.red, C.bold, C.inverse, …), générées
--     depuis CODES ;
--   * C.badge(bg, fg, s) : combine un code de FOND et un code de TEXTE dans un
--     SEUL séquence ANSI (« \27[43;30m … \27[0m »). Indispensable pour un fond
--     qui « tient » : imbriquer deux fonctions (fond puis texte) couperait le
--     fond prématurément, car le reset interne (\27[0m) annule tout.

local color = {}

local CODES = {
    reset      = "0",
    bold       = "1",
    dim        = "2",
    inverse    = "7",
    red        = "31",
    green      = "32",
    yellow     = "33",
    blue       = "34",
    magenta    = "35",
    cyan       = "36",
    white      = "37",
    on_red     = "41",
    on_green   = "42",
    on_yellow  = "43",
    on_blue    = "44",
    on_magenta = "45",
    on_cyan    = "46",
    on_white   = "47",
}

function color.new(enabled)
    local self = {}
    for name, code in pairs(CODES) do
        self[name] = function(s)
            if not enabled then return s end
            return "\27[" .. code .. "m" .. s .. "\27[0m"
        end
    end

    -- Badge : fond + texte combinés en une seule séquence ANSI, pour que le
    -- fond reste appliqué sur toute la chaîne. bg/fg sont des codes ANSI
    -- (ex. "43" fond jaune, "30" texte noir).
    self.badge = function(bg, fg, s)
        if not enabled then return s end
        return "\27[" .. bg .. ";" .. fg .. "m" .. s .. "\27[0m"
    end

    return self
end

return color
