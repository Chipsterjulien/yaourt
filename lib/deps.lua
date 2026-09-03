-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- deps.lua — résolution des dépendances AUR.
--
-- Un paquet AUR peut dépendre d'autres paquets AUR (et non seulement de
-- paquets des dépôts). makepkg, appelé sans -s, n'installe rien : les
-- dépendances dépôt doivent être présentes, et les dépendances AUR construites
-- au préalable. Ce module identifie, pour un paquet donné, ses dépendances.
--
-- Classification d'une dépendance, en deux tests (la dépendance brute est
-- passée telle quelle, provides et version étant gérés nativement) :
--   1. `pacman -T <dep>`  : déjà satisfaite LOCALEMENT (installé) ? -> rien.
--   2. `pacman -Sp <dep>` : sinon, disponible dans les DÉPÔTS ? -> à installer
--      en root avant le build (repo_deps_of).
--   3. ni l'un ni l'autre -> candidate AUR (à construire), confirmée via le RPC.
-- Important : `pacman -T` ne consulte QUE la base installée, pas les dépôts ;
-- d'où le second test `-Sp` pour ne pas prendre une dépendance dépôt encore
-- non installée pour une dépendance AUR.
-- Le nom n'est nettoyé (strip_version) que pour interroger l'AUR, qui ne
-- comprend pas les contraintes de version.

local util = require("lib.util")
local aur  = require("lib.aur")
local i18n = require("lib.i18n")

local deps = {}

-- strip_version(dep) -> nom nu, sans contrainte de version.
-- « libalpm.so>=14 » -> « libalpm.so », « foo=1.0 » -> « foo », « git » -> « git ».
-- Sert uniquement à interroger l'AUR (le RPC ne gère pas « foo>=1.2 »).
local function strip_version(dep)
    return dep:match("^[^<>=]+") or dep
end

-- satisfied_locally(dep) -> bool : la dépendance (BRUTE) est-elle déjà
-- satisfaite par l'état INSTALLÉ du système ? `pacman -T <dep>` (deptest) ne
-- consulte QUE la base locale installée (provides et version compris), pas les
-- dépôts. Code 0 = déjà satisfaite localement.
local function satisfied_locally(dep)
    local res = util.run({ "pacman", "-T", dep })
    return res ~= nil and res.code == 0
end

-- available_in_repos(dep) -> bool : un paquet des DÉPÔTS satisfait-il la
-- dépendance (BRUTE) ? `pacman -Sp <dep>` résout la cible contre les dépôts en
-- tenant compte des provides ET de la version, et renvoie 0 (avec l'URL du
-- paquet) si trouvé. Indispensable en complément de -T, qui ignore les dépôts :
-- une dépendance repo disponible mais non installée n'est PAS une candidate AUR.
local function available_in_repos(dep)
    local res = util.run({ "pacman", "-Sp", dep })
    return res ~= nil and res.code == 0
end

