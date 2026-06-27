-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
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
local color      = require("lib.color")
local aur        = require("lib.aur")

local BUILD_USER = "yaourt"

local build      = {}

-- build.clean_stale(config, dest) : supprime les paquets déjà construits qui
-- traînent dans le dossier de build AVANT une nouvelle compilation. Sinon
-- makepkg refuse de réécrire (« Un paquet a déjà été compilé ») et bloque —
-- typiquement après une installation interrompue (Ctrl+C) qui a laissé le
-- .pkg.tar.* sans l'installer. On vise précisément les chemins que le PKGBUILD
-- produirait (makepkg --packagelist), pas un effacement aveugle du dossier.
function build.clean_stale(config, dest)
    local res = util.run({ "runuser", "-u", BUILD_USER, "--", "makepkg", "--packagelist" }, { cwd = dest })
    if not res or res.code ~= 0 then
        -- Pas de liste exploitable (ex. PKGBUILD illisible) : on ne fait rien,
        -- makepkg signalera lui-même le vrai problème.
        return
    end
    for _, path in ipairs(luapilot.split(res.stdout, "\n")) do
        if path ~= "" and luapilot.fileExists(path) then
            local ok, err = luapilot.remove(path)
            if not ok then
                log.warn("impossible de supprimer le paquet résiduel " .. path .. " : " .. tostring(err))
            end
        end
    end
end

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

