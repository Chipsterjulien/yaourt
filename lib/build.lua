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
function build.result(status, name, message, code)
    return {
        ok      = (status == "ok" or status == "skipped"),
        status  = status,
        code    = code,
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
    if not util.complete(res) then
        if res and util.is_interrupted(res.code) then return false, res.code end
        -- Pas de liste exploitable (ex. PKGBUILD illisible) : on ne fait rien,
        -- makepkg signalera lui-même le vrai problème.
        return
    end
    for _, path in ipairs(babet.split(res.stdout, "\n")) do
        if path ~= "" and babet.fileExists(path) then
            local ok, err, code = util.remove_artifact(config, path)
            if util.is_interrupted(code) then return false, code end
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
        local ok, err, code = util.remove_artifact(config, pkg)
        if util.is_interrupted(code) then return false, code end
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
function build.install(config, dest, selected, explicit, opts)
    opts = opts or {}
    local res, err = util.run_as(
        config.build_user,
        { "makepkg", "--packagelist" },
        { cwd = dest }
    )
    if not res then
        log.error(err)
        return false, nil, 1
    end
    if not util.complete(res) then
        log.error(res.stderr)
        return false, nil, res.code ~= 0 and res.code or 1
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

    local was_explicit, previous_err, previous_code = pacman.explicit_packages()
    if not was_explicit then
        log.error(previous_err)
        return false, produced, previous_code and previous_code ~= 0 and previous_code or 1
    end
    local selected_paths = {}
    local explicit_names = {}
    local dependency_count = 0
    explicit = explicit or {}
    for _, name in ipairs(selected or {}) do
        local path = by_name[name]
        if not path then return false, produced, 1 end
        selected_paths[#selected_paths + 1] = path
        local want_explicit = explicit[name] or was_explicit[name]
        if explicit[name] and opts.reason then want_explicit = opts.reason=="asexplicit" end
        if want_explicit then
            explicit_names[#explicit_names + 1] = name
        else
            dependency_count = dependency_count + 1
        end
    end
    if #selected_paths == 0 then return false, produced, 1 end

    local argv = { "-U" }
    local mixed_reasons = dependency_count > 0 and #explicit_names > 0
    argv[#argv+1] = dependency_count > 0 and "--asdeps" or "--asexplicit"
    if opts.needed then argv[#argv+1]="--needed" end
    if opts.noconfirm then argv[#argv+1]="--noconfirm" end
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
-- paquet existe déjà. --needed est traité par le plan puis par pacman -U,
-- pas par makepkg sans -i.
local function makepkg_flags(opts)
    local flags = { "-c" }
    if opts and opts.force then flags[#flags + 1] = "-f" end
    return flags
end

function build.make_as_yaourt_user(config, dest, opts)
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

local function results_for(packages, status, key, code)
    local out = {}
    for _, package in ipairs(packages) do
        out[#out + 1] = result(status, package, i18n.t(key, { package = package }), code)
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
    -- Version installée : pacman -Q (local). Le RPC donne une version cible
    -- pour les paquets ordinaires ; pour les VCS, pkgver() la calculera.
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
    local development = vcs.is_candidate(pkgbase) or vcs.is_candidate(name)
    local vcs_changed = false
    for _, package in ipairs(packages) do
        development = development or vcs.is_candidate(package)
        if opts.vcs_packages and opts.vcs_packages[package] then vcs_changed = true end
    end
    if development or vcs_changed then
        -- Do not advertise an AUR version as the result of a VCS build,
        -- nor a new upstream revision during a simple reinstallation.
        if installed then
            heading = vcs_changed and "build.heading_vcs" or "build.heading_installed"
            variables.version = C.dim(installed)
        end
    elseif target then
        if installed then
            heading = "build.heading_update"
            variables.old_version = C.dim(installed)
            variables.new_version = C.green(target)
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

    local meta, err, prepare_code = build.prepare(bcfg, name)
    if not meta then
        if util.is_interrupted(prepare_code) then return results_for(packages, "interrupted", "result.build_interrupted", prepare_code) end
        local out = {}
        for _, package in ipairs(packages) do
            out[#out + 1] = result("failed", package,
                i18n.t("common.named_error", { name = package, error = tostring(err) }))
        end
        return out
    end
    local dest = meta.path

    local reviewed, why, review_code = build.review(bcfg, meta)
    if not reviewed then
        if util.is_interrupted(review_code) then return results_for(packages, "interrupted", "result.build_interrupted", review_code) end
        if why == "refused" then
            return results_for(packages, "refused", "result.review_refused")
        end
        log.error(tostring(why))
        -- why == "review_error" (éditeur indisponible) ou autre : échec technique.
        return results_for(packages, "failed", "result.review_failed")
    end

    -- Capturer la révision après la revue mais avant la compilation. La lecture
    -- du .SRCINFO est inerte ; aucune fonction du PKGBUILD n'est exécutée ici.
    -- L'état ne sera toutefois écrit qu'après une installation réussie.
    local vcs_snapshot
    if vcs.is_candidate(pkgbase) or vcs.is_candidate(name) then
        local snapshot, snapshot_err, snapshot_code = vcs.snapshot_file(
            bcfg,
            babet.joinPath(dest, ".SRCINFO")
        )
        if util.is_interrupted(snapshot_code) then return results_for(packages, "interrupted", "result.build_interrupted", snapshot_code) end
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
    local _, stale_code = build.clean_stale(bcfg, dest)
    if util.is_interrupted(stale_code) then return results_for(packages, "interrupted", "result.build_interrupted", stale_code) end

    local made, make_code = build.make(bcfg, dest, is_root, opts)
    if not made then
        if util.is_interrupted(make_code) then
            return results_for(packages, "interrupted", "result.build_interrupted", make_code)
        end
        return results_for(packages, "failed", "result.build_failed")
    end

    local ok, pkgs, inst_code = build.install(
        bcfg,
        dest,
        packages,
        group.explicit,
        opts
    )
    if not ok then
        if util.is_interrupted(inst_code) then
            return results_for(packages, "interrupted", "result.install_interrupted", inst_code)
        end
        return results_for(packages, "install_failed", "result.install_failed")
    end
    if vcs_snapshot then
        local remembered, remember_err = vcs.remember(
            bcfg,
            pkgbase,
            vcs_snapshot,
            packages
        )
        if not remembered then
            log.warn(i18n.t("common.named_error", {
                name = pkgbase,
                error = tostring(remember_err),
            }))
        end
    end

    local _, clean_code = build.clean(bcfg, dest, pkgs)
    if util.is_interrupted(clean_code) then return results_for(packages, "interrupted", "result.build_interrupted", clean_code) end

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
    local meta, err, code = fetch.one(config, name)
    if not meta then return nil, err, code end

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

-- Approval is tied to reviewed content, not the most recent pull.
function build.review(config, meta)
    return require("lib.review").run(config, meta)
end

-- Both build and cache cleanup use this environment.
function build.environment(config)
    local root = util.is_root()
    local path, err = build.resolve_builddir(config, root)
    if not path then return nil, err end
    local overrides = {builddir=path}
    if root then overrides.build_user=BUILD_USER end
    return babet.mergeTables(config, overrides)
end

-- ensure_repo_deps(config, name) -> (true, nil) | (false, raison)
-- Installe en root les dépendances dépôt manquantes de `name`
-- (pacman -S --asdeps --needed) AVANT la compilation. Nécessaire car makepkg
-- tourne en tant que l'utilisateur de build (sans droits pacman) et est appelé
-- sans -s ; les dépendances dépôt doivent donc déjà être présentes. --asdeps
-- les marque comme dépendances, --needed évite de réinstaller l'existant.
local function ensure_repo_deps(config, name, opts)
    local rdeps, err, resolve_code = deps.repo_deps_of(config, name)
    if not rdeps then
        return false, i18n.t("deps.repo_resolution_failed", {
            package = name,
            error = tostring(err),
        }), resolve_code
    end
    if #rdeps == 0 then
        return true, nil
    end
    local code = pacman.install_dependencies(config, rdeps, opts)
    if code ~= 0 then
        return false, i18n.t("deps.repo_install_failed", {
            package = name,
            dependencies = table.concat(rdeps, ", "),
        }), code
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
    local resolved, rerr, rcode = deps.resolve_many(config, targets, opts)
    if not resolved then return nil, rerr, rcode end
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

-- Skip ordinary up-to-date packages before installing build dependencies.
-- VCS packages need their source revision checked; --needed is still passed
-- to the final pacman -U transaction for those builds.
function build.is_current(config, group)
    if vcs.is_candidate(group.base) then return false end
    local infos, err = aur.info(config, group.packages)
    if not infos then return nil, err end
    for _, name in ipairs(group.packages) do
        if vcs.is_candidate(name) then return false end
        local q, qerr = util.run({"pacman", "-Q", name}, {env={LC_ALL="C"}})
        if q and q.code==1 then return false end
        if not util.complete(q) then return nil, qerr or (q and q.stderr) or "pacman -Q", q and q.code end
        local version=q.stdout:match("^%S+%s+(%S+)")
        if not version or not infos[name] then return false end
        local compared, cerr=util.vercmp(version, infos[name].Version)
        if compared==nil then return nil,cerr end
        if compared~=0 then return false end
    end
    return true
end

-- aur_many(config, targets, opts) -> liste de résultats typés.
-- Toute la transaction AUR est planifiée avant le premier effet de bord. Un
-- pkgbase est construit une seule fois, même si plusieurs cibles directes ou
-- dépendances désignent des sous-paquets issus du même PKGBUILD.
function build.aur_many(config, targets, opts)
    opts = opts or {}
    local results = {}
    local cleanup_state = builddeps.start(config)
    if cleanup_state.interrupted then
        return results_for(targets, "interrupted", "result.build_interrupted", cleanup_state.code)
    end
    local plan, rerr, plan_code = build.plan(config, targets, opts)
    if not plan then
        if util.is_interrupted(plan_code) then return results_for(targets, "interrupted", "result.build_interrupted", plan_code) end
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

        local current, current_err, current_code
        if opts.needed and not opts.force and not opts.reason then current,current_err,current_code=build.is_current(config,group) end
        if current then
            for _, package in ipairs(group.packages) do
                results[#results+1]=result("skipped",package,i18n.t("status.up_to_date"))
            end
            status[base]=true
        elseif current_err and util.is_interrupted(current_code) then
            for _, r in ipairs(results_for(group.packages, "interrupted", "result.build_interrupted", current_code)) do results[#results+1]=r end
            interrupted=true
            break
        elseif current_err then
            for _, package in ipairs(group.packages) do results[#results+1]=result("failed",package,current_err) end
            status[base]=false
        elseif failed_dependency then
            for _, package in ipairs(group.packages) do
                results[#results + 1] = result("failed", package,
                    i18n.t("deps.abandoned", {
                        package = package,
                        dependency = failed_dependency,
                    }))
            end
            status[base] = false
        else
            local dependency_error, dependency_code
            for _, package in ipairs(group.packages) do
                local ok, derr, dcode = ensure_repo_deps(config, package, opts)
                if not ok then
                    dependency_error, dependency_code = derr, dcode
                    break
                end
            end

            local group_results
            if dependency_error then
                group_results = {}
                for _, package in ipairs(group.packages) do
                    group_results[#group_results + 1] = result(util.is_interrupted(dependency_code) and "interrupted" or "failed", package,
                        i18n.t("common.named_error", {
                            name = package,
                            error = tostring(dependency_error),
                        }), dependency_code)
                end
            else
                local has_explicit = next(group.explicit) ~= nil
                group_results = build.one_group(
                    config,
                    group,
                    has_explicit and opts or {needed=opts.needed, noconfirm=opts.noconfirm}
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