-- raw_deps(entry) -> liste des dépendances brutes (Depends + MakeDepends).
local function raw_deps(entry)
    local raw = {}
    for _, field in ipairs({ "Depends", "MakeDepends" }) do
        local arr = entry[field]
        if type(arr) == "table" then
            for _, d in ipairs(arr) do raw[#raw + 1] = d end
        end
    end
    return raw
end

-- aur_deps_of(config, name) -> (liste, nil) | (nil, err)
-- Dépendances AUR DIRECTES de `name` : on lit Depends + MakeDepends via le RPC,
-- on écarte celles que pacman sait déjà satisfaire (installées, dépôt, provides,
-- version), puis un seul aur.info groupé confirme lesquelles existent en AUR.
function deps.aur_deps_of(config, name)
    local info, err = aur.info(config, { name })
    if not info then return nil, err end

    local entry = info[name]
    if not entry then
        -- Paquet introuvable en AUR : aucune dépendance AUR à remonter.
        return {}, nil
    end

    -- Candidates AUR : dépendances ni satisfaites localement, ni disponibles
    -- dans les dépôts (provides + version testés sur la dépendance brute). On
    -- retient le nom nettoyé pour interroger l'AUR. Déduplication au passage.
    local seen = {}
    local candidates = {}
    for _, d in ipairs(raw_deps(entry)) do
        if not satisfied_locally(d) and not available_in_repos(d) then
            local n = strip_version(d)
            if n and n ~= "" and not seen[n] then
                seen[n] = true
                candidates[#candidates + 1] = n
            end
        end
    end

    if #candidates == 0 then return {}, nil end

    -- Confirmation : un seul aur.info groupé. Ne survivent que les candidates
    -- réellement présentes dans l'AUR (les autres n'existent nulle part).
    local found, ferr = aur.info(config, candidates)
    if not found then return nil, ferr end

    local result = {}
    for _, n in ipairs(candidates) do
        if found[n] then result[#result + 1] = n end
    end
    return result, nil
end

-- repo_deps_of(config, name) -> (liste, nil) | (nil, err)
-- Dépendances de `name` à installer en root AVANT compilation : celles qui
-- sont disponibles dans les dépôts (provides/version compris) mais PAS déjà
-- satisfaites localement. On les passe ensuite à `pacman -S --asdeps --needed`
-- (le --needed est une sécurité supplémentaire). On renvoie le nom NETTOYÉ ;
-- pacman résout provides et version au moment de l'installation.
--
-- Nécessaire car makepkg tourne en tant qu'utilisateur de build (sans droits
-- pacman) et est appelé sans -s : les dépendances dépôt doivent déjà être là.
function deps.repo_deps_of(config, name)
    local info, err = aur.info(config, { name })
    if not info then return nil, err end

    local entry = info[name]
    if not entry then return {}, nil end

    local seen = {}
    local result = {}
    for _, d in ipairs(raw_deps(entry)) do
        -- À installer : disponible en dépôt et pas déjà satisfaite localement.
        if not satisfied_locally(d) and available_in_repos(d) then
            local n = strip_version(d)
            if n and n ~= "" and not seen[n] then
                seen[n] = true
                result[#result + 1] = n
            end
        end
    end
    return result, nil
end

-- resolve(config, target) -> (ordre, nil) | (nil, err)
-- Explore récursivement le graphe des dépendances AUR de `target` et renvoie
-- la liste ORDONNÉE des dépendances AUR à construire AVANT la cible (la cible
-- elle-même n'est pas incluse). Tri topologique par parcours en profondeur :
-- on visite les dépendances d'un paquet avant de l'ajouter, donc les feuilles
-- se retrouvent en tête et les paquets les plus proches de la cible en fin.
-- L'ensemble `visited` évite les doublons et neutralise les cycles éventuels.
function deps.resolve(config, target)
    local plan, err = deps.resolve_many(config, { target })
    if not plan then return nil, err end

    local order = {}
    for _, pkg in ipairs(plan.order) do
        if pkg ~= target then order[#order + 1] = pkg end
    end
    return order, nil
end

-- resolve_many(config, targets) -> ({ order, direct }, nil) | (nil, err)
-- Variante multi-cibles du solveur. Contrairement à resolve(), la liste
-- ordonnée contient aussi les cibles : elle décrit ainsi tout le graphe de
-- paquets requis par une même transaction. `direct[pkg]` conserve les arêtes
-- du graphe ; build.lua les regroupe ensuite par PackageBase pour construire
-- une seule fois les split packages partageant le même dépôt AUR.
function deps.resolve_many(config, targets)
    local order    = {}
    local direct   = {}
    local visited  = {}
    local visiting = {}
    local rerr

    local function visit(pkg)
        if visited[pkg] then return true end
        -- Les cycles AUR sont invalides en pratique, mais les neutraliser ici
        -- conserve le comportement historique du solveur sans récursion infinie.
        if visiting[pkg] then return true end
        visiting[pkg] = true

        local pkg_deps, err = deps.aur_deps_of(config, pkg)
        if not pkg_deps then
            rerr = err
            return false
        end
        direct[pkg] = pkg_deps
        for _, dependency in ipairs(pkg_deps) do
            if not visit(dependency) then return false end
        end

        visiting[pkg] = nil
        visited[pkg] = true
        order[#order + 1] = pkg
        return true
    end

    for _, target in ipairs(targets or {}) do
        if not visit(target) then return nil, rerr end
    end

    return { order = order, direct = direct }, nil
end

-- deps.show(config, name) -> code de sortie. Outil de debug : affiche les
-- dépendances AUR directes d'un paquet, sans rien construire.
function deps.show(config, name)
    local list, err = deps.aur_deps_of(config, name)
    if not list then
        print(i18n.t("common.error", { error = tostring(err) }))
        return 1
    end
    print(i18n.t("deps.direct_heading", { package = name }))
    if #list == 0 then
        print("  " .. i18n.t("common.none"))
    else
        for _, d in ipairs(list) do print("  " .. d) end
    end
    return 0
end

-- deps.show_resolve(config, name) -> code de sortie. Outil de debug : affiche
-- l'ordre de build récursif complet des dépendances AUR, sans rien construire.
function deps.show_resolve(config, name)
    local order, err = deps.resolve(config, name)
    if not order then
        print(i18n.t("common.error", { error = tostring(err) }))
        return 1
    end
    print(i18n.t("deps.order_heading", { package = name }))
    if #order == 0 then
        print("  " .. i18n.t("deps.none"))
    else
        for i, d in ipairs(order) do print("  " .. i .. ". " .. d) end
        print("  " .. (#order + 1) .. ". " .. name .. "  " .. i18n.t("deps.target"))
    end
    return 0
end

return deps
