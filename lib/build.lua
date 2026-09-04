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
local i18n       = require("lib.i18n")
local vcs        = require("lib.vcs")
local builddeps  = require("lib.builddeps")

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
    local res = util.run_as(
        config.build_user,
        { "makepkg", "--packagelist" },
        { cwd = dest }
    )
    if not res or res.code ~= 0 then
        -- Pas de liste exploitable (ex. PKGBUILD illisible) : on ne fait rien,
        -- makepkg signalera lui-même le vrai problème.
        return
    end
    for _, path in ipairs(babet.split(res.stdout, "\n")) do
        if path ~= "" and babet.fileExists(path) then
            local ok, err = babet.remove(path)
            if not ok then
                log.warn(i18n.t("build.remove_stale_failed", {
                    path = path,
                    error = tostring(err),
                }))
            end
        end
    end
end

function build.clean(config, dest, pkgs)
    for _, pkg in ipairs(pkgs) do
        local ok, err = babet.remove(pkg)
        if not ok then
            log.warn(i18n.t("build.remove_package_failed", {
                path = pkg,
                error = tostring(err),
            }))
        end
    end
    return true
end

local function trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

-- package_name(path) -> nom réel contenu dans une archive pacman.
-- Le nom de fichier n'est pas analysé : pkgver/pkgrel/arch peuvent contenir
-- des formes ambiguës. En mode requête sur fichier, `--quiet` demande à pacman
-- de ne renvoyer que le nom canonique enregistré dans l'archive. L'option
-- `--print-format`, elle, appartient au mode transaction et ne doit pas être
-- utilisée avec `-Qp`.
local function package_name(path)
    local res, err = util.run(
        { "pacman", "-Qp", "--quiet", path },
        { env = { LC_ALL = "C" } }
    )
    if not res then
        return nil, tostring(err or i18n.t("common.unknown"))
    end
    if res.code ~= 0 then
        local detail = trim(res.stderr)
        if detail == "" then detail = trim(res.stdout) end
        if detail == "" then detail = i18n.t("common.unknown") end
        return nil, detail
    end

    local name = trim(res.stdout)
    if name == "" or name:find("%s") then
        return nil, i18n.t("process.unexpected_output", {
            command = "pacman -Qp --quiet",
            output = name,
        })
    end
    return name
end

