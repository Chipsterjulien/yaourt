-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- main.lua — point d'entrée de yaourt (réécriture Lua/luapilot).
--
-- Stratégie « figuier étrangleur » : ce binaire est la porte d'entrée et,
-- pour tout ce qui n'est pas encore porté nativement, il délègue à pacman.

local cfg     = require("lib.config")
local clean   = require("lib.clean")
local color   = require("lib.color")
local deps    = require("lib.deps")
local fetch   = require("lib.fetch")
local install = require("lib.install")
local log     = require("lib.log")
local pacman  = require("lib.pacman")
local search  = require("lib.search")
local update  = require("lib.update")
local version = require("lib.version")

-- arg[1..n] = arguments utilisateur (cf. doc luapilot : <=0 ignorés)
local args    = {}
for i = 1, #arg do args[i] = arg[i] end

local function usage()
    io.write(([[
%s %s — wrapper pacman + assistant AUR

USAGE :
  yaourt <opérations pacman>      passe la main à pacman (-Q, -R, -Sy…)
  yaourt -S <paquet>...           installe un paquet (dépôts ou AUR)
  yaourt -Ss <terme>              recherche unifiée dépôts + AUR
  yaourt -Syu | -Su               mise à jour unifiée dépôts + AUR ([M] : choix
                                  manuel des paquets AUR à mettre à jour)
  yaourt -Sc | -Scc               nettoie le cache de build (doux | complet)
  yaourt -G <paquet>...           récupère les fichiers de build AUR (git clone)
  yaourt -h | --help              cette aide
  yaourt -V | --version           version
]]):format(version.name, version.version))
end

-- Recherche (-Ss, -Ssq…) -> notre recherche unifiée dépôts + AUR.
-- Opération S contenant 's' (search) mais pas 'y'/'u' (refresh/upgrade).
local function is_search(op)
    if not op:match("^%-%a*S%a*$") then return false end -- opération courte avec un S
    if not op:find("s") then return false end            -- doit contenir 's' (search)
    if op:find("[yu]") then return false end             -- mais ni refresh ni upgrade
    return true
end

-- Sysupgrade sans cible (-Syu, -Su, -Syyu…) -> vue unifiée des MAJ.
local function is_sysupgrade(a)
    local op = a[1] or ""
    if not op:match("^%-%a*S%a*$") then return false end
    if not op:find("u") then return false end
    for i = 2, #a do
        if not a[i]:match("^%-") then return false end
    end
    return true
end