-- makepkg_flags(opts) -> liste des options makepkg issues de la commande.
-- -c (clean) est toujours présent ; -f force la reconstruction même si le
-- paquet existe déjà ; --needed évite de reconstruire un paquet déjà installé
-- et à jour. Seuls force et needed sont repris (périmètre prudent côté AUR).
local function makepkg_flags(opts)
    local flags = { "-c" }
    if opts and opts.force then flags[#flags + 1] = "-f" end
    if opts and opts.needed then flags[#flags + 1] = "--needed" end
    return flags
end

function build.make_as_yaourt_user(config, dest, opts)
    local res, err = util.run({ "chown", "-R", BUILD_USER .. ":", dest })
    if not res then
        log.error(err)
        return false
    end
    if res.code ~= 0 then
        log.error(res.stderr)
        return false
    end

    local argv = luapilot.mergeTables({ "runuser", "-u", BUILD_USER, "--", "makepkg" }, makepkg_flags(opts))
    local code = util.passthrough(argv, dest)
    if code ~= 0 then
        log.error("échec de la compilation (makepkg)")
        return false
    end

    return true
end

-- make(config, name) -> true | false
-- Compile puis installe via makepkg le paquet
function build.make(config, dest, is_root, opts)
    if is_root then
        return build.make_as_yaourt_user(config, dest, opts)
    else
        local argv = luapilot.mergeTables({ "makepkg", "-i" }, makepkg_flags(opts))
        local code = util.passthrough(argv, dest)
        return code == 0
    end
end

-- one(config, name) -> (true, nil) | (false, raison)
-- Prépare puis fait réviser le PKGBUILD. S'arrête après la revue.
function build.one(config, name, opts)
    opts = opts or {}
    local C = color.new(config.color)

    -- Annonce visible du paquet en cours de construction (façon yaourt) :
    -- « ==> Construction de <nom> (ancienne -> nouvelle) », ou
    -- « ==> Construction de <nom> (nouvelle installation <ver>) » si absent.
    -- Version installée : pacman -Q (local). Version cible : RPC AUR.
    local installed
    do
        local qres = util.run({ "pacman", "-Q", name })
        if qres and qres.code == 0 then
            installed = (qres.stdout or ""):match("^%S+%s+(%S+)")
        end
    end
    local target
    do
        local info = aur.info(config, { name })
        if info and info[name] then target = info[name].Version end
    end

    local line = C.cyan("==> ") .. C.bold("Construction de ") .. C.magenta(name)
    if target then
        if installed then
            line = line .. " (" .. C.dim(installed) .. " -> " .. C.green(target) .. ")"
        else
            line = line .. " (" .. C.green("nouvelle installation " .. target) .. ")"
        end
    elseif installed then
        line = line .. " (" .. C.dim(installed) .. ")"
    end
    print("")
    print(line)

    local is_root = util.is_root()
    local build_path, err = build.resolve_builddir(config, is_root)
    if err then return false, err end

    local overrides = { builddir = build_path }
    if is_root then
        overrides.build_user = BUILD_USER
    end
    local bcfg = luapilot.mergeTables(config, overrides)

    local meta, err = build.prepare(bcfg, name)
    if not meta then
        return false, err
    end
    local dest = meta.path

    if not build.review(bcfg, meta) then
        return false, name .. " : revue refusée"
    end

    -- Repartir d'un terrain propre : supprimer un éventuel paquet déjà construit
    -- (résidu d'une compilation/installation précédente interrompue), sinon
    -- makepkg refuserait de réécrire.
    build.clean_stale(bcfg, dest)

    if not build.make(bcfg, dest, is_root, opts) then
        -- On ne peut pas distinguer de façon fiable un vrai échec d'une
        -- interruption (Ctrl+C) : le code de retour est aplati. Message neutre.
        return false, name .. " : compilation non terminée (échec ou interruption)"
    end

    local ok, pkgs = build.install(bcfg, dest)
    if not ok then
        return false, name .. " : installation non terminée (échec ou interruption)"
    end

    build.clean(bcfg, dest, pkgs) -- On ne va pas vérifier le retour car on fait déjà une alerte lors du nettoyage

    return true, nil
end

-- prepare(config, name) -> (dossier, nil) | (nil, message)
function build.prepare(config, name)
    local meta, err = fetch.one(config, name)
    if err ~= nil then return nil, err end

    -- Construire l'emplacement du PKGBUILD
    local pkgbuild_path = meta.path .. "/PKGBUILD"

    -- Tester l'existence du PKGBUILD
    local exists, cerr = luapilot.fileExists(pkgbuild_path)
    if cerr ~= nil then return nil, cerr end
    if not exists then return nil, name .. " : PKGBUILD introuvable" end

    return meta, nil
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
-- build.review(config, meta) -> bool (true = on poursuit, false = refusé)
-- Selon le contexte de récupération (meta) :
--   * premier clone      -> review complète : on ouvre le PKGBUILD dans
--     l'éditeur (rien à comparer, l'utilisateur découvre le paquet) ;
--   * mise à jour modifiée -> diff git des fichiers entre l'ancien et le
--     nouveau commit (met en évidence ce qui a changé, .install et patches
--     compris — ce sont aussi du code exécuté) ;
--   * mise à jour sans changement -> rien à revoir, on poursuit directement.
-- Dans les deux premiers cas, on demande confirmation avant de continuer.
function build.review(config, meta)
    local C = color.new(config.color)
    local dest = meta.path

    if meta.first_clone then
        -- Premier clone : review complète du PKGBUILD dans l'éditeur.
        local result = util.passthrough({ config.editor, dest .. "/PKGBUILD" })
        if result ~= 0 then
            print("Impossible d'ouvrir le PKGBUILD avec '" .. tostring(config.editor) .. "'")
            return false
        end
    elseif meta.updated then
        -- Mise à jour : diff git de TOUS les fichiers entre les deux commits.
        print("")
        print(C.cyan("==> ") .. C.bold("Modifications depuis la dernière version :"))
        local res = util.run_as(config.build_user, {
            "git", "-C", dest, "diff", "--color=always",
            meta.old_commit .. ".." .. meta.new_commit,
        })
        if res and res.code == 0 and (res.stdout or "") ~= "" then
            io.write(res.stdout)
            if not (res.stdout:match("\n$")) then io.write("\n") end
        else
            -- Diff vide ou indisponible (ex. changements hors fichiers suivis).
            print(C.dim("  (aucune modification de fichier à afficher)"))
        end
    else
        -- Dépôt inchangé depuis la dernière fois : rien à revoir.
        print(C.dim("==> PKGBUILD inchangé depuis la dernière validation."))
        return true
    end

    io.write("Continuer la construction ? [O/n] ")
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
function build.aur(config, name, built, opts)
    built = built or {}
    opts = opts or {}
    local built_names = {}

    -- Résolution des dépendances AUR (ordre topologique, cible non incluse).
    local order, rerr = deps.resolve(config, name)
    if not order then
        return false, name .. " : échec de résolution des dépendances ("
            .. tostring(rerr) .. ")", built_names
    end

    -- Construit un paquet : dépendances dépôt (root) puis makepkg (build user).
    -- `pkg_opts` : force/needed ne s'appliquent qu'à la cible demandée, pas aux
    -- dépendances tirées automatiquement (on ne force pas tout le graphe).
    local function build_one_full(pkg, pkg_opts)
        local ok, derr = ensure_repo_deps(config, pkg)
        if not ok then return false, derr end
        return build.one(config, pkg, pkg_opts)
    end

    -- Dépendances AUR d'abord, dans l'ordre résolu (sans force/needed).
    for _, dep in ipairs(order) do
        if not built[dep] then
            local ok, err = build_one_full(dep, nil)
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

    -- Cible enfin (avec les options de la commande : force/needed).
    if not built[name] then
        local ok, err = build_one_full(name, opts)
        built[name] = true
        if not ok then
            return false, err, built_names
        end
        built_names[#built_names + 1] = name
    end

    return true, nil, built_names
end

return build