-- install(config, dest, selected, explicit) -> ok, produced, code
-- `makepkg --packagelist` décrit tous les sous-paquets d'un pkgbase. On
-- n'installe que les noms présents dans `selected`; les frères non demandés
-- et les éventuels paquets -debug restent donc hors de la transaction.
--
-- Si un même pkgbase fournit à la fois une dépendance et une cible explicite,
-- tous les sous-paquets retenus sont installés ensemble avec --asdeps (ce qui
-- préserve les dépendances internes au split package), puis les seules cibles
-- explicites sont reclassées via `pacman -D --asexplicit`.
function build.install(config, dest, selected, explicit)
    local res, err = util.run_as(
        config.build_user,
        { "makepkg", "--packagelist" },
        { cwd = dest }
    )
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
    local by_name = {}
    for _, path in ipairs(babet.split(res.stdout, "\n")) do
        if path ~= "" and babet.fileExists(path) then
            produced[#produced + 1] = path
            local name, name_err = package_name(path)
            if name then
                by_name[name] = path
            else
                log.error(i18n.t("common.named_error", {
                    name = path,
                    error = tostring(name_err),
                }))
            end
        end
    end

    if #produced == 0 then
        return false, nil, 1
    end

    local selected_paths = {}
    local explicit_names = {}
    local dependency_count = 0
    explicit = explicit or {}
    for _, name in ipairs(selected or {}) do
        local path = by_name[name]
        if not path then return false, produced, 1 end
        selected_paths[#selected_paths + 1] = path
        if explicit[name] then
            explicit_names[#explicit_names + 1] = name
        else
            dependency_count = dependency_count + 1
        end
    end
    if #selected_paths == 0 then return false, produced, 1 end

    local argv = { "-U" }
    local mixed_reasons = dependency_count > 0 and #explicit_names > 0
    if dependency_count > 0 then argv[#argv + 1] = "--asdeps" end
    argv = babet.mergeTables(argv, selected_paths)
    local code = pacman.passthrough(config, argv)
    if code ~= 0 then
        return false, produced, code
    end

    if mixed_reasons then
        local mark = babet.mergeTables({ "-D", "--asexplicit" }, explicit_names)
        code = pacman.passthrough(config, mark)
        if code ~= 0 then return false, produced, code end
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
            log.error(i18n.t("build.makepkg_failed"))
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
        -- Ne jamais utiliser `makepkg -i` ici : sur un split package, makepkg
        -- transmettrait tous les artefacts à pacman avant que build.install ait
        -- pu sélectionner les seuls sous-paquets requis.
        local argv = babet.mergeTables({ "makepkg" }, makepkg_flags(opts))
        local code = util.passthrough(argv, dest)
        return code == 0, code
    end
end

local function results_for(packages, status, key)
    local out = {}
    for _, package in ipairs(packages) do
        out[#out + 1] = result(status, package, i18n.t(key, { package = package }))
    end
    return out
end

-- one_group(config, group, opts) -> liste de résultats typés.
-- `group` représente un pkgbase unique :
--   * representative : nom utilisé pour le RPC et le clone ;
--   * packages       : sous-paquets réellement requis ;
--   * explicit       : ensemble des cibles demandées directement.
-- Le dépôt, la revue et makepkg ne sont exécutés qu'une fois pour le groupe.
function build.one_group(config, group, opts)
    opts = opts or {}
    local name = group.representative
    local pkgbase = group.base or name
    local packages = group.packages
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

    local variables = { package = C.magenta(table.concat(packages, ", ")) }
    local heading = "build.heading"
    if target then
        if installed then
            local vcs_only = false
            for _, package in ipairs(packages) do
                if opts.vcs_packages and opts.vcs_packages[package] then
                    vcs_only = true
                    break
                end
            end
            if vcs_only then
                heading = "build.heading_vcs"
                variables.version = C.dim(installed)
            else
                heading = "build.heading_update"
                variables.old_version = C.dim(installed)
                variables.new_version = C.green(target)
            end
        else
            heading = "build.heading_new"
            variables.version = C.green(target)
        end
    elseif installed then
        heading = "build.heading_installed"
        variables.version = C.dim(installed)
    end
    print("")
    print(C.cyan("==> ") .. C.bold(i18n.t(heading, variables)))

    local is_root = util.is_root()
    local build_path, err = build.resolve_builddir(config, is_root)
    if err then
        local out = {}
        for _, package in ipairs(packages) do
            out[#out + 1] = result("failed", package,
                i18n.t("common.named_error", { name = package, error = tostring(err) }))
        end
        return out
    end

    local overrides = { builddir = build_path }
    if is_root then
        overrides.build_user = BUILD_USER
    end
    local bcfg = babet.mergeTables(config, overrides)

    local meta, err = build.prepare(bcfg, name)
    if not meta then
        local out = {}
        for _, package in ipairs(packages) do
            out[#out + 1] = result("failed", package,
                i18n.t("common.named_error", { name = package, error = tostring(err) }))
        end
        return out
    end
    local dest = meta.path

    local reviewed, why = build.review(bcfg, meta)
    if not reviewed then
        if why == "refused" then
            return results_for(packages, "refused", "result.review_refused")
        end
        -- why == "review_error" (éditeur indisponible) ou autre : échec technique.
        return results_for(packages, "failed", "result.review_failed")
    end

    -- Capturer la révision après la revue mais avant la compilation. La lecture
    -- du .SRCINFO est inerte ; aucune fonction du PKGBUILD n'est exécutée ici.
    -- L'état ne sera toutefois écrit qu'après une installation réussie.
    local vcs_snapshot
    if vcs.is_candidate(pkgbase) or vcs.is_candidate(name) then
        local snapshot, snapshot_err = vcs.snapshot_file(
            bcfg,
            babet.joinPath(dest, ".SRCINFO")
        )
        if snapshot_err then
            log.warn(i18n.t("common.named_error", {
                name = pkgbase,
                error = tostring(snapshot_err),
            }))
        else
            vcs_snapshot = snapshot
        end
    end

    -- Repartir d'un terrain propre : supprimer un éventuel paquet déjà construit
    -- (résidu d'une compilation/installation précédente interrompue), sinon
    -- makepkg refuserait de réécrire.
    build.clean_stale(bcfg, dest)

    local made, make_code = build.make(bcfg, dest, is_root, opts)
    if not made then
        if util.is_interrupted(make_code) then
            return results_for(packages, "interrupted", "result.build_interrupted")
        end
        return results_for(packages, "failed", "result.build_failed")
    end

    local ok, pkgs, inst_code = build.install(
        bcfg,
        dest,
        packages,
        group.explicit
    )
    if not ok then
        if util.is_interrupted(inst_code) then
            return results_for(packages, "interrupted", "result.install_interrupted")
        end
        return results_for(packages, "install_failed", "result.install_failed")
    end
    if vcs_snapshot then
        local remembered, remember_err = vcs.remember(
            bcfg,
            pkgbase,
            vcs_snapshot
        )
        if not remembered then
            log.warn(i18n.t("common.named_error", {
                name = pkgbase,
                error = tostring(remember_err),
            }))
        end
    end

    build.clean(bcfg, dest, pkgs) -- On ne va pas vérifier le retour car on fait déjà une alerte lors du nettoyage

    return results_for(packages, "ok", "result.installed")
end

-- Compatibilité interne pour les appels unitaires historiques : un seul nom
-- forme naturellement un groupe d'un sous-paquet.
function build.one(config, name, opts, as_dep)
    local explicit = {}
    if not as_dep then explicit[name] = true end
    return build.one_group(config, {
        representative = name,
        packages = { name },
        explicit = explicit,
    }, opts)[1]
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
    if not exists then return nil, i18n.t("build.pkgbuild_missing", { package = name }) end

    return meta, nil
end

-- resolve_builddir(config) -> (dossier, nil) | (nil, message)
function build.resolve_builddir(config, is_root)
    if not is_root then
        return config.builddir
    end

    local u, err = babet.user.get(BUILD_USER)
    if not u then
        return nil, i18n.t("build.user_missing", {
            user = BUILD_USER,
            error = tostring(err),
        })
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
            print(C.cyan("==> ") .. C.bold(i18n.n("review.files", #files)))
        end
        for i, f in ipairs(files) do
            if #files > 1 then
                print(C.cyan("  [" .. i .. "/" .. #files .. "] ") .. f)
            end
            local code = util.passthrough({ config.editor, dest .. "/" .. f })
            if code ~= 0 then
                print(i18n.t("review.open_failed", {
                    file = f,
                    editor = tostring(config.editor),
                }))
                return false, "review_error"
            end
        end
    elseif meta.updated then
        -- Mise à jour : diff git de TOUS les fichiers entre les deux commits.
        print("")
        print(C.cyan("==> ") .. C.bold(i18n.t("review.changes")))
        local res = util.run_as(config.build_user, {
            "git", "-C", dest, "diff", "--color=always",
            meta.old_commit .. ".." .. meta.new_commit,
        })
        if res and res.code == 0 and (res.stdout or "") ~= "" then
            io.write(res.stdout)
            if not (res.stdout:match("\n$")) then io.write("\n") end
        else
            -- Diff vide ou indisponible (ex. changements hors fichiers suivis).
            print(C.dim("  " .. i18n.t("review.no_changes")))
        end
    else
        -- Dépôt inchangé depuis la dernière fois : rien à revoir.
        print(C.dim("==> " .. i18n.t("review.unchanged")))
        return true
    end

    io.write(i18n.t("review.continue") .. " ")
    io.flush()
    local ans = (io.read("l") or ""):lower()
    if i18n.is_answer(ans, "no") then
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
        return false, i18n.t("deps.repo_resolution_failed", {
            package = name,
            error = tostring(err),
        })
    end
    if #rdeps == 0 then
        return true, nil
    end
    local argv = babet.mergeTables({ "-S", "--asdeps", "--needed" }, rdeps)
    local code = pacman.passthrough(config, argv)
    if code ~= 0 then
        return false, i18n.t("deps.repo_install_failed", {
            package = name,
            dependencies = table.concat(rdeps, ", "),
        })
    end
    return true, nil
end

-- plan(config, targets) -> plan de construction groupé par PackageBase.
-- Le solveur travaille d'abord avec les noms de paquets (car ce sont eux qui
-- portent Depends/MakeDepends/CheckDepends), puis cette fonction replie le
-- graphe sur les pkgbase. Deux sous-paquets frères partagent alors une seule
-- étape clone, revue et makepkg, sans perdre la liste précise des artefacts à
-- installer.
function build.plan(config, targets, opts)
    local resolved, rerr = deps.resolve_many(config, targets, opts)
    if not resolved then return nil, rerr end
    if #resolved.order == 0 then
        return { order = {}, bases = {}, missing = {} }, nil
    end

    local infos, ierr = aur.info(config, resolved.order)
    if not infos then return nil, ierr end

    local explicit = {}
    for _, name in ipairs(targets) do explicit[name] = true end

    local bases, missing = {}, {}
    local package_base = {}
    for _, name in ipairs(resolved.order) do
        local entry = infos[name]
        if not entry then
            missing[#missing + 1] = name
        else
            local base = entry.PackageBase or entry.Name or name
            package_base[name] = base
            local group = bases[base]
            if not group then
                group = {
                    base = base,
                    representative = name,
                    packages = {},
                    package_set = {},
                    explicit = {},
                    dependencies = {},
                }
                bases[base] = group
            end
            if not group.package_set[name] then
                group.package_set[name] = true
                group.packages[#group.packages + 1] = name
            end
            if explicit[name] then group.explicit[name] = true end
        end
    end

    -- Arêtes entre pkgbase. Les dépendances internes à un split package ne
    -- créent aucune étape supplémentaire : elles seront installées ensemble.
    for package, direct in pairs(resolved.direct) do
        local base = package_base[package]
        local group = base and bases[base]
        if group then
            for _, dependency in ipairs(direct) do
                local dep_base = package_base[dependency]
                if dep_base and dep_base ~= base then
                    group.dependencies[dep_base] = true
                end
            end
        end
    end

    local order, visited, visiting = {}, {}, {}
    local function visit(base)
        if visited[base] or visiting[base] then return end
        visiting[base] = true
        local names = {}
        for dependency in pairs(bases[base].dependencies) do
            names[#names + 1] = dependency
        end
        table.sort(names)
        for _, dependency in ipairs(names) do visit(dependency) end
        visiting[base] = nil
        visited[base] = true
        order[#order + 1] = base
    end
    -- L'ordre des paquets résolu stabilise celui des groupes indépendants.
    for _, package in ipairs(resolved.order) do
        local base = package_base[package]
        if base then visit(base) end
    end

    return { order = order, bases = bases, missing = missing }, nil
end

-- aur_many(config, targets, opts) -> liste de résultats typés.
-- Toute la transaction AUR est planifiée avant le premier effet de bord. Un
-- pkgbase est construit une seule fois, même si plusieurs cibles directes ou
-- dépendances désignent des sous-paquets issus du même PKGBUILD.
function build.aur_many(config, targets, opts)
    opts = opts or {}
    local results = {}
    local cleanup_state = builddeps.start(config)
    local plan, rerr = build.plan(config, targets, opts)
    if not plan then
        for _, name in ipairs(targets) do
            results[#results + 1] = result("failed", name,
                i18n.t("deps.aur_resolution_failed", {
                    package = name,
                    error = tostring(rerr),
                }))
        end
        builddeps.finish(config, cleanup_state, opts)
        return results
    end

    for _, name in ipairs(plan.missing) do
        results[#results + 1] = result("failed", name,
            i18n.t("aur.package_not_found", { package = name }))
    end

    local status = {}
    local interrupted = false
    for _, base in ipairs(plan.order) do
        local group = plan.bases[base]
        local failed_dependency
        for dependency in pairs(group.dependencies) do
            if status[dependency] == false then
                failed_dependency = dependency
                break
            end
        end

        if failed_dependency then
            for _, package in ipairs(group.packages) do
                results[#results + 1] = result("failed", package,
                    i18n.t("deps.abandoned", {
                        package = package,
                        dependency = failed_dependency,
                    }))
            end
            status[base] = false
        else
            local dependency_error
            for _, package in ipairs(group.packages) do
                local ok, derr = ensure_repo_deps(config, package)
                if not ok then
                    dependency_error = derr
                    break
                end
            end

            local group_results
            if dependency_error then
                group_results = {}
                for _, package in ipairs(group.packages) do
                    group_results[#group_results + 1] = result("failed", package,
                        i18n.t("common.named_error", {
                            name = package,
                            error = tostring(dependency_error),
                        }))
                end
            else
                local has_explicit = next(group.explicit) ~= nil
                group_results = build.one_group(
                    config,
                    group,
                    has_explicit and opts or nil
                )
            end

            local ok = true
            local group_interrupted = false
            for _, item in ipairs(group_results) do
                results[#results + 1] = item
                if not item.ok then ok = false end
                if item.status == "interrupted" then
                    group_interrupted = true
                    interrupted = true
                end
            end
            status[base] = ok
            if group_interrupted then break end
        end
    end

    builddeps.finish(config, cleanup_state, {
        noconfirm = opts.noconfirm,
        passthrough = opts.passthrough,
        interrupted = interrupted,
    })

    return results
end

-- Compatibilité avec l'ancienne surface interne à une cible. Les chemins
-- utilisateur (-S et -Syu) appellent aur_many afin de partager le plan global.
function build.aur(config, name, _, opts)
    return build.aur_many(config, { name }, opts)
end

return build
