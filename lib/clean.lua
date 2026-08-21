-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- clean.lua — nettoyage du cache de build yaourt.
--
-- Deux niveaux, façon yay/pacman :
--   -Sc  (doux)  : dans chaque dépôt cloné, supprime tout ce qui n'est PAS
--                  suivi par git (sources téléchargées, restes de build) via
--                  `git clean -fdx`, en conservant le clone (PKGBUILD, .git).
--                  Puis délègue à `pacman -Sc` pour le cache pacman.
--   -Scc (total) : supprime TOUT le contenu du cache de build (tous les dépôts
--                  clonés). Le prochain build re-clonera. Puis `pacman -Scc`.
--
-- Le cache de build est config.builddir (ex. /var/cache/yaourt/.cache/yaourt
-- ou ~/.cache/yaourt). Chaque sous-dossier est le clone d'un paquet AUR.

local util   = require("lib.util")
local log    = require("lib.log")
local color  = require("lib.color")
local pacman = require("lib.pacman")
local i18n   = require("lib.i18n")

local clean  = {}

-- list_pkg_dirs(builddir) -> liste des chemins des dépôts de paquets.
-- Renvoie une liste (éventuellement vide). nil si le cache n'existe pas.
local function list_pkg_dirs(builddir)
    local is_dir, dir_err = babet.isDir(builddir)
    if is_dir == nil then
        log.warn(i18n.t("cache.inspect_failed", { error = tostring(dir_err) }))
        return {}
    end
    if not is_dir then return nil end

    -- Babet 2.22.2 fournit une recherche bornée et sans shell. Les enfants
    -- directs de la racine sont à la profondeur 0.
    local dirs, err = babet.find(builddir, {
        type = "d",
        maxdepth = 0,
    })
    if not dirs then
        log.warn(i18n.t("cache.list_failed", { error = tostring(err) }))
        return {}
    end

    table.sort(dirs)
    return dirs
end

-- confirm(C, prompt) -> bool : invite [O/n], vrai si l'utilisateur accepte.
local function confirm(C, prompt)
    io.write(C.cyan("==> ") .. prompt .. " " .. i18n.t("prompt.yes_no") .. " ")
    io.flush()
    local ans = (io.read("l") or ""):lower()
    return not i18n.is_answer(ans, "no")
end

-- soft(config) : nettoyage doux. Pour chaque dépôt, `git clean -fdx` (supprime
-- les fichiers non suivis : sources téléchargées, artefacts), en gardant le
-- clone. Puis pacman -Sc.
function clean.soft(config)
    local C = color.new(config.color)
    local dirs = list_pkg_dirs(config.builddir)

    if dirs == nil then
        print(C.dim(i18n.t("cache.absent", { path = config.builddir })))
    elseif #dirs == 0 then
        print(C.dim(i18n.t("cache.empty")))
    else
        print(C.cyan("==> ") .. C.bold(i18n.n("cache.clean_sources", #dirs)))
        print(C.dim("    " .. config.builddir))
        if confirm(C, i18n.t("cache.remove_untracked")) then
            local cleaned = 0
            for _, dir in ipairs(dirs) do
                -- git clean -fdx en tant que build_user (le dépôt lui appartient
                -- en cas B). -f force, -d inclut les répertoires, -x les fichiers
                -- ignorés par .gitignore (sources, artefacts).
                local res = util.run_as(config.build_user,
                    { "git", "-C", dir, "clean", "-fdx" })
                if res and res.code == 0 then
                    cleaned = cleaned + 1
                else
                    log.warn(i18n.t("cache.clean_failed", { path = dir }))
                end
            end
            print(C.green("==> " .. i18n.n("cache.cleaned", cleaned)))
        else
            print(i18n.t("cache.clean_skipped"))
        end
    end

    -- Cache pacman (délégué, avec sa propre confirmation).
    print("")
    print(C.cyan("==> ") .. C.bold(i18n.t("cache.pacman")))
    local cmd = {}
    local p = util.sudo_prefix(config)
    if p then cmd[#cmd + 1] = p end
    cmd[#cmd + 1] = "pacman"
    cmd[#cmd + 1] = "-Sc"
    return util.passthrough(cmd)
end

-- full(config) : nettoyage total. Supprime tout le contenu du cache de build
-- (tous les dépôts clonés). Puis pacman -Scc.
function clean.full(config)
    local C = color.new(config.color)
    local dirs = list_pkg_dirs(config.builddir)

    if dirs == nil then
        print(C.dim(i18n.t("cache.absent", { path = config.builddir })))
    elseif #dirs == 0 then
        print(C.dim(i18n.t("cache.empty")))
    else
        print(C.cyan("==> ") .. C.bold(i18n.n("cache.remove_full", #dirs)))
        print(C.dim("    " .. config.builddir))
        print(C.red("    " .. i18n.t("cache.remove_warning")))
        if confirm(C, i18n.t("cache.remove_confirm")) then
            local removed = 0
            for _, dir in ipairs(dirs) do
                local ok, err = babet.rmdirAll(dir)
                if ok then
                    removed = removed + 1
                else
                    log.warn(i18n.t("cache.remove_failed", {
                        path = dir,
                        error = tostring(err),
                    }))
                end
            end
            print(C.green("==> " .. i18n.n("cache.removed", removed)))
        else
            print(i18n.t("cache.remove_skipped"))
        end
    end

    -- Cache pacman complet (délégué).
    print("")
    print(C.cyan("==> ") .. C.bold(i18n.t("cache.pacman_full")))
    local cmd = {}
    local p = util.sudo_prefix(config)
    if p then cmd[#cmd + 1] = p end
    cmd[#cmd + 1] = "pacman"
    cmd[#cmd + 1] = "-Scc"
    return util.passthrough(cmd)
end

return clean
