-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- help.lua — mise en forme de l'aide sans exposer sa structure aux catalogues.

local i18n = require("lib.i18n")

local help = {}

local rows = {
    { "yaourt <pacman operations>", "help.delegate" },
    { "yaourt -S <package>...",     "help.install" },
    { "yaourt -Ss <term>",          "help.search" },
    { "yaourt -Syu | -Su",          "help.update" },
    { "yaourt -Sc | -Scc",          "help.clean" },
    { "yaourt -G <package>...",     "help.get_build_files" },
    { "yaourt -h | --help",         "help.show_help" },
    { "yaourt -V | --version",      "help.show_version" },
}

local width = 0
for _, row in ipairs(rows) do
    if #row[1] > width then width = #row[1] end
end

-- Un catalogue .mo externe n'est pas passé par tools/compile_catalogs.py.
-- Neutraliser ici ses espaces de contrôle empêche une traduction défectueuse
-- de réintroduire des lignes ou des tabulations dans le tableau de commandes.
local function one_line(value)
    value = tostring(value or ""):gsub("%s+", " ")
    return value:match("^%s*(.-)%s*$")
end

function help.render(name, version)
    local lines = {
        one_line(i18n.t("help.title", { name = name, version = version })),
        "",
        one_line(i18n.t("help.usage")),
    }

    for _, row in ipairs(rows) do
        local command, key = row[1], row[2]
        lines[#lines + 1] = "  " .. command
            .. string.rep(" ", width - #command + 2)
            .. one_line(i18n.t(key))
    end

    return table.concat(lines, "\n") .. "\n"
end

function help.commands()
    local commands = {}
    for index, row in ipairs(rows) do commands[index] = row[1] end
    return commands
end

return help
