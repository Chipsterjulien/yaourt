-- build.lua — pipeline de construction des paquets AUR.
--
-- prepare : récupère le dossier (via fetch) + vérifie le PKGBUILD
-- review  : montre le PKGBUILD dans l'éditeur et demande validation
-- one     : orchestre prepare -> review (makepkg à venir)

local fetch      = require("lib.fetch")
local util       = require("lib.util")
local log        = require("lib.log")
local deps       = require("lib.deps")
local pacman     = require("lib.pacman")

local BUILD_USER = "yaourt"

local build      = {}

function build.clean(config, dest, pkgs)
    for _, pkg in ipairs(pkgs) do
        local ok, err = luapilot.remove(pkg)
        if not ok then log.warn("impossible de supprimer le paquet " .. pkg .. " : " .. tostring(err)) end
    end
    return true
end

function build.install(config, dest)
    local res, err = util.run({ "runuser", "-u", BUILD_USER, "--", "makepkg", "--packagelist" }, { cwd = dest })
    if not res then
        log.error(err)
        return false, nil
    end
    if res.code ~= 0 then
        log.error(res.stderr)
        return false, nil
    end

    -- `makepkg --packagelist` liste TOUS les paquets que le PKGBUILD pourrait
    -- produire, y compris un éventuel paquet -debug. Or ce dernier n'est créé
    -- que s'il y a des binaires à débugger : pour un paquet de scripts (ex.
    -- downgrade), le fichier -debug n'existe pas sur le disque. On filtre donc
    -- pour ne garder que les paquets RÉELLEMENT produits, sinon `pacman -U`
    -- échoue sur un fichier fantôme.
    local produced = {}
    for _, path in ipairs(luapilot.split(res.stdout, "\n")) do
        if path ~= "" and luapilot.fileExists(path) then
            produced[#produced + 1] = path
        end
    end

    if #produced == 0 then
        return false, nil
    end

    local argv = luapilot.mergeTables({ "pacman", "-U" }, produced)
    local code = util.passthrough(argv)
    if code ~= 0 then
        return false, nil
    end

    return true, produced
end

function build.make_as_yaourt_user(config, dest)
    local res, err = util.run({ "chown", "-R", BUILD_USER .. ":", dest })
    if not res then
        log.error(err)
        return false
    end
    if res.code ~= 0 then
        log.error(res.stderr)
        return false
    end

    local code = util.passthrough({ "runuser", "-u", BUILD_USER, "--", "makepkg", "-c" }, dest)
    if code ~= 0 then
        log.error("échec de la compilation (makepkg)")
        return false
    end

    return true
end

-- make(config, name) -> true | false
-- Compile puis installe via makepkg le paquet
function build.make(config, dest, is_root)
    if is_root then
        return build.make_as_yaourt_user(config, dest)
    else
        local code = util.passthrough({ "makepkg", "-i", "-c" }, dest)
        return code == 0
    end
end

-- one(config, name) -> (true, nil) | (false, raison)
-- Prépare puis fait réviser le PKGBUILD. S'arrête après la revue.
function build.one(config, name)
    local is_root = util.is_root()
    local build_path, err = build.resolve_builddir(config, is_root)
    if err then return false, err end

    local overrides = { builddir = build_path }
    if is_root then
        overrides.build_user = BUILD_USER
    end
    local bcfg = luapilot.mergeTables(config, overrides)

    local dest, err = build.prepare(bcfg, name)
    if not dest then
        return false, err
    end

    if not build.review(bcfg, dest) then
        return false, name .. " : revue refusée"
    end

    if not build.make(bcfg, dest, is_root) then
        return false, name .. " : échec de la compilation"
    end

    local ok, pkgs = build.install(bcfg, dest)
    if not ok then
        return false, name .. " : échec de l'installation"
    end

    build.clean(bcfg, dest, pkgs) -- On ne va pas vérifier le retour car on fait déjà une alerte lors du nettoyage

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
function build.resolve_builddir(config, is_root)
    if not is_root then
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

-- ensure_repo_deps(config, name) -> (true, nil) | (false, raison)
-- Installe en root les dépendances dépôt manquantes de `name`
-- (pacman -S --asdeps --needed) AVANT la compilation. Nécessaire car makepkg
-- tourne en tant que l'utilisateur de build (sans droits pacman) et est appelé
-- sans -s ; les dépendances dépôt doivent donc déjà être présentes. --asdeps
-- les marque comme dépendances, --needed évite de réinstaller l'existant.
local function ensure_repo_deps(config, name)
    local rdeps, err = deps.repo_deps_of(config, name)
    if not rdeps then
        return false, name .. " : échec résolution des dépendances dépôt ("
            .. tostring(err) .. ")"
    end
    if #rdeps == 0 then
        return true, nil
    end
    local argv = luapilot.mergeTables({ "-S", "--asdeps", "--needed" }, rdeps)
    local code = pacman.passthrough(config, argv)
    if code ~= 0 then
        return false, name .. " : échec installation des dépendances dépôt ("
            .. table.concat(rdeps, ", ") .. ")"
    end
    return true, nil
end

-- build.aur(config, name, built) -> (ok, err, built_names)
-- Brique HAUT NIVEAU : construit un paquet AUR avec toute sa chaîne de
-- dépendances. Résout les dépendances AUR (ordre topologique), puis pour
-- chaque paquet (dépendances AUR d'abord, cible ensuite) installe ses
-- dépendances dépôt en root et le compile via build.one.
--   * `built` : ensemble PARTAGÉ {nom = true} des paquets déjà construits dans
--     la session (anti-doublon entre plusieurs cibles). L'appelant le crée et
--     le conserve d'un appel à l'autre.
--   * retour : ok (booléen), err (message si échec), built_names (liste des
--     paquets effectivement construits lors de cet appel, pour le bilan).
function build.aur(config, name, built)
    built = built or {}
    local built_names = {}

    -- Résolution des dépendances AUR (ordre topologique, cible non incluse).
    local order, rerr = deps.resolve(config, name)
    if not order then
        return false, name .. " : échec de résolution des dépendances ("
            .. tostring(rerr) .. ")", built_names
    end

    -- Construit un paquet : dépendances dépôt (root) puis makepkg (build user).
    local function build_one_full(pkg)
        local ok, derr = ensure_repo_deps(config, pkg)
        if not ok then return false, derr end
        return build.one(config, pkg)
    end

    -- Dépendances AUR d'abord, dans l'ordre résolu.
    for _, dep in ipairs(order) do
        if not built[dep] then
            local ok, err = build_one_full(dep)
            built[dep] = true
            if not ok then
                -- Une dépendance échoue : inutile de tenter la cible.
                return false,
                    (err or (dep .. " : échec")) .. " | "
                    .. name .. " : abandonné (échec de la dépendance " .. dep .. ")",
                    built_names
            end
            built_names[#built_names + 1] = dep
        end
    end

    -- Cible enfin.
    if not built[name] then
        local ok, err = build_one_full(name)
        built[name] = true
        if not ok then
            return false, err, built_names
        end
        built_names[#built_names + 1] = name
    end

    return true, nil, built_names
end

return build