-- parse_install_opts(args) -> (names, opts)
-- Sépare, pour une commande -S, les noms de paquets des options.
--   * args[1] est l'opération (ex. -S, -Sf, -Sfw) : les lettres après le S
--     sont des flags courts collés. 'f' -> force ; les autres -> passthrough
--     (sous forme -x), transmis à pacman pour les paquets dépôt uniquement.
--   * args[2..] : un argument commençant par '-' est un flag (--needed -> needed ;
--     -f/--force -> force ; le reste -> passthrough), sinon c'est un nom de paquet.
-- opts = { force = bool, needed = bool, passthrough = { … } }.
local function parse_install_opts(args)
    local names = {}
    local opts  = { force = false, needed = false, passthrough = {} }

    -- 1) Flags courts collés à l'opération (args[1]), après le 'S'.
    local op    = args[1] or ""
    local tail  = op:match("^%-%a*S(%a*)$") or ""
    for ch in tail:gmatch("%a") do
        if ch == "f" then
            opts.force = true
        else
            opts.passthrough[#opts.passthrough + 1] = "-" .. ch
        end
    end

    -- 2) Arguments suivants : flags (commencent par '-') ou noms de paquets.
    for i = 2, #args do
        local a = args[i]
        if a:sub(1, 1) == "-" then
            if a == "--needed" then
                opts.needed = true
            elseif a == "-f" or a == "--force" then
                opts.force = true
            else
                opts.passthrough[#opts.passthrough + 1] = a
            end
        else
            names[#names + 1] = a
        end
    end

    return names, opts
end

-- Nettoyage du cache (-Sc doux, -Scc total). Opération S contenant 'c',
-- sans 's'/'y'/'u'/'i'/'l'. Renvoie nil (pas un nettoyage), "soft" ou "full".
local function clean_kind(op)
    if not op:match("^%-%a*S%a*$") then return nil end
    if op:find("[syuil]") then return nil end
    local _, n = op:gsub("c", "") -- nombre de 'c'
    if n >= 2 then return "full" end
    if n == 1 then return "soft" end
    return nil
end

-- Installation directe (-S nu) -> routage dépôts/AUR.
-- Opération S sans 's' (search), 'y'/'u' (upgrade), 'i' (info) ni 'l' (list),
-- qui ont chacun leur propre sémantique.
local function is_install(op)
    if not op:match("^%-%a*S%a*$") then return false end
    if op:find("[syuilc]") then return false end
    return true
end

local function main()
    local config = cfg.load()
    log.setup(config)

    if #args == 0 then
        usage()
        return 0
    end

    local first = args[1]

    if first == "-h" or first == "--help" then
        usage()
        return 0
    end

    if first == "-V" or first == "--version" then
        io.write(version.name .. " " .. version.version .. "\n")
        return 0
    end

    if not luapilot.user.exists("yaourt") then
        local C = color.new(config.color)
        print(C.red("L'utilisateur système « yaourt » est introuvable."))
        print("Créez-le (en tant que root) :")
        print(C.cyan(
            [[useradd --system --home-dir /var/cache/yaourt --create-home --shell /usr/sbin/nologin --comment "yaourt AUR build user" yaourt]]))
        return 1
    end

    -- Récupération des fichiers de build AUR (équivalent -G / --getpkgbuild)
    if first == "-G" or first == "--getpkgbuild" then
        local pkgs = {}
        for i = 2, #args do pkgs[i - 1] = args[i] end
        if #pkgs == 0 then
            log.error("-G attend au moins un nom de paquet")
            return 1
        end
        return fetch.get(config, pkgs)
    end

    -- Outil interne (non documenté dans -h) : yaourt --debug-deps <paquet>
    -- Affiche les dépendances AUR directes d'un paquet.
    -- Affiche les dépendances AUR directes d'un paquet, sans rien construire.
    if first == "--debug-deps" then
        if not args[2] then
            log.error("--debug-deps attend un nom de paquet")
            return 1
        end
        return deps.show(config, args[2])
    end

    -- Outil interne (non documenté dans -h) : yaourt --debug-resolve <paquet>
    -- Affiche l'ordre de build récursif des dépendances AUR.
    -- Affiche l'ordre de build récursif des dépendances AUR, sans construire.
    if first == "--debug-resolve" then
        if not args[2] then
            log.error("--debug-resolve attend un nom de paquet")
            return 1
        end
        return deps.show_resolve(config, args[2])
    end


    -- Recherche unifiée dépôts + AUR (-Ss)
    if is_search(first) then
        if not args[2] then
            log.error("-Ss attend un terme de recherche")
            return 1
        end
        return search.run(config, args[2])
    end

    -- Mise à jour système unifiée (dépôts + AUR).
    if is_sysupgrade(args) then
        return update.run(config)
    end

    -- Installation directe (-S <paquet>...) : route chaque paquet vers les
    -- dépôts (pacman) ou l'AUR (build).
    -- Nettoyage du cache (-Sc doux, -Scc total) : à intercepter AVANT
    -- is_install (sinon -Sc serait pris pour une installation).
    local ck = clean_kind(first)
    if ck == "soft" then
        return clean.soft(config)
    elseif ck == "full" then
        return clean.full(config)
    end

    if is_install(first) then
        local names, opts = parse_install_opts(args)
        if #names == 0 then
            log.error("-S attend au moins un nom de paquet")
            return 1
        end
        return install.run(config, names, opts)
    end

    -- Tout le reste : on délègue à pacman tel quel (avec sudo si nécessaire).
    return pacman.passthrough(config, args)
end

os.exit(main())
