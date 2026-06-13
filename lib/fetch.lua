-- fetch.lua — récupération des fichiers de build d'un paquet AUR.
--
-- Équivalent de `-G`. Pour chaque paquet :
--   1. on interroge le RPC AUR pour obtenir le PackageBase (le dépôt git
--      est nommé d'après le pkgbase, pas le pkgname — important pour les
--      paquets splittés) ;
--   2. on git clone https://aur.archlinux.org/<pkgbase>.git dans builddir,
--      ou git pull si le clone existe déjà.

local util  = require("lib.util")
local log   = require("lib.log")
local aur   = require("lib.aur")

local fetch = {}

local function prepare_builddir(config)
    local ok, err = util.mkdirp(config.builddir)
    if not ok then return nil, err end

    if config.build_user then
        local res, err = util.run({ "chown", config.build_user .. ":", config.builddir})
        if not res then return nil, err end
        if res.code ~= 0 then return nil, res.stderr end
    end
    return true
end

local function clone_or_update(config, pkgbase)
    local dest = config.builddir .. "/" .. pkgbase

    local ok, err = prepare_builddir(config)
    if not ok then return nil, err end


    local is_repo, derr = luapilot.isdir(dest .. "/.git")
    if derr then return nil, derr end
    if is_repo then
        log.info("mise à jour de " .. pkgbase)
        local res, err = util.run_as(config.build_user, { "git", "-C", dest, "pull", "--ff-only" })
        if not res then return nil, err end
        if res.code ~= 0 then return nil, "git pull: " .. res.stderr end
    else
        log.info("clonage de " .. pkgbase)
        local url = (config.aur_url or "https://aur.archlinux.org") .. "/" .. pkgbase .. ".git"
        local res, err = util.run_as(config.build_user, { "git", "clone", url, dest })
        if not res then return nil, err end
        if res.code ~= 0 then return nil, "git clone: " .. res.stderr end
    end
    return dest
end

function fetch.one(config, name)
    -- Récupérer les informations sur le paquet
    local infos, err = aur.info(config, {name})
    if not infos then
        return nil, err
    end

    local entry = infos[name]
    if not entry then
        return nil, name .. " : introuvable dans l'AUR"
    end

    local dest, cerr = clone_or_update(config, entry.PackageBase)
    if not dest then
        return nil, name .. " : " .. tostring(cerr)
    end

    return dest, nil
end

-- get(config, pkgs) -> code de sortie (0 = ok)
function fetch.get(config, pkgs)
    if not luapilot.which("git") then
        log.error("git introuvable dans le PATH")
        return 1
    end

    local ok, merr = util.mkdirp(config.builddir)
    if not ok then
        log.error("création de builddir impossible : " .. tostring(merr))
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
            local dest, cerr = clone_or_update(config, entry.PackageBase)
            if not dest then
                log.error(name .. " : " .. tostring(cerr))
                failed = failed + 1
            else
                io.write(dest .. "\n")
            end
        end
    end

    return failed == 0 and 0 or 1
end

return fetch
