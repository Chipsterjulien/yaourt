-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- main.lua — point d'entrée de yaourt (réécriture Lua/babet).
--
-- Stratégie « figuier étrangleur » : ce binaire est la porte d'entrée et,
-- pour tout ce qui n'est pas encore porté nativement, il délègue à pacman.

local cli = require("lib.cli")
local build = require("lib.build")
local i18n = require("lib.i18n")
local help = require("lib.help")
local runtime = require("lib.runtime")
runtime.assert_supported()

local cfg     = require("lib.config")
local clean   = require("lib.clean")
local color   = require("lib.color")
local deps    = require("lib.deps")
local fetch   = require("lib.fetch")
local install = require("lib.install")
local log     = require("lib.log")
local pacman  = require("lib.pacman")
local pacdiff = require("lib.pacdiff")
local search  = require("lib.search")
local update  = require("lib.update")
local version = require("lib.version")

-- arg[1..n] = arguments utilisateur (cf. doc babet : <=0 ignorés)
local args    = {}
for i = 1, #arg do args[i] = arg[i] end

local function usage()
    io.write(help.render(version.name, version.version))
end

local function main()
    local config = cfg.load()
    i18n.configure(config)
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

    -- Gestion des fichiers .pacnew/.pacsave/.pacorig avec l'outil officiel
    -- pacdiff. Cette commande ne construit rien : elle reste utilisable sans
    -- l'utilisateur système de build yaourt.
    if first == "-C" or first == "--pacdiff" then
        local opts = {}
        for i = 2, #args do opts[#opts + 1] = args[i] end
        return pacdiff.run(config, opts)
    end

    -- Récupération des fichiers de build AUR (équivalent -G / --getpkgbuild)
    if first == "-G" or first == "--getpkgbuild" then
        local pkgs = {}
        for i = 2, #args do pkgs[i - 1] = args[i] end
        if #pkgs == 0 then
            log.error(i18n.t("cli.package_required", { option = "-G" }))
            return 1
        end
        return fetch.get(config, pkgs)
    end

    -- Outil interne (non documenté dans -h) : yaourt --debug-deps <paquet>
    -- Affiche les dépendances AUR directes d'un paquet.
    -- Affiche les dépendances AUR directes d'un paquet, sans rien construire.
    if first == "--debug-deps" then
        if not args[2] then
            log.error(i18n.t("cli.package_required", { option = "--debug-deps" }))
            return 1
        end
        return deps.show(config, args[2])
    end

    -- Outil interne (non documenté dans -h) : yaourt --debug-resolve <paquet>
    -- Affiche l'ordre de build récursif des dépendances AUR.
    -- Affiche l'ordre de build récursif des dépendances AUR, sans construire.
    if first == "--debug-resolve" then
        if not args[2] then
            log.error(i18n.t("cli.package_required", { option = "--debug-resolve" }))
            return 1
        end
        return deps.show_resolve(config, args[2])
    end


    local parsed = cli.parse(args, config)
    local valid, option = cli.validate(parsed)
    if not valid then
        log.error(i18n.t("cli.unsupported", { option = option }))
        return 1
    end
    if parsed.action == "search" then
        if #parsed.names == 0 then
            log.error(i18n.t("cli.search_term_required", { option = "-Ss" }))
            return 1
        end
        return search.run(config, table.concat(parsed.names, " "))
    elseif parsed.action == "update" then
        return update.run(config, parsed)
    elseif parsed.action == "soft" or parsed.action == "full" then
        local cache_config, err = build.environment(config)
        if not cache_config then log.error(err); return 1 end
        return clean[parsed.action](cache_config)
    elseif parsed.action == "install" then
        if #parsed.names == 0 then
            log.error(i18n.t("cli.package_required", { option = "-S" }))
            return 1
        end
        return install.run(config, parsed.names, parsed)
    end

    -- Tout le reste : on délègue à pacman tel quel (avec sudo si nécessaire).
    return pacman.passthrough(config, args)
end

os.exit(main())
