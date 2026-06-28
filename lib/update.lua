-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- update.lua — vue unifiée des mises à jour (dépôts + AUR).
--
-- Sources :
--   * dépôts : synchro réelle des bases (`pacman -Sy`, root, visible) puis
--     `pacman -Qu` pour lister les mises à jour disponibles. L'application se
--     fait ensuite avec `pacman -Su` (la synchro est déjà faite). Plus de
--     dépendance à `checkupdates`/pacman-contrib.
--   * AUR    : `pacman -Qm` (paquets étrangers) -> RPC info -> `vercmp`.
--
-- Affichage épuré façon yaourt : `dépôt/nom  ancienne -> nouvelle`, coloré
-- par dépôt. Puis invite [O/n]. Sur [O], upgrade des dépôts (tout-ou-rien)
-- via pacman, puis build des paquets AUR (build.aur).
--
-- Note : l'utilisateur tape son mot de passe AVANT l'affichage (le -Sy est
-- root). S'il refuse à l'invite, les bases ont été synchronisées mais rien
-- n'est appliqué — comportement assumé pour un -Syu.

local aur     = require("lib.aur")
local build   = require("lib.build")
local color   = require("lib.color")
local log     = require("lib.log")
local util    = require("lib.util")
local display = require("lib.display")

local update  = {}

--------------------------------------------------------------------------
-- Collecte
--------------------------------------------------------------------------

