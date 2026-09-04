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
-- via pacman, puis build des paquets AUR (build.aur_many).
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
local i18n    = require("lib.i18n")
local vcs     = require("lib.vcs")

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
        log.error(i18n.t("update.sync_failed"))
        return {}
    end

    -- 2) Détection des MAJ disponibles (pacman -Qu, capturé).
    -- Format : « nom ancienne -> nouvelle ». Code non nul si aucune MAJ.
    local res = util.run({ "pacman", "-Qu" }, { env = { LC_ALL = "C" } })
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
    local res = util.run({ "pacman", "-Sl" }, { env = { LC_ALL = "C" } })
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
-- On interroge l'AUR en une passe groupée ; les MAJ ET la liste complète en
-- dérivent (le client RPC découpe seulement si l'URL deviendrait trop longue).
local function aur_status(config, check_devel)
    local res = util.run({ "pacman", "-Qm" }, { env = { LC_ALL = "C" } })
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
        return nil, err
    end

    local list = {}
    for _, name in ipairs(names) do
        local entry = infos[name]
        local e = { name = name, repo = "aur", oldver = installed[name], in_aur = entry ~= nil }

        if entry then
            e.newver     = entry.Version
            e.pkgbase    = entry.PackageBase or entry.Name
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
    local vcs_errors = {}
    if check_devel then vcs_errors = vcs.mark_updates(config, list) end
    return list, nil, vcs_errors
end

-- check(config, opts) -> (repos[], auras[], aurall[], aurerr, vcs_errors[])
--   repos  : MAJ des dépôts (champ .repo renseigné)
--   auras  : paquets AUR à mettre à jour (sous-ensemble de aurall)
--   aurall : statut de TOUS les paquets AUR installés (pour la liste optionnelle)
--   aurerr : erreur RPC éventuelle ; dans ce cas aurall est vide et aucun
--            paquet n'est faussement déclaré « non géré par AUR ».
--   vcs_errors : contrôles VCS impossibles ; ils n'annulent pas les autres MAJ.
function update.check(config, opts)
    opts = opts or {}
    local check_devel = opts.devel
    if check_devel == nil then check_devel = config.devel == true end
    local repos = repo_updates(config)
    if #repos > 0 then
        local rmap = repo_map()
        for _, u in ipairs(repos) do u.repo = rmap[u.name] or "repo" end
    end
    table.sort(repos, function(a, b)
        if a.repo ~= b.repo then return a.repo < b.repo end
        return a.name < b.name
    end)

    local aurall, aurerr, vcs_errors = aur_status(config, check_devel)
    aurall = aurall or {}
    local auras = {}
    for _, e in ipairs(aurall) do
        if e.has_update then auras[#auras + 1] = e end
    end

    return repos, auras, aurall, aurerr, vcs_errors or {}
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

local function displayed_version(entry)
    if entry.vcs_only then return i18n.t("status.vcs_update") end
    return entry.newver
end

function update.display(config, repos, auras)
    local C = color.new(config.color)

    local all = {}
    for _, u in ipairs(repos) do all[#all + 1] = u end
    for _, u in ipairs(auras) do all[#all + 1] = u end

    if #all == 0 then
        print(":: " .. i18n.t("update.up_to_date"))
        return
    end

    -- Partition : révisions (bump de pkgrel) vs vraies nouvelles versions.
    local revs, vers = {}, {}
    for _, u in ipairs(all) do
        if not u.vcs_only and is_revision(u.oldver, u.newver) then
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
        local shown = displayed_version(u)
        if #shown > wnew then wnew = #shown end
    end

    local function line(u)
        local rc      = display.repo_color(C, u.repo)
        local visible = #(u.repo .. "/" .. u.name)
        local label   = rc(u.repo .. "/") .. u.name
        local namepad = string.rep(" ", wname - visible)
        local oldpad  = string.rep(" ", wold - #u.oldver)
        local shown   = displayed_version(u)
        local newpad  = string.rep(" ", wnew - #shown)
        -- Drapeaux à droite (AUR uniquement) : bien visibles.
        local flags   = ""
        if u.orphan then flags = flags .. "  " .. C.yellow(i18n.t("status.orphan")) end
        if u.outofdate then flags = flags .. "  " .. C.red(i18n.t("status.out_of_date")) end
        print(string.format("  %s%s  %s%s %s %s%s%s",
            label, namepad, u.oldver, oldpad, C.dim("->"), C.green(shown), newpad, flags))
    end

    if #revs > 0 then
        print(C.cyan("==> " .. i18n.n("update.revisions", #revs)))
        for _, u in ipairs(revs) do line(u) end
    end
    if #vers > 0 then
        if #revs > 0 then print("") end
        print(C.cyan("==> " .. i18n.n("update.new_versions", #vers)))
        for _, u in ipairs(vers) do line(u) end
    end
end

-- Normalise la configuration du récapitulatif AUR :
--   * "notable" (et toute valeur absente/inconnue) : éléments à surveiller ;
--   * "all" ou true : liste complète (compatibilité avec l'ancien booléen) ;
--   * false : aucun récapitulatif.
local function aur_list_mode(value)
    if value == false then return "none" end
    if value == true or value == "all" then return "all" end
    return "notable"
end

-- Récapitulatif des paquets AUR installés avec leur statut (option config).
-- En mode notable, les mises à jour simples ne sont pas répétées ici : elles
-- figurent déjà dans la liste principale produite par update.display.
function update.list_aur(config, aurall)
    local mode = aur_list_mode(config.list_aur)
    if mode == "none" or #aurall == 0 then return end
    local C = color.new(config.color)

    local function line(e, wname)
        local pad = string.rep(" ", wname - #e.name)
        local status
        if e.vcs_only then
            status = C.green(e.oldver .. " -> " .. i18n.t("status.vcs_update"))
        elseif e.has_update then
            status = C.green(e.oldver .. " -> " .. e.newver)
        else
            status = i18n.t("status.up_to_date")
        end
        local flags = ""
        if e.orphan then flags = flags .. "  " .. C.yellow(i18n.t("status.orphan_plain")) end
        if e.outofdate then flags = flags .. "  " .. C.red(i18n.t("status.out_of_date")) end

        print(string.format("  %s%s : %s%s", C.magenta(e.name), pad, status, flags))
    end

    local notinaur, inaur = {}, {}

    for _, e in ipairs(aurall) do
        if e.in_aur then
            if mode == "all" or e.orphan or e.outofdate then
                inaur[#inaur + 1] = e
            end
        else
            notinaur[#notinaur + 1] = e
        end
    end

    local wname = 0
    for _, e in ipairs(inaur) do
        if #e.name > wname then wname = #e.name end
    end

    local printed = false

    if #inaur > 0 then
        local key = (mode == "all") and "update.aur_managed" or "update.aur_notable"
        print(C.cyan("==> " .. i18n.n(key, #inaur)))
        for _, v in ipairs(inaur) do
            line(v, wname)
        end
        printed = true
    end

    if #notinaur > 0 then
        if printed then print("") end

        local notinaur_names = {}
        for _, v in ipairs(notinaur) do
            notinaur_names[#notinaur_names + 1] = v.name
        end

        print(C.cyan("==> " .. i18n.n("update.aur_unmanaged", #notinaur)))
        print(C.dim(table.concat(notinaur_names, " ")))
        printed = true
    end

    -- Sépare toujours le récapitulatif AUR de la liste principale des mises à
    -- jour, y compris lorsqu'il n'existe aucun paquet non géré par l'AUR.
    if printed then print("") end
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
    print(C.cyan("==> ") .. C.bold(i18n.t("update.select_aur")))
    for i, u in ipairs(auras) do
        local ver = ""
        if u.oldver and u.newver then
            ver = "  " .. C.dim(u.oldver) .. " -> "
                .. C.green(displayed_version(u))
        end
        print(string.format("  %2d. %s%s", i, C.magenta(u.name), ver))
    end
    io.write(C.cyan("==> ") .. i18n.t("update.selection_prompt") .. " ")
    io.flush()
    local input = io.read("l") or ""

    local chosen = parse_selection(input, #auras)
    local filtered = {}
    for i, u in ipairs(auras) do
        if chosen[i] then filtered[#filtered + 1] = u end
    end
    return filtered
end

function update.parse_opts(args, config)
    local opts = { devel = config and config.devel == true or false }
    for i = 2, #(args or {}) do
        if args[i] == "--devel" then
            opts.devel = true
        elseif args[i] == "--no-devel" then
            opts.devel = false
        end
    end
    return opts
end

function update.run(config, opts)
    opts = opts or { devel = config.devel == true }
    local repos, auras, aurall, aurerr, vcs_errors = update.check(config, opts)
    if aurerr then
        log.warn(i18n.t("update.aur_check_skipped", { error = tostring(aurerr) }))
    end
    for _, err in ipairs(vcs_errors or {}) do
        log.warn(i18n.t("update.vcs_check_skipped", { error = tostring(err) }))
    end
    -- Option : afficher les paquets AUR notables ou la liste complète.
    if aur_list_mode(config.list_aur) ~= "none" then
        update.list_aur(config, aurall)
    end
    update.display(config, repos, auras)
    if #repos == 0 and #auras == 0 then return 0 end

    local C = color.new(config.color)
    -- L'option [m]anuel n'a de sens que s'il y a des paquets AUR à choisir ;
    -- sinon on propose simplement [O/n].
    local has_manual = #auras > 0
    local prompt = has_manual
        and i18n.prompt("update.continue_manual", true)
        or i18n.prompt("update.continue", false)
    io.write("\n" .. C.cyan("==> " .. prompt) .. " ")
    io.flush()
    local ans = (io.read("l") or ""):lower()
    if i18n.is_answer(ans, "no") then
        print(i18n.t("common.cancelled"))
        return 0
    end

    -- [m]anuel : sélection à la carte des paquets AUR (inclusion). Ne concerne
    -- que l'AUR ; les paquets des dépôts restent gérés par pacman -Su. Ignoré
    -- s'il n'y a aucun paquet AUR (l'invite ne propose alors pas m).
    if i18n.is_answer(ans, "manual") and #auras > 0 then
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

    if #auras > 0 then
        local names = {}
        local vcs_packages = {}
        for _, u in ipairs(auras) do
            names[#names + 1] = u.name
            if u.vcs_only then vcs_packages[u.name] = true end
        end
        -- Plan global : plusieurs sous-paquets installés provenant du même
        -- pkgbase sont mis à jour par une seule compilation.
        local results = build.aur_many(config, names, {
            vcs_packages = vcs_packages,
        })
        return display.build_summary(C, results, "updated")
    end

    return 0
end

return update
