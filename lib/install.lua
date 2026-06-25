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
function install.run(config, names)
    local C            = color.new(config.color)

    local repos, auras = classify(names)

    local ok_names     = {} -- noms des paquets installés/construits avec succès
    local collect      = {} -- messages d'échec
    local built        = {} -- anti-doublon partagé entre les cibles AUR

    -- 1) Dépôts : un seul appel pacman pour tout le groupe (atomique).
    if #repos > 0 then
        local argv = luapilot.mergeTables({ "-S" }, repos)
        local code = pacman.passthrough(config, argv)
        if code == 0 then
            for _, r in ipairs(repos) do ok_names[#ok_names + 1] = r end
        else
            collect[#collect + 1] =
                "dépôts (" .. table.concat(repos, ", ") .. ") : échec de l'installation"
            print(C.red("\n==> Échec de l'installation des paquets des dépôts ; "
                .. "poursuite avec l'AUR."))
        end
    end

    -- 2) AUR : chaque cible via build.aur (dépendances AUR résolues + dépôt).
    for _, name in ipairs(auras) do
        local ok, err, built_names = build.aur(config, name, built)
        for _, b in ipairs(built_names or {}) do ok_names[#ok_names + 1] = b end
        if not ok then collect[#collect + 1] = err end
    end

    -- 3) Bilan combiné. Le compte porte sur les paquets DEMANDÉS et les
    -- dépendances AUR construites ; pacman a pu installer en plus des
    -- dépendances dépôt (--asdeps), déjà affichées par pacman, non comptées.
    print(C.green("\n==> " .. #ok_names .. " paquet(s) installé(s)"))
    if #ok_names > 0 then
        print(C.green("    " .. table.concat(ok_names, ", ")))
    end
    if #collect > 0 then
        print(C.red("\n==> Échecs (" .. #collect .. ") :"))
        for _, e in ipairs(collect) do
            print(C.red("    " .. tostring(e)))
        end
    end

    return #collect == 0 and 0 or 1
end

return install
