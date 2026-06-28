-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- install.lua — installation directe de paquets (dépôts ou AUR).
--
-- Implémente `-S <paquet>...`. Les paquets sont classés en deux groupes :
-- ceux présents dans les dépôts officiels (installés en UN seul `pacman -S`)
-- et ceux de l'AUR (construits via build.aur, qui résout récursivement leurs
-- dépendances AUR et installe leurs dépendances dépôt).
--
-- ROADMAP (objectif : équivalent yay) :
--   étape 1  : routage dépôt/AUR, paquet par paquet, avec bilan.
--   étape 2  : groupement des paquets dépôt dans un seul `pacman -S`.
--   étape 3  : résolution récursive des dépendances AUR (déléguée à build.aur,
--              partagée avec -Syu).

local util    = require("lib.util")
local log     = require("lib.log")
local build   = require("lib.build")
local pacman  = require("lib.pacman")
local color   = require("lib.color")
local display = require("lib.display")

local install = {}

-- in_repos(name) -> bool : vrai si le paquet existe dans un dépôt officiel.
-- Détection via `pacman -Si <name>` (capturé) : code 0 = trouvé.
local function in_repos(name)
    local res = util.run({ "pacman", "-Si", name })
    return res ~= nil and res.code == 0
end

-- classify(names) -> (repos, auras) : répartit les paquets demandés entre
-- ceux des dépôts et les autres (candidats AUR), en préservant l'ordre.
local function classify(names)
    local repos, auras = {}, {}
    for _, name in ipairs(names) do
        if in_repos(name) then
            repos[#repos + 1] = name
        else
            auras[#auras + 1] = name
        end
    end
    return repos, auras
end

-- run(config, names) -> code de sortie (0 = tout ok, 1 = au moins un échec)
-- Dépôts d'abord (un seul pacman -S), puis chaque AUR via build.aur (qui gère
-- la résolution récursive des dépendances).
function install.run(config, names, opts)
    local C            = color.new(config.color)
    opts               = opts or { force = false, needed = false, passthrough = {} }

    local repos, auras = classify(names)

    local results      = {} -- résultats typés (build.result) pour le bilan
    local built        = {} -- anti-doublon partagé entre les cibles AUR

    -- 1) Dépôts : un seul appel pacman pour tout le groupe (atomique).
    -- On transmet à pacman --needed et les flags inconnus (passthrough) tels
    -- quels ; pour les paquets dépôt, pacman gère ces options nativement.
    if #repos > 0 then
        local argv = { "-S" }
        if opts.needed then argv[#argv + 1] = "--needed" end
        for _, f in ipairs(opts.passthrough or {}) do argv[#argv + 1] = f end
        argv = luapilot.mergeTables(argv, repos)
        local code = pacman.passthrough(config, argv)
        local label = "dépôts (" .. table.concat(repos, ", ") .. ")"
        if code == 0 then
            for _, r in ipairs(repos) do
                results[#results + 1] = build.result("ok", r, r .. " : installé")
            end
        elseif util.is_interrupted(code) then
            results[#results + 1] = build.result("interrupted", label,
                label .. " : installation interrompue (Ctrl+C)")
        else
            results[#results + 1] = build.result("install_failed", label,
                label .. " : échec de l'installation")
        end
    end

    -- 2) AUR : chaque cible via build.aur (retourne une liste de résultats, une
    -- entrée par paquet construit, dépendances comprises). Si une interruption
    -- (Ctrl+C) survient, on arrête net : inutile d'enchaîner les suivants.
    local stop = false
    for _, name in ipairs(auras) do
        local res_list = build.aur(config, name, built, opts)
        for _, r in ipairs(res_list) do
            results[#results + 1] = r
            if r.status == "interrupted" then stop = true end
        end
        if stop then break end
    end

    -- 3) Bilan groupé par statut.
    return display.build_summary(C, results, "installé(s)")
end

return install
