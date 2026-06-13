-- pacman.lua — délégation à pacman.
--
-- Tant qu'une opération n'est pas portée nativement, on la passe à pacman.
-- On préfixe sudo pour les opérations qui modifient le système.

local util   = require("lib.util")
local log    = require("lib.log")

local pacman = {}

-- Heuristique simple de détection root à partir du flag d'opération court
-- (ex. "-Syu", "-Rns", "-Ss"). Suffisant pour le squelette ; à affiner.
local function needs_root(op)
    local main = op:match("^%-(%u)")
    if not main then return false end -- ex. "--help" non concerné ici
    if main == "R" or main == "U" or main == "D" then
        return true
    end
    if main == "S" then
        -- y (refresh) ou u (sysupgrade) -> root.
        if op:find("y") or op:find("u") then return true end
        -- variantes lecture seule : search/info/list/group/print/query.
        if op:find("[silgpq]") then return false end
        -- -S nu : installation -> root.
        return true
    end
    return false
end

-- argv = tous les arguments utilisateur (le premier est l'opération).
function pacman.passthrough(config, argv)
    if not luapilot.which("pacman") then
        log.error("pacman introuvable dans le PATH")
        return 1
    end

    local cmd = {}
    if needs_root(argv[1] or "") then
        cmd[#cmd + 1] = config.sudo or "sudo"
    end
    cmd[#cmd + 1] = "pacman"
    for _, a in ipairs(argv) do cmd[#cmd + 1] = a end

    return util.passthrough(cmd)
end

return pacman
