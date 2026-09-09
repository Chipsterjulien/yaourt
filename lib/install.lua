-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- install.lua — installation directe de paquets (dépôts ou AUR).
--
-- Implémente `-S <paquet>...`. Les paquets sont classés en deux groupes :
-- ceux présents dans les dépôts officiels (installés en UN seul `pacman -S`)
-- et ceux de l'AUR (construits via build.aur_many, qui résout récursivement leurs
-- dépendances AUR et installe leurs dépendances dépôt).
--
-- ROADMAP (objectif : équivalent yay) :
--   étape 1  : routage dépôt/AUR, paquet par paquet, avec bilan.
--   étape 2  : groupement des paquets dépôt dans un seul `pacman -S`.
--   étape 3  : résolution récursive des dépendances AUR (déléguée à
--              build.aur_many, partagée avec -Syu).
--   étape 4  : plan global par PackageBase pour les split packages.

local util    = require("lib.util")
local log     = require("lib.log")
local build   = require("lib.build")
local pacman  = require("lib.pacman")
local color   = require("lib.color")
local display = require("lib.display")
local i18n    = require("lib.i18n")

local install = {}

-- parse_opts(args) -> (names, opts)
-- Sépare les cibles des modificateurs d'une opération -S. Le mode de
-- téléchargement seul est conservé explicitement : il est sûr pour les
-- dépôts, mais ne possède pas encore de sémantique AUR non ambiguë.
function install.parse_opts(args)
    local opts = require("lib.cli").parse(args)
    local valid, option = require("lib.cli").validate(opts)
    if not valid then opts.error = option end
    return opts.names, opts
end

-- in_repos(name) -> bool : vrai si le paquet existe dans un dépôt officiel.
-- Détection via `pacman -Si <name>` (capturé) : code 0 = trouvé.
local function in_repos(name)
    local res = util.run({ "pacman", "-Si", name })
    return res ~= nil and res.code == 0, res and res.code
end

-- classify(names) -> (repos, auras) : répartit les paquets demandés entre
-- ceux des dépôts et les autres (candidats AUR), en préservant l'ordre.
local function classify(names)
    local repos, auras = {}, {}
    for _, name in ipairs(names) do
        local found, code = in_repos(name)
        if util.is_interrupted(code) then return nil, nil, code end
        if found then
            repos[#repos + 1] = name
        else
            auras[#auras + 1] = name
        end
    end
    return repos, auras
end

-- run(config, names) -> code de sortie (0 = tout ok, 1 = au moins un échec)
-- Dépôts d'abord (un seul pacman -S), puis toutes les cibles AUR via un plan
-- build.aur_many (résolution récursive + regroupement des split packages).
function install.run(config, names, opts)
    local C            = color.new(config.color)
    opts               = opts or {
        force = false,
        needed = false,
        noconfirm = false,
        download_only = false,
        passthrough = {},
    }

    if opts.error then
        log.error(i18n.t("cli.unsupported", { option = opts.error }))
        return 1
    end
    local repos, auras, classify_code = classify(names)
    if not repos then return classify_code end

    -- `pacman -Sw` ne sait télécharger que les paquets des dépôts. Construire
    -- puis installer silencieusement une cible AUR ferait l'inverse de la
    -- demande. Une commande mixte est donc refusée en entier avant le moindre
    -- téléchargement, clone, build ou appel pacman modificateur.
    if opts.print_only and #auras > 0 then
        log.error(i18n.t("cli.unsupported", {option="-Sp AUR"}))
        return 1
    end
    if opts.download_only and #auras > 0 then
        log.error(i18n.t("install.download_only_aur_unsupported", {
            packages = table.concat(auras, ", "),
        }))
        return 1
    end

    -- Dépôts uniquement : on rend la main à pacman avec sa sémantique native
    -- et sans produire un bilan d'installation mensonger.
    if opts.download_only or opts.print_only then
        local argv = { "-S" }
        if opts.download_only then argv[#argv+1]="-w" end
        if opts.print_only then argv[#argv+1]="-p" end
        if opts.needed then argv[#argv + 1] = "--needed" end
        for _, flag in ipairs(opts.passthrough or {}) do
            argv[#argv + 1] = flag
        end
        argv = babet.mergeTables(argv, repos)
        return pacman.passthrough(config, argv)
    end

    local results      = {} -- résultats typés (build.result) pour le bilan

    -- 1) Dépôts : un seul appel pacman pour tout le groupe (atomique).
    -- On transmet à pacman --needed et les flags inconnus (passthrough) tels
    -- quels ; pour les paquets dépôt, pacman gère ces options nativement.
    if #repos > 0 then
        local argv = { "-S" }
        if opts.needed then argv[#argv + 1] = "--needed" end
        for _, f in ipairs(opts.passthrough or {}) do argv[#argv + 1] = f end
        argv = babet.mergeTables(argv, repos)
        local code = pacman.passthrough(config, argv)
        local label = i18n.t("install.repositories", { packages = table.concat(repos, ", ") })
        if code == 0 then
            for _, r in ipairs(repos) do
                results[#results + 1] = build.result("ok", r,
                    i18n.t("result.installed", { package = r }))
            end
        elseif util.is_interrupted(code) then
            results[#results + 1] = build.result("interrupted", label,
                i18n.t("result.install_interrupted", { package = label }))
        else
            results[#results + 1] = build.result("install_failed", label,
                i18n.t("result.install_failed", { package = label }))
        end
        if code ~= 0 then return code end
    end

    -- 2) AUR : toutes les cibles sont planifiées ensemble. Le plan regroupe les
    -- sous-paquets par pkgbase afin qu'un dépôt partagé ne soit cloné, revu et
    -- construit qu'une seule fois, puis filtre les artefacts à installer.
    if #auras > 0 then
        local res_list = build.aur_many(config, auras, opts)
        for _, r in ipairs(res_list) do results[#results + 1] = r end
    end

    -- 3) Bilan groupé par statut.
    return display.build_summary(C, results, "installed")
end

return install
