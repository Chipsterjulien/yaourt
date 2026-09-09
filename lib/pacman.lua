-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- pacman.lua — délégation à pacman.
--
-- Tant qu'une opération n'est pas portée nativement, on la passe à pacman.
-- On préfixe sudo pour les opérations qui modifient le système.

local util   = require("lib.util")
local log    = require("lib.log")
local i18n   = require("lib.i18n")

local pacman = {}

local function needs_root(argv)
    local parsed = require("lib.cli").parse(argv)
    local flags = parsed.flags
    -- Native long operations must receive the same privilege handling.
    for _, a in ipairs(argv) do
        if a == "--remove" or a == "--upgrade" or a == "--database" then return true end
    end
    if flags.R or flags.U or flags.D then return true end
    if flags.S then
        if flags.y then return true end
        if flags.p or flags.s or flags.i or flags.l or flags.g then return false end
        return true
    end
    return flags.F and flags.y ~= nil or false
end

-- argv = tous les arguments utilisateur (le premier est l'opération).
function pacman.passthrough(config, argv)
    if not babet.which("pacman") then
        log.error(i18n.t("command.not_found", { command = "pacman" }))
        return 1
    end

    local cmd = {}
    if needs_root(argv) then
        local p = util.sudo_prefix(config)
        if p then cmd[#cmd + 1] = p end
    end
    cmd[#cmd + 1] = "pacman"
    for _, a in ipairs(argv) do cmd[#cmd + 1] = a end

    return util.passthrough(cmd)
end

-- Preserve explicit reasons when a repository build dependency is upgraded.
-- --asdeps applies to every target, including previously installed packages.
function pacman.explicit_packages()
    local query, err = util.run({"pacman", "-Qqe"}, {env={LC_ALL="C"}})
    if not util.complete(query) and not (query and query.code==1 and query.stdout=="" and query.stderr==""
            and not query.timed_out and not query.stdout_truncated) then
        return nil, err or (query and query.stderr) or "pacman -Qqe", query and query.code or 1
    end
    local names={}
    for name in query.stdout:gmatch("[^\n]+") do names[name]=true end
    return names
end
function pacman.install_dependencies(config, targets, opts)
    local before, err, code=pacman.explicit_packages()
    if not before then return code~=0 and code or 1,err end
    local argv={"-S","--asdeps","--needed"}
    if opts and opts.noconfirm then argv[#argv+1]="--noconfirm" end
    for _,name in ipairs(targets) do argv[#argv+1]=name end
    code=pacman.passthrough(config,argv)
    if code~=0 or next(before)==nil then return code end
    local after, qerr=util.run({"pacman","-Qdq"},{env={LC_ALL="C"}})
    if not util.complete(after) and not (after and after.code==1 and after.stdout=="" and after.stderr=="") then
        return after and after.code~=0 and after.code or 1,qerr or (after and after.stderr)
    end
    local restore={}
    for name in after.stdout:gmatch("[^\n]+") do if before[name] then restore[#restore+1]=name end end
    table.sort(restore)
    if #restore>0 then return pacman.passthrough(config,babet.mergeTables({"-D","--asexplicit"},restore)) end
    return 0
end

return pacman
