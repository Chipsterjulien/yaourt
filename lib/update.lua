-- update.lua — vue unifiée des mises à jour (dépôts + AUR).
--
-- Sources :
--   * dépôts : `checkupdates` (paquet pacman-contrib) — sûr, sans root,
--     rafraîchit une base de sync temporaire (pas d'upgrade partiel).
--   * AUR    : `pacman -Qm` (paquets étrangers) -> RPC info -> `vercmp`.
--
-- Affichage épuré façon yaourt : `dépôt/nom  ancienne -> nouvelle`, coloré
-- par dépôt. Puis invite [O/n]. Sur [O], upgrade des dépôts (tout-ou-rien)
-- via pacman ; le build des paquets AUR arrivera à l'étape suivante.

local aur    = require("lib.aur")
local build  = require("lib.build")
local color  = require("lib.color")
local log    = require("lib.log")
local util   = require("lib.util")

local update = {}

--------------------------------------------------------------------------
-- Collecte
--------------------------------------------------------------------------

-- Mises à jour des dépôts via checkupdates -> { {name, oldver, newver}, … }
local function repo_updates()
    if not luapilot.which("checkupdates") then
        log.warn("checkupdates introuvable (paquet pacman-contrib) — MAJ des dépôts ignorées")
        return {}
    end
    local res, err = util.run({ "checkupdates" })
    if not res then
        log.error("checkupdates: " .. tostring(err))
        return {}
    end
    -- code 2 = aucune MAJ (stdout vide) ; sinon lignes "name old -> new".
    local list = {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
        local name, oldv, newv = line:match("^(%S+)%s+(%S+)%s*%->%s*(%S+)")
        if name then
            list[#list + 1] = { name = name, oldver = oldv, newver = newv }
        end
    end
    return list
end

-- Carte nom -> dépôt (pour colorer core/extra/multilib…), via `pacman -Sl`.
local function repo_map()
    local res = util.run({ "pacman", "-Sl" })
    local m = {}
    if res and res.code == 0 then
        for line in (res.stdout or ""):gmatch("[^\n]+") do
            local repo, name = line:match("^(%S+)%s+(%S+)")
            if repo and name then m[name] = repo end
        end
    end
    return m
end

-- Un champ JSON peut être absent (nil) ou explicitement null (sentinelle).
local function isset(v)
    return v ~= nil and v ~= luapilot.json.null
end

-- Statut de TOUS les paquets AUR installés (pacman -Qm -> info RPC).
-- Renvoie une liste triée d'entrées :
--   { name, repo="aur", oldver, in_aur, newver, has_update, orphan, outofdate }
-- On interroge l'AUR une seule fois ; les MAJ ET la liste complète en dérivent.
local function aur_status(config)
    local res = util.run({ "pacman", "-Qm" })
    if not res or res.code ~= 0 then return {} end

    local installed, names = {}, {}
    for line in (res.stdout or ""):gmatch("[^\n]+") do
        local name, ver = line:match("^(%S+)%s+(%S+)")
        if name then
            installed[name] = ver
            names[#names + 1] = name
        end
    end
    if #names == 0 then return {} end

    local infos, err = aur.info(config, names)
    if not infos then
        log.warn("AUR: " .. tostring(err))
        infos = {}
    end

    local list = {}
    for _, name in ipairs(names) do
        local entry = infos[name]
        local e = { name = name, repo = "aur", oldver = installed[name], in_aur = entry ~= nil }

        if entry then
            e.newver     = entry.Version
            e.orphan     = not isset(entry.Maintainer)
            e.outofdate  = isset(entry.OutOfDate)
            e.has_update = util.vercmp(installed[name], entry.Version) == -1
        end
        local is_debug_subproduct = not e.in_aur and e.name:match("%-debug$") ~= nil
        if not is_debug_subproduct then
            list[#list + 1] = e
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- check(config) -> (repos[], auras[], aurall[])
--   repos  : MAJ des dépôts (champ .repo renseigné)
--   auras  : paquets AUR à mettre à jour (sous-ensemble de aurall)
--   aurall : statut de TOUS les paquets AUR installés (pour la liste optionnelle)
function update.check(config)
    local repos = repo_updates()
    if #repos > 0 then
        local rmap = repo_map()
        for _, u in ipairs(repos) do u.repo = rmap[u.name] or "repo" end
    end
    table.sort(repos, function(a, b)
        if a.repo ~= b.repo then return a.repo < b.repo end
        return a.name < b.name
    end)

    local aurall = aur_status(config)
    local auras = {}
    for _, e in ipairs(aurall) do
        if e.has_update then auras[#auras + 1] = e end
    end

    return repos, auras, aurall
end

--------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------

local function repo_color(C, repo)
    if repo == "core" then
        return C.red
    elseif repo == "extra" then
        return C.green
    elseif repo == "multilib" then
        return C.cyan
    elseif repo == "aur" then
        return C.magenta
    else
        return C.blue
    end
end

-- Découpe une version pacman en (partie ver, pkgrel). pkgver ne peut pas
-- contenir de '-' : on coupe donc au dernier tiret. La « partie ver »
-- inclut l'éventuelle épochε (préfixe "N:").
local function ver_part(s)
    return s:match("^(.-)%-[^-]+$") or s
end

-- Révision = seul le pkgrel a changé (même pkgver / épochε).
local function is_revision(oldv, newv)
    return ver_part(oldv) == ver_part(newv)
end

function update.display(config, repos, auras)
    local C = color.new(config.color)

    local all = {}
    for _, u in ipairs(repos) do all[#all + 1] = u end
    for _, u in ipairs(auras) do all[#all + 1] = u end

    if #all == 0 then
        print(":: Le système est à jour.")
        return
    end

    -- Partition : révisions (bump de pkgrel) vs vraies nouvelles versions.
    local revs, vers = {}, {}
    for _, u in ipairs(all) do
        if is_revision(u.oldver, u.newver) then
            revs[#revs + 1] = u
        else
            vers[#vers + 1] = u
        end
    end

    -- Largeurs visibles (hors codes ANSI), calculées sur l'ensemble pour
    -- que les deux sections restent alignées entre elles.
    local wname, wold, wnew = 0, 0, 0
    for _, u in ipairs(all) do
        local label = u.repo .. "/" .. u.name
        if #label > wname then wname = #label end
        if #u.oldver > wold then wold = #u.oldver end
        if #u.newver > wnew then wnew = #u.newver end
    end

    local function line(u)
        local rc      = repo_color(C, u.repo)
        local visible = #(u.repo .. "/" .. u.name)
        local label   = rc(u.repo .. "/") .. u.name
        local namepad = string.rep(" ", wname - visible)
        local oldpad  = string.rep(" ", wold - #u.oldver)
        local newpad  = string.rep(" ", wnew - #u.newver)
        -- Drapeaux à droite (AUR uniquement) : bien visibles.
        local flags   = ""
        if u.orphan then flags = flags .. "  " .. C.yellow("(orphelin)") end
        if u.outofdate then flags = flags .. "  " .. C.red("(périmé)") end
        print(string.format("  %s%s  %s%s %s %s%s%s",
            label, namepad, u.oldver, oldpad, C.dim("->"), C.green(u.newver), newpad, flags))
    end

    if #revs > 0 then
        print(C.cyan("==> Nouvelle révision des paquets (" .. #revs .. ") :"))
        for _, u in ipairs(revs) do line(u) end
    end
    if #vers > 0 then
        if #revs > 0 then print("") end
        print(C.cyan("==> Mise à jour des logiciels (nouvelle version) (" .. #vers .. ") :"))
        for _, u in ipairs(vers) do line(u) end
    end
end

-- Liste complète des paquets AUR installés avec leur statut (option config).
-- Reproduit le « <nom> : à jour / Orphelin / périmé » de yaourt.
function update.list_aur(config, aurall)
    if #aurall == 0 then return end
    local C = color.new(config.color)

    local function line(e, wname)
        local pad = string.rep(" ", wname - #e.name)
        local status
        if e.has_update then
            status = C.green(e.oldver .. " -> " .. e.newver)
        else
            status = "à jour"
        end
        local flags = ""
        if e.orphan then flags = flags .. "  " .. C.yellow("Orphelin") end
        if e.outofdate then flags = flags .. "  " .. C.red("(périmé)") end

        print(string.format("  %s%s : %s%s", C.magenta(e.name), pad, status, flags))
    end

    -- Déterminer le mot le plus long et sauvegarder la taille
    local wname = 0
    for _, e in ipairs(aurall) do
        if #e.name > wname then wname = #e.name end
    end

    local notinaur, inaur = {}, {}

    for _, e in ipairs(aurall) do
        if e.in_aur then
            inaur[#inaur+1] = e
        else
            notinaur[#notinaur+1] = e
        end
    end

    if #inaur > 0 then
        print(C.cyan("==> Paquets gérés par AUR (" .. #inaur .. ")"))
        for _, v in ipairs(inaur) do
            line(v, wname)
        end
    end

    if #notinaur > 0 then
        if #inaur > 0 then print("") end

        local notinaur_names = {}
        for _, v in ipairs(notinaur) do
            notinaur_names[#notinaur_names+1] = v.name
        end

        print(C.cyan("==> Paquets non gérés par AUR (" .. #notinaur .. ")"))
        print(C.dim(table.concat(notinaur_names, " ")))
        print("")
    end
end

--------------------------------------------------------------------------
-- Orchestration
--------------------------------------------------------------------------

function update.run(config)
    local repos, auras, aurall = update.check(config)
    -- Option : lister tous les paquets AUR installés avec leur statut.
    if config.list_aur then
        update.list_aur(config, aurall)
    end
    update.display(config, repos, auras)
    if #repos == 0 and #auras == 0 then return 0 end

    local C = color.new(config.color)
    io.write("\n" .. C.cyan("==> Continuer la mise à jour ? [O/n] "))
    io.flush()
    local ans = (io.read("l") or ""):lower()
    if ans == "n" or ans == "non" then
        print("Annulé.")
        return 0
    end
    -- [M]anuel : sélection à la carte des paquets AUR -> à venir.

    -- Dépôts : upgrade complet et sûr (tout-ou-rien). pacman gère sa propre
    -- confirmation finale.
    if #repos > 0 then
        local code = util.passthrough({ config.sudo or "sudo", "pacman", "-Syu" })
        if code ~= 0 then return code end
    end

    local collect = {}
    if #auras > 0 then
        for _, u in ipairs(auras) do
            local ok, err = build.one(config, u.name)
            if not ok then collect[#collect+1] = {name = u.name, error = err} end
        end
        print(C.green("\n==> " .. #auras-#collect .. " paquet(s) AUR installé(s) avec succès"))
        if #collect > 0 then
            print(C.red("==> Échecs (" .. #collect .. ") :"))
            for _, pkg in ipairs(collect) do
                print(C.red("\t" .. pkg.name .. " : " .. tostring(pkg.error)))
            end
        end
        return #collect == 0 and 0 or 1
    end

    return 0
end

return update
