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

-- Résultat typé d'une construction de paquet. status ∈ {ok, refused, failed,
-- install_failed, interrupted}. ok est un raccourci (status == "ok"). name est
-- le paquet concerné, message un texte lisible pour le bilan.
function build.result(status, name, message)
    return {
        ok      = (status == "ok"),
        status  = status,
        name    = name,
        message = message,
    }
end

local result = build.result

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
    for _, path in ipairs(babet.split(res.stdout, "\n")) do
        if path ~= "" and babet.fileExists(path) then
            local ok, err = babet.remove(path)
            if not ok then
                log.warn("impossible de supprimer le paquet résiduel " .. path .. " : " .. tostring(err))
            end
        end
    end
end

function build.clean(config, dest, pkgs)
    for _, pkg in ipairs(pkgs) do
        local ok, err = babet.remove(pkg)
        if not ok then log.warn("impossible de supprimer le paquet " .. pkg .. " : " .. tostring(err)) end
    end
    return true
end

function build.install(config, dest, as_dep)
    local res, err = util.run({ "runuser", "-u", BUILD_USER, "--", "makepkg", "--packagelist" }, { cwd = dest })
    if not res then
        log.error(err)
        return false, nil, 1
    end
    if res.code ~= 0 then
        log.error(res.stderr)
        return false, nil, 1
    end

    -- `makepkg --packagelist` liste TOUS les paquets que le PKGBUILD pourrait
    -- produire, y compris un éventuel paquet -debug. Or ce dernier n'est créé
    -- que s'il y a des binaires à débugger : pour un paquet de scripts (ex.
    -- downgrade), le fichier -debug n'existe pas sur le disque. On filtre donc
    -- pour ne garder que les paquets RÉELLEMENT produits, sinon `pacman -U`
    -- échoue sur un fichier fantôme.
    local produced = {}
    for _, path in ipairs(babet.split(res.stdout, "\n")) do
        if path ~= "" and babet.fileExists(path) then
            produced[#produced + 1] = path
        end
    end

    if #produced == 0 then
        return false, nil, 1
    end

    -- --asdeps : marque le paquet comme dépendance (installé automatiquement)
    -- et non comme demande explicite. Réservé aux dépendances AUR tirées par la
    -- résolution ; la cible demandée par l'utilisateur reste explicite, afin
    -- qu'un `pacman -Rcs <cible>` retire ensuite ses dépendances devenues
    -- orphelines.
    local pre = { "pacman", "-U" }
    if as_dep then pre[#pre + 1] = "--asdeps" end
    local argv = babet.mergeTables(pre, produced)
    local code = util.passthrough(argv)
    if code ~= 0 then
        return false, nil, code
    end

    return true, produced, 0
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
        return false, 1
    end
    if res.code ~= 0 then
        log.error(res.stderr)
        return false, 1
    end

    local argv = babet.mergeTables({ "runuser", "-u", BUILD_USER, "--", "makepkg" }, makepkg_flags(opts))
    local code = util.passthrough(argv, dest)
    if code ~= 0 then
        -- On ne crie pas « échec » si l'utilisateur a simplement interrompu.
        if not util.is_interrupted(code) then
            log.error("échec de la compilation (makepkg)")
        end
        return false, code
    end

    return true, 0
end

-- make(config, name) -> true | false
-- Compile puis installe via makepkg le paquet
function build.make(config, dest, is_root, opts)
    if is_root then
        return build.make_as_yaourt_user(config, dest, opts)
    else
        local argv = babet.mergeTables({ "makepkg", "-i" }, makepkg_flags(opts))
        local code = util.passthrough(argv, dest)
        return code == 0, code
    end
end

-- one(config, name) -> (true, nil) | (false, raison)
-- Prépare puis fait réviser le PKGBUILD. S'arrête après la revue.
function build.one(config, name, opts, as_dep)
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
    if err then return result("failed", name, name .. " : " .. tostring(err)) end

    local overrides = { builddir = build_path }
    if is_root then
        overrides.build_user = BUILD_USER
    end
    local bcfg = babet.mergeTables(config, overrides)

    local meta, err = build.prepare(bcfg, name)
    if not meta then
        return result("failed", name, name .. " : " .. tostring(err))
    end
    local dest = meta.path

    local reviewed, why = build.review(bcfg, meta)
    if not reviewed then
        if why == "refused" then
            return result("refused", name, name .. " : revue refusée")
        end
        -- why == "review_error" (éditeur indisponible) ou autre : échec technique.
        return result("failed", name, name .. " : revue impossible")
    end

    -- Repartir d'un terrain propre : supprimer un éventuel paquet déjà construit
    -- (résidu d'une compilation/installation précédente interrompue), sinon
    -- makepkg refuserait de réécrire.
    build.clean_stale(bcfg, dest)

    local made, make_code = build.make(bcfg, dest, is_root, opts)
    if not made then
        if util.is_interrupted(make_code) then
            return result("interrupted", name, name .. " : compilation interrompue (Ctrl+C)")
        end
        return result("failed", name, name .. " : échec de la compilation")
    end

    local ok, pkgs, inst_code = build.install(bcfg, dest, as_dep)
    if not ok then
        if util.is_interrupted(inst_code) then
            return result("interrupted", name, name .. " : installation interrompue (Ctrl+C)")
        end
        return result("install_failed", name, name .. " : échec de l'installation")
    end

    build.clean(bcfg, dest, pkgs) -- On ne va pas vérifier le retour car on fait déjà une alerte lors du nettoyage

    return result("ok", name, name .. " : installé")
end

-- prepare(config, name) -> (dossier, nil) | (nil, message)
function build.prepare(config, name)
    local meta, err = fetch.one(config, name)
    if err ~= nil then return nil, err end

    -- Construire l'emplacement du PKGBUILD
    local pkgbuild_path = meta.path .. "/PKGBUILD"

    -- Tester l'existence du PKGBUILD
    local exists, cerr = babet.fileExists(pkgbuild_path)
    if cerr ~= nil then return nil, cerr end
    if not exists then return nil, name .. " : PKGBUILD introuvable" end

    return meta, nil
end

-- resolve_builddir(config) -> (dossier, nil) | (nil, message)
function build.resolve_builddir(config, is_root)
    if not is_root then
        return config.builddir
    end

    local u, err = babet.user.get(BUILD_USER)
    if not u then
        return nil, "L'utilisateur " .. BUILD_USER .. " est introuvable : " .. tostring(err)
    end
    return babet.joinPath(u.home, ".cache", BUILD_USER)
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
        -- Premier clone : review de TOUS les fichiers versionnés du dépôt
        -- (PKGBUILD, .install, patches, scripts locaux…), pas seulement le
        -- PKGBUILD. Un .install s'exécute en root à l'installation et un patch
        -- modifie les sources : tout doit être visible avant de construire.
        -- PKGBUILD est placé en tête ; s'il n'y a que lui, comportement inchangé.
        local files = { "PKGBUILD" }
        local listed = util.run_as(config.build_user,
            { "git", "-C", dest, "ls-files" })
        if listed and listed.code == 0 then
            for _, f in ipairs(babet.split(listed.stdout, "\n")) do
                if f ~= "" and f ~= "PKGBUILD" then
                    files[#files + 1] = f
                end
            end
        end

        -- Ouverture SÉQUENTIELLE : un fichier à la fois, dans l'ordre. On évite
        -- d'ouvrir tous les fichiers d'un coup (ex. « vim f1 … f6 »), qui
        -- n'affiche que le premier et déroute l'utilisateur (E173 à la
        -- fermeture). Chaque fichier est ainsi explicitement présenté à la
        -- revue, quel que soit l'éditeur. Pour un paquet à un seul fichier, le
        -- comportement est identique à avant.
        if #files > 1 then
            print("")
            print(C.cyan("==> ") .. C.bold(#files .. " fichiers à examiner")
                .. C.dim(" (ouverts un par un)"))
        end
        for i, f in ipairs(files) do
            if #files > 1 then
                print(C.cyan("  [" .. i .. "/" .. #files .. "] ") .. f)
            end
            local code = util.passthrough({ config.editor, dest .. "/" .. f })
            if code ~= 0 then
                print("Impossible d'ouvrir " .. f .. " avec '" .. tostring(config.editor) .. "'")
                return false, "review_error"
            end
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
        return false, "refused"
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
    local argv = babet.mergeTables({ "-S", "--asdeps", "--needed" }, rdeps)
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
-- build.aur(config, name, built, opts) -> liste de résultats typés.
-- Construit les dépendances AUR (marquées --asdeps) puis la cible. Chaque
-- paquet traité produit un résultat (build.result). Si une dépendance échoue
-- (ou est refusée/interrompue), on s'arrête : la cible n'est pas tentée, et un
-- résultat « failed » est ajouté pour la cible abandonnée. `built` est l'index
-- anti-doublon partagé entre les cibles d'une même invocation.
function build.aur(config, name, built, opts)
    built = built or {}
    opts = opts or {}
    local results = {}

    -- Résolution des dépendances AUR (ordre topologique, cible non incluse).
    local order, rerr = deps.resolve(config, name)
    if not order then
        results[#results + 1] = result("failed", name,
            name .. " : échec de résolution des dépendances (" .. tostring(rerr) .. ")")
        return results
    end

    -- Construit un paquet : dépendances dépôt (root) puis makepkg (build user).
    -- `pkg_opts` : force/needed ne s'appliquent qu'à la cible demandée, pas aux
    -- dépendances tirées automatiquement (on ne force pas tout le graphe).
    local function build_one_full(pkg, pkg_opts, as_dep)
        local ok, derr = ensure_repo_deps(config, pkg)
        if not ok then
            return result("failed", pkg, pkg .. " : " .. tostring(derr))
        end
        return build.one(config, pkg, pkg_opts, as_dep)
    end

    -- Dépendances AUR d'abord, dans l'ordre résolu (sans force/needed, marquées
    -- --asdeps pour qu'un -Rcs de la cible les retire si elles deviennent
    -- orphelines).
    for _, dep in ipairs(order) do
        if not built[dep] then
            local res = build_one_full(dep, nil, true)
            built[dep] = true
            results[#results + 1] = res
            if not res.ok then
                -- Une dépendance n'a pas abouti : inutile de tenter la cible.
                results[#results + 1] = result("failed", name,
                    name .. " : abandonné (dépendance " .. dep .. " non aboutie)")
                return results
            end
        end
    end

    -- Cible enfin (avec les options de la commande : force/needed ; installée
    -- explicitement, donc as_dep = false).
    if not built[name] then
        local res = build_one_full(name, opts, false)
        built[name] = true
        results[#results + 1] = res
    end

    return results
end

return build
