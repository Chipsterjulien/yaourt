-- build.lua — pipeline de construction des paquets AUR.
--
-- prepare : récupère le dossier (via fetch) + vérifie le PKGBUILD
-- review  : montre le PKGBUILD dans l'éditeur et demande validation
-- one     : orchestre prepare -> review (makepkg à venir)

local fetch = require("lib.fetch")
local util  = require("lib.util")
local log   = require("lib.log")

local BUILD_USER = "yaourt"

local build = {}

function build.clean(config, dest)
    return true
end

function build.install(config, dest)
    local inspect = require("inspect")
    local res, err = util.run({ "runuser", "-u", BUILD_USER, "--", "makepkg", "--packagelist" }, {cwd = dest})
    if not res then
        log.error(err)
        return false
    end
    if res.code ~= 0 then
        log.error(res.stderr)
        return false
    end

    print(inspect(res))

    return true
end

function build.make_as_yaourt_user(config, dest)
    local res, err = util.run({"chown", "-R", BUILD_USER .. ":", dest})
    if not res then
        log.error(err)
        return false
    end
    if res.code ~= 0 then
        log.error(res.stderr)
        return false
    end

    local code = util.passthrough({"runuser", "-u", BUILD_USER, "--", "makepkg"}, dest)
    if code ~= 0 then
        log.error("échec de la compilation (makepkg)")
        return false
    end

    return true
end

-- make(config, name) -> true | false
-- Compile puis installe via makepkg le paquet
function build.make(config, dest)
    if util.is_root() then
        return build.make_as_yaourt_user(config, dest)
    else
        local code = util.passthrough({"makepkg", "-i"}, dest)
        return code == 0
    end
end

-- one(config, name) -> (true, nil) | (false, raison)
-- Prépare puis fait réviser le PKGBUILD. S'arrête après la revue.
function build.one(config, name)
    local build_path, err = build.resolve_builddir(config)
    if err then return false, err end

    local bcfg = luapilot.mergeTables(config, { builddir = build_path })

    local dest, err = build.prepare(bcfg, name)
    if not dest then
        return false, err
    end

    if not build.review(bcfg, dest) then
        return false, name .. " : revue refusée"
    end

    if not build.make(bcfg, dest) then
        return false, name .. " : échec de la compilation"
    end

    if not build.install(bcfg, dest) then
        return false, name .. " : échec de l'installation"
    end

    if not build.clean(bcfg, dest) then
        return false, name .. " : échec lors du nettoyage"
    end

    return true, nil
end

-- prepare(config, name) -> (dossier, nil) | (nil, message)
function build.prepare(config, name)
    local dest, err = fetch.one(config, name)
    if err ~= nil then return nil, err end

    -- Construire l'emplacement du PKGBUILD
    local pkgbuild_path = dest .. "/PKGBUILD"

    -- Tester l'existence du PKGBUILD
    local exists, cerr = luapilot.fileExists(pkgbuild_path)
    if cerr ~= nil then return nil, cerr end
    if not exists then return nil, name .. " : PKGBUILD introuvable" end

    return dest, nil
end

-- resolve_builddir(config) -> (dossier, nil) | (nil, message)
function build.resolve_builddir(config)
    if not util.is_root() then
        return config.builddir
    end

    local u, err = luapilot.user.get(BUILD_USER)
    if not u then
        return nil, "L'utilisateur " .. BUILD_USER .. " est introuvable : " .. tostring(err)
    end
    return luapilot.joinPath(u.home, ".cache", BUILD_USER)
end

-- review(config, dest) -> bool : montre le PKGBUILD et demande validation.
function build.review(config, dest)
    local pkgbuild_path = dest .. "/PKGBUILD"
    local cmd = { config.editor, pkgbuild_path }
    local result = util.passthrough(cmd)
    if result ~= 0 then
        print("Impossible d'ouvrir le PKGBUILD avec '" .. tostring(config.editor) .. "'")
        return false
    end

    io.write("Voulez-vous continuer ? [O/n] ")
    io.flush()
    local ans = (io.read("l") or ""):lower()
    if ans == "n" or ans == "non" then
        return false
    end
    return true
end

return build