-- Mises à jour des dépôts via une vraie synchro puis `pacman -Qu`.
-- Approche « façon yaourt » : on rafraîchit réellement les bases (pacman -Sy,
-- en root, avec barres de progression visibles), PUIS on liste les paquets
-- pouvant être mis à jour (pacman -Qu). L'application se fera ensuite avec
-- `pacman -Su` seul (la synchro est déjà faite) — voir update.run.
-- Renvoie { {name, oldver, newver}, … }.
local function repo_updates(config)
    -- 1) Synchro réelle des bases (root, interactif pour voir la progression).
    local sync = {}
    local p = util.sudo_prefix(config)
    if p then sync[#sync + 1] = p end
    sync[#sync + 1] = "pacman"
    sync[#sync + 1] = "-Sy"
    local code = util.passthrough(sync)
    if code ~= 0 then
        log.error("échec de la synchronisation des bases (pacman -Sy)")
        return {}
    end

    -- 2) Détection des MAJ disponibles (pacman -Qu, capturé).
    -- Format : « nom ancienne -> nouvelle ». Code non nul si aucune MAJ.
    local res = util.run({ "pacman", "-Qu" })
    if not res then
        return {}
    end
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
            e.orphan     = not util.isset(entry.Maintainer)
            e.outofdate  = util.isset(entry.OutOfDate)
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
    local repos = repo_updates(config)
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
        local rc      = display.repo_color(C, u.repo)
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
            inaur[#inaur + 1] = e
        else
            notinaur[#notinaur + 1] = e
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
            notinaur_names[#notinaur_names + 1] = v.name
        end

        print(C.cyan("==> Paquets non gérés par AUR (" .. #notinaur .. ")"))
        print(C.dim(table.concat(notinaur_names, " ")))
        print("")
    end
end

--------------------------------------------------------------------------
-- Orchestration
--------------------------------------------------------------------------

-- parse_selection(input, max) -> table {indice = true, …}
-- Analyse une saisie de sélection : numéros isolés et plages, séparés par des
-- espaces ou des virgules. Ex. « 1 3 5 », « 1-4 », « 1-3, 5 ». Les indices hors
-- de [1, max] sont ignorés silencieusement. Renvoie l'ensemble des indices
-- retenus (vide si rien de valide).
-- parse_selection(input, max) -> table { [indice] = true } des éléments choisis.
-- Inclusion : numéros et plages (« 1 3 5 », « 1-4 », « 1-3, 5 »).
-- Exclusion : préfixe « ^ » pour retirer (« ^4 », « ^1-3 »).
-- Si la saisie ne contient QUE des exclusions, on part de « tout sélectionné »
-- puis on retire (ex. « ^4 » = tout sauf 4). Si elle contient au moins une
-- inclusion, on part de rien, on ajoute, puis on retire les exclusions
-- (ex. « 1-10 ^5 » = 1 à 10 sauf 5).
local function parse_selection(input, max)
    -- applique un token (sans le préfixe ^) à l'ensemble set, avec la valeur
    -- value (true = ajouter, nil = retirer).
    local function apply(set, token, value)
        local a, b = token:match("^(%d+)%-(%d+)$")
        if a then
            a, b = tonumber(a), tonumber(b)
            if a > b then a, b = b, a end
            for i = a, b do
                if i >= 1 and i <= max then set[i] = value end
            end
        else
            local n = tonumber(token:match("^(%d+)$"))
            if n and n >= 1 and n <= max then set[n] = value end
        end
    end

    -- Première passe : repérer s'il y a des inclusions et/ou des exclusions.
    local has_include, has_exclude = false, false
    for token in (input or ""):gmatch("[^%s,]+") do
        if token:sub(1, 1) == "^" then
            has_exclude = true
        else
            has_include = true
        end
    end

    -- Base : « tout sélectionné » uniquement si la saisie comporte des
    -- exclusions SANS aucune inclusion (ex. « ^4 » = tout sauf 4). Une saisie
    -- vide ne sélectionne rien : l'utilisateur a choisi le mode manuel, donc on
    -- ne met rien à jour par défaut plutôt que tout (choix prudent).
    local chosen = {}
    if has_exclude and not has_include then
        for i = 1, max do chosen[i] = true end
    end

    -- Deuxième passe : inclusions (+) puis exclusions (^ -> retrait).
    for token in (input or ""):gmatch("[^%s,]+") do
        if token:sub(1, 1) == "^" then
            apply(chosen, token:sub(2), nil)
        else
            apply(chosen, token, true)
        end
    end

    return chosen
end

-- select_auras(config, auras) -> liste filtrée des paquets AUR à mettre à jour.
-- Affiche la liste numérotée et lit une sélection par INCLUSION : l'utilisateur
-- saisit les numéros (et plages) des paquets qu'il veut mettre à jour. Une
-- saisie vide ne sélectionne rien (cohérent avec une inclusion explicite).
local function select_auras(config, auras)
    local C = color.new(config.color)
    print("")
    print(C.cyan("==> ") .. C.bold("Sélection des paquets AUR à mettre à jour"))
    for i, u in ipairs(auras) do
        local ver = ""
        if u.oldver and u.newver then
            ver = "  " .. C.dim(u.oldver) .. " -> " .. C.green(u.newver)
        end
        print(string.format("  %2d. %s%s", i, C.magenta(u.name), ver))
    end
    io.write(C.cyan("==> ") .. "Numéros à mettre à jour (ex. 1 3 5, 1-4, ^2 pour tout sauf 2) : ")
    io.flush()
    local input = io.read("l") or ""

    local chosen = parse_selection(input, #auras)
    local filtered = {}
    for i, u in ipairs(auras) do
        if chosen[i] then filtered[#filtered + 1] = u end
    end
    return filtered
end

function update.run(config)
    local repos, auras, aurall = update.check(config)
    -- Option : lister tous les paquets AUR installés avec leur statut.
    if config.list_aur then
        update.list_aur(config, aurall)
    end
    update.display(config, repos, auras)
    if #repos == 0 and #auras == 0 then return 0 end

    local C = color.new(config.color)
    -- L'option [M]anuel n'a de sens que s'il y a des paquets AUR à choisir ;
    -- sinon on propose simplement [O/n].
    local prompt = (#auras > 0)
        and "==> Continuer la mise à jour ? [O/n/M] "
        or "==> Continuer la mise à jour ? [O/n] "
    io.write("\n" .. C.cyan(prompt))
    io.flush()
    local ans = (io.read("l") or ""):lower()
    if ans == "n" or ans == "non" then
        print("Annulé.")
        return 0
    end

    -- [M]anuel : sélection à la carte des paquets AUR (inclusion). Ne concerne
    -- que l'AUR ; les paquets des dépôts restent gérés par pacman -Su. Ignoré
    -- s'il n'y a aucun paquet AUR (l'invite ne propose alors pas M).
    if ans == "m" and #auras > 0 then
        auras = select_auras(config, auras)
    end

    -- Dépôts : upgrade complet et sûr (tout-ou-rien). La synchro des bases a
    -- déjà été faite lors de la détection (pacman -Sy), donc on applique avec
    -- `pacman -Su` seul — pas de double synchro. pacman gère sa confirmation.
    if #repos > 0 then
        local cmd = {}
        local p = util.sudo_prefix(config)
        if p then cmd[#cmd + 1] = p end
        cmd[#cmd + 1] = "pacman"
        cmd[#cmd + 1] = "-Su"

        local code = util.passthrough(cmd)
        if code ~= 0 then return code end
    end

    local collect = {}
    if #auras > 0 then
        local built = {} -- anti-doublon partagé entre les paquets AUR mis à jour
        local ok_count = 0
        local interrupted = false
        for _, u in ipairs(auras) do
            -- build.aur résout les dépendances AUR récursives et installe les
            -- dépendances dépôt, comme pour -S (chemin unifié).
            local ok, err, built_names, intr = build.aur(config, u.name, built)
            ok_count = ok_count + #(built_names or {})
            if not ok then collect[#collect + 1] = { name = u.name, error = err } end
            if intr then
                interrupted = true
                break
            end
        end
        print(C.green("\n==> " .. ok_count .. " paquet(s) AUR installé(s)"))
        if #collect > 0 then
            print(C.red("\n==> Non abouti(s) (" .. #collect .. ") :"))
            for _, pkg in ipairs(collect) do
                -- pkg.error vaut déjà « <nom> : <raison> » (renvoyé par build.aur),
                -- donc on l'affiche tel quel sans re-préfixer par le nom.
                print(C.red("    " .. tostring(pkg.error)))
            end
        end
        if interrupted then return 130 end
        return #collect == 0 and 0 or 1
    end

    return 0
end

return update
