-- main.lua — point d'entrée de yaourt (réécriture Lua/luapilot).
--
-- Stratégie « figuier étrangleur » : ce binaire est la porte d'entrée et,
-- pour tout ce qui n'est pas encore porté nativement, il délègue à pacman.

local build   = require("lib.build")
local cfg     = require("lib.config")
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
  yaourt -G <paquet>...           récupère les fichiers de build AUR (git clone)
  yaourt -Syu | -Su               mise à jour unifiée dépôts + AUR
  yaourt -B <paquet>              (temporaire) test du pipeline de build
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

-- Installation directe (-S nu) -> routage dépôts/AUR.
-- Opération S sans 's' (search), 'y'/'u' (upgrade), 'i' (info) ni 'l' (list),
-- qui ont chacun leur propre sémantique.
local function is_install(op)
    if not op:match("^%-%a*S%a*$") then return false end
    if op:find("[syuil]") then return false end
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

    -- TEMPORAIRE (debug) : yaourt --debug-deps <paquet>
    -- Affiche les dépendances AUR directes d'un paquet, sans rien construire.
    if first == "--debug-deps" then
        if not args[2] then
            log.error("--debug-deps attend un nom de paquet")
            return 1
        end
        return deps.show(config, args[2])
    end

    -- TEMPORAIRE (debug) : yaourt --debug-resolve <paquet>
    -- Affiche l'ordre de build récursif des dépendances AUR, sans construire.
    if first == "--debug-resolve" then
        if not args[2] then
            log.error("--debug-resolve attend un nom de paquet")
            return 1
        end
        return deps.show_resolve(config, args[2])
    end

    -- TEMPORAIRE (test du pipeline de build) : yaourt -B <paquet>
    -- Sera remplacé par l'appel à build.one depuis -Syu une fois le pipeline prêt.
    if first == "-B" then
        if not args[2] then
            log.error("-B attend un nom de paquet")
            return 1
        end
        local ok, berr = build.one(config, args[2])
        if not ok then log.error(tostring(berr)) end
        return ok and 0 or 1
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
    if is_install(first) then
        local names = {}
        for i = 2, #args do names[#names + 1] = args[i] end
        if #names == 0 then
            log.error("-S attend au moins un nom de paquet")
            return 1
        end
        return install.run(config, names)
    end

    -- Tout le reste : on délègue à pacman tel quel (avec sudo si nécessaire).
    return pacman.passthrough(config, args)
end

os.exit(main())
