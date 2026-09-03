-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- pacdiff.lua — gestion interactive des fichiers .pacnew/.pacsave/.pacorig.

local i18n = require("lib.i18n")
local log  = require("lib.log")
local util = require("lib.util")

local pacdiff = {}

local function has_option(args, short, long)
    for _, value in ipairs(args or {}) do
        if value == short or value == long then return true end
    end
    return false
end

-- Exécute l'outil officiel pacdiff de pacman-contrib dans le terminal courant.
-- En utilisateur non privilégié, --sudo laisse pacdiff lire sans privilège et
-- n'élève que les modifications via sudo/sudoedit.
function pacdiff.run(config, args)
    args = args or {}

    if not babet.which("pacdiff") then
        log.error(i18n.t("pacdiff.not_found"))
        return 1
    end

    local argv = { "pacdiff" }
    if not util.is_root() and not has_option(args, "-s", "--sudo") then
        argv[#argv + 1] = "--sudo"
    end
    if config and config.color == false
            and not has_option(args, "", "--nocolor") then
        argv[#argv + 1] = "--nocolor"
    end
    for _, value in ipairs(args) do argv[#argv + 1] = value end

    local code, err = util.passthrough(argv)
    if err then
        log.error(i18n.t("common.named_error", {
            name = "pacdiff",
            error = tostring(err),
        }))
    end
    return code or 1
end

return pacdiff
