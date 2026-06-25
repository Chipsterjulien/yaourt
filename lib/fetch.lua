-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- fetch.lua — récupération des fichiers de build d'un paquet AUR.
--
-- Équivalent de `-G`. Pour chaque paquet :
--   1. on interroge le RPC AUR pour obtenir le PackageBase (le dépôt git
--      est nommé d'après le pkgbase, pas le pkgname — important pour les
--      paquets splittés) ;
--   2. on git clone https://aur.archlinux.org/<pkgbase>.git dans builddir,
--      ou git pull si le clone existe déjà.
--
-- Cas root (cas B) : quand `config.build_user` est défini, tout ce qui touche
-- au dépôt (création du dossier, clone, pull) est exécuté EN TANT QUE cet
-- utilisateur via `util.run_as`. Ainsi le builddir et son parent lui
-- appartiennent dès le départ — pas de chown de rattrapage, pas de conflit
-- de propriété git (« dubious ownership »), et les outils de build (Go, Rust…)
-- qui écrivent dans ~/.cache de l'utilisateur de build ont les bons droits.

local util  = require("lib.util")
local log   = require("lib.log")
local aur   = require("lib.aur")

local fetch = {}

-- prepare_builddir(config) -> (true, nil) | (nil, message)
-- S'assure que le builddir existe avant tout clone/pull. En cas B
-- (config.build_user défini), le dossier est créé EN TANT QUE cet
-- utilisateur (via run_as), donc toute la chaîne (~/.cache, ~/.cache/yaourt)
-- lui appartient — condition nécessaire pour que makepkg et les outils de
-- build puissent y écrire. En cas A, c'est un simple `mkdir -p`.
local function prepare_builddir(config)
    local res, err = util.run_as(config.build_user, { "mkdir", "-p", config.builddir })
    if not res then return nil, err end
    if res.code ~= 0 then return nil, "mkdir: " .. res.stderr end
    return true
end

-- clone_or_update(config, pkgbase) -> (meta, nil) | (nil, message)
-- Clone le dépôt AUR du pkgbase dans le builddir, ou le met à jour (git pull)
-- s'il est déjà présent. Les opérations git passent par run_as : en cas B
-- elles tournent sous build_user (le dépôt lui appartient), en cas A
-- directement sous l'utilisateur courant.
--
-- Renvoie une table de métadonnées que le pipeline de build exploitera pour
-- décider quoi montrer à l'utilisateur (review complète vs diff) :
--   {
--     path        = <dossier du dépôt>,
--     first_clone = true si le dépôt vient d'être cloné (pas de validation
--                   préalable possible -> review complète),
--     updated     = true si un pull a fait avancer le dépôt (HEAD a changé),
--     old_commit  = HEAD avant le pull (nil si premier clone),
--     new_commit  = HEAD après l'opération,
--   }
local function clone_or_update(config, pkgbase)
    local dest = config.builddir .. "/" .. pkgbase

    local ok, err = prepare_builddir(config)
    if not ok then return nil, err end

    -- Lit le HEAD courant du dépôt (nil si indéterminé).
    local function head_commit()
        local res = util.run_as(config.build_user, { "git", "-C", dest, "rev-parse", "HEAD" })
        if res and res.code == 0 then
            return (res.stdout or ""):gsub("%s+$", "")
        end
        return nil
    end

    local is_repo, derr = luapilot.isdir(dest .. "/.git")
    if derr then return nil, derr end

    if is_repo then
        log.info("mise à jour de " .. pkgbase)
        local old_commit = head_commit()
        local res, rerr = util.run_as(config.build_user, { "git", "-C", dest, "pull", "--ff-only" })
        if not res then return nil, rerr end
        if res.code ~= 0 then return nil, "git pull: " .. res.stderr end
        local new_commit = head_commit()
        return {
            path        = dest,
            first_clone = false,
            updated     = (old_commit ~= nil and new_commit ~= nil and old_commit ~= new_commit),
            old_commit  = old_commit,
            new_commit  = new_commit,
        }
    else
        log.info("clonage de " .. pkgbase)
        local url = (config.aur_url or "https://aur.archlinux.org") .. "/" .. pkgbase .. ".git"
        local res, rerr = util.run_as(config.build_user, { "git", "clone", url, dest })
        if not res then return nil, rerr end
        if res.code ~= 0 then return nil, "git clone: " .. res.stderr end
        return {
            path        = dest,
            first_clone = true,
            updated     = false,
            old_commit  = nil,
            new_commit  = head_commit(),
        }
    end
end

-- fetch.one(config, name) -> (meta, nil) | (nil, message)
-- Résout le PackageBase du paquet via le RPC AUR puis clone/met à jour son
-- dépôt. Renvoie la table de métadonnées de clone_or_update (path + infos de
-- mise à jour). Usage interne au pipeline de build.
function fetch.one(config, name)
    -- Récupérer les informations sur le paquet
    local infos, err = aur.info(config, { name })
    if not infos then
        return nil, err
    end

    local entry = infos[name]
    if not entry then
        return nil, name .. " : introuvable dans l'AUR"
    end

    local meta, cerr = clone_or_update(config, entry.PackageBase)
    if not meta then
        return nil, name .. " : " .. tostring(cerr)
    end

    return meta, nil
end

-- fetch.get(config, pkgs) -> code de sortie (0 = ok, 1 = au moins un échec)
-- Implémente la commande `-G` : pour chaque paquet, clone/met à jour son dépôt
-- AUR et affiche le dossier obtenu. Continue sur erreur et renvoie un code
-- global. La création du builddir est gérée par clone_or_update.
function fetch.get(config, pkgs)
    if not luapilot.which("git") then
        log.error("git introuvable dans le PATH")
        return 1
    end

    local infos, err = aur.info(config, pkgs)
    if not infos then
        log.error(err)
        return 1
    end

    local failed = 0
    for _, name in ipairs(pkgs) do
        local entry = infos[name]
        if not entry then
            log.warn(name .. " : introuvable dans l'AUR")
            failed = failed + 1
        else
            local meta, cerr = clone_or_update(config, entry.PackageBase)
            if not meta then
                log.error(name .. " : " .. tostring(cerr))
                failed = failed + 1
            else
                io.write(meta.path .. "\n")
            end
        end
    end

    return failed == 0 and 0 or 1
end

return fetch
