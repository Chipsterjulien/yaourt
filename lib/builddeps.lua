-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- builddeps.lua — nettoyage prudent des dépendances de build orphelines.
--
-- Le nettoyage ne doit jamais viser les orphelins historiques de la machine.
-- On photographie donc les paquets installés avant le premier effet de bord,
-- puis on ne retient à la fin que les orphelins absents de cette photographie.
-- Le plan récursif de pacman est d'abord calculé sans effet de bord. Yaourt en
-- retire tout paquet déjà présent avant l'opération, puis transmet la liste
-- restante à une suppression non récursive. Ainsi, même une ancienne
-- dépendance devenue orpheline ne peut pas être entraînée par `-Rns`.

local color  = require("lib.color")
local i18n   = require("lib.i18n")
local log    = require("lib.log")
local pacman = require("lib.pacman")
local util   = require("lib.util")

local builddeps = {}

local function trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$"))
end

local function detail(res, err)
    if err then return tostring(err) end
    local value = trim(res and res.stderr)
    if value == "" then value = trim(res and res.stdout) end
    if value == "" then value = i18n.t("common.unknown") end
    return value
end

local function package_set(output)
    local result = {}
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local name = trim(line)
        if name ~= "" then result[name] = true end
    end
    return result
end

-- Valeurs de configuration acceptées :
--   false / nil / "never" : aucun contrôle (défaut) ;
--   "ask"                 : afficher puis demander, choix par défaut = non ;
--   true / "always"       : supprimer automatiquement les nouveaux orphelins.
function builddeps.mode(value)
    if value == true or value == "always" then return "always" end
    if value == "ask" then return "ask" end
    return "never"
end

-- start(config) -> état opaque transmis à finish().
-- La liste complète des paquets installés est plus sûre qu'une photographie
-- des seuls orphelins : elle permet aussi d'ignorer un paquet ancien qui ne
-- deviendrait orphelin qu'au cours de l'opération courante.
function builddeps.start(config)
    local mode = builddeps.mode(config and config.cleanup_build_deps)
    if mode == "never" then return { mode = mode } end

    local res, err = util.run(
        { "pacman", "-Qq" },
        { env = { LC_ALL = "C" } }
    )
    if not res or res.code ~= 0 then
        log.warn(i18n.t("common.named_error", {
            name = "pacman -Qq",
            error = detail(res, err),
        }))
        return { mode = "never", unavailable = true }
    end

    return {
        mode = mode,
        before = package_set(res.stdout),
    }
end

local function is_noninteractive(opts)
    if opts and opts.noconfirm then return true end
    for _, flag in ipairs(opts and opts.passthrough or {}) do
        if flag == "--noconfirm" then return true end
    end
    return false
end

-- Demande à pacman de calculer la fermeture récursive de suppression, sans
-- l'exécuter. Le résultat est ensuite borné aux seuls paquets absents de la
-- photographie initiale. La transaction réelle utilise -Rn avec cette liste
-- complète : pacman conserve son contrôle de cohérence, mais ne peut plus
-- ajouter silencieusement un paquet historique à la transaction.
local function removal_plan(state, roots)
    -- --print est incompatible avec --nosave (-n) dans pacman. Cette option
    -- ne modifie pas les paquets sélectionnés ; elle ne sert que pendant la
    -- transaction réelle pour éviter la création de fichiers .pacsave.
    local argv = { "pacman", "-Rs", "--print-format", "%n" }
    argv = babet.mergeTables(argv, roots)
    local res, err = util.run(argv, { env = { LC_ALL = "C" } })
    if not res or res.code ~= 0 then
        log.warn(i18n.t("common.named_error", {
            name = "pacman -Rs --print",
            error = detail(res, err),
        }))
        return nil, res and res.code or 1
    end

    local packages = {}
    for name in pairs(package_set(res.stdout)) do
        if not (state.before and state.before[name]) then
            packages[#packages + 1] = name
        end
    end
    table.sort(packages)
    if #packages == 0 then
        log.warn(i18n.t("common.named_error", {
            name = "pacman -Rs --print",
            error = i18n.t("process.unexpected_output", {
                command = "pacman -Rs --print",
                output = trim(res.stdout),
            }),
        }))
        return nil, 1
    end
    return packages, 0
end

-- finish(config, state, opts) -> { status, packages, code? }
-- Un Ctrl+C ne doit jamais déclencher une nouvelle transaction pacman après
-- l'interruption demandée par l'utilisateur : le nettoyage est alors différé.
function builddeps.finish(config, state, opts)
    state = state or { mode = "never" }
    if state.mode == "never" then
        return { status = "disabled", packages = {} }
    end
    if opts and opts.interrupted then
        return { status = "interrupted", packages = {} }
    end

    local res, err = util.run(
        { "pacman", "-Qdtq" },
        { env = { LC_ALL = "C" } }
    )
    -- pacman renvoie 1, sans sortie, lorsqu'aucun orphelin n'existe.
    if not res or (res.code ~= 0 and not (res.code == 1 and trim(res.stdout) == "")) then
        log.warn(i18n.t("common.named_error", {
            name = "pacman -Qdtq",
            error = detail(res, err),
        }))
        return { status = "failed", packages = {}, code = res and res.code or 1 }
    end

    local roots = {}
    for name in pairs(package_set(res.stdout)) do
        if not (state.before and state.before[name]) then
            roots[#roots + 1] = name
        end
    end
    table.sort(roots)
    if #roots == 0 then
        return { status = "none", packages = roots }
    end

    local packages, plan_code = removal_plan(state, roots)
    if not packages then
        return { status = "failed", packages = roots, code = plan_code }
    end

    local C = color.new(config and config.color)
    print("")
    print(C.cyan("==> ") .. C.bold(i18n.n(
        "build_deps.heading", #packages, { count = #packages }
    )))
    print("    " .. table.concat(packages, ", "))

    if state.mode == "ask" then
        if is_noninteractive(opts) then
            log.warn(i18n.t("build_deps.kept_noninteractive"))
            return { status = "kept", packages = packages }
        end

        io.write(C.cyan("==> " .. i18n.prompt(
            "build_deps.remove_confirm", false, "no"
        )) .. " ")
        io.flush()
        local answer = (io.read("l") or ""):lower()
        if not i18n.is_answer(answer, "yes") then
            print(i18n.t("build_deps.kept"))
            return { status = "kept", packages = packages }
        end
    end

    local argv = { "-Rn", "--noconfirm" }
    argv = babet.mergeTables(argv, packages)
    local code = pacman.passthrough(config, argv)
    if code ~= 0 then
        log.warn(i18n.t("common.named_error", {
            name = "pacman -Rns",
            error = tostring(code),
        }))
        return { status = "failed", packages = packages, code = code }
    end

    print(i18n.n("build_deps.removed", #packages, { count = #packages }))
    return { status = "removed", packages = packages, code = 0 }
end

return builddeps
