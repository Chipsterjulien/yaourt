-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- util.lua — fonctions utilitaires partagées.
--
-- IMPORTANT — tous les appels à `babet.exec` passent par util.run().
-- Centralisé ici : si l'API exec bouge, il n'y a QUE ce bloc à toucher.

local i18n = require("lib.i18n")

local util = {}

function util.cache_home()
    return babet.env("XDG_CACHE_HOME") or (util.home() .. "/.cache")
end

function util.config_home()
    return babet.env("XDG_CONFIG_HOME") or (util.home() .. "/.config")
end

-- Remplace un ~ initial par $HOME.
function util.expanduser(path)
    if type(path) ~= "string" then return path end
    if path == "~" then return util.home() end
    local rest = path:match("^~/(.*)$")
    if rest then return util.home() .. "/" .. rest end
    return path
end

--------------------------------------------------------------------------
-- Chemins
--------------------------------------------------------------------------
function util.home()
    return babet.env("HOME") or "/root"
end

function util.is_root()
    local res, err = util.run({ "id", "-u" })
    if not res then return false end -- en cas d'échec, on suppose non-root (prudent)
    return tonumber(res.stdout) == 0
end

-- mkdir -p natif : babet.mkdir est récursif et idempotent.
function util.mkdirp(path)
    return babet.mkdir(path)
end

-- Passthrough interactif : rend la main au terminal (sudo, couleurs, barres de
-- progression de pacman) grâce aux redirections "inherit" de Babet 2.22.2 et
-- à son transfert/restauration du terminal pour les enfants interactifs.
-- La commande et ses arguments restent séparés : aucun shell implicite, aucun
-- quoting à reconstruire et aucune interprétation de caractères spéciaux.
--
-- Convention de retour, alignée sur les shells POSIX :
--   0           : succès
--   1..127      : échec normal de la commande (code de sortie)
--   128 + N     : terminé par le signal N (130 = SIGINT/Ctrl+C)
-- Un second résultat textuel décrit un éventuel échec de lancement/attente.
function util.passthrough(argv, cwd)
    local cmd = argv[1]
    if type(cmd) ~= "string" then
        return 1, i18n.t("process.command_missing", { function_name = "util.passthrough" })
    end

    local args = {}
    for i = 2, #argv do args[#args + 1] = argv[i] end

    local process, err = babet.spawn(cmd, args, {
        cwd = cwd,
        stdin = "inherit",
        stdout = "inherit",
        stderr = "inherit",
    })
    if not process then return 1, err end

    local result, wait_err = process:wait()
    if not result then
        process:close()
        return 1, wait_err
    end

    process:close()
    return result.code
end

-- is_interrupted(code) : vrai si le code de retour correspond à une interruption
-- par l'utilisateur (Ctrl+C / SIGINT = 130). Centralisé ici pour que tous les
-- appelants distinguent une interruption d'un échec applicatif.
function util.is_interrupted(code)
    return code == 130
end

--------------------------------------------------------------------------
-- Exécution de processus
--------------------------------------------------------------------------
--
-- API babet.exec (Babet 2.22.2) :
--
--   local res, err = babet.exec(commande, args, opts)
--     commande : string            ("git", "vercmp", …)
--     args     : table de strings  ({ "clone", url, dest })
--     opts     : table optionnelle
--                { cwd=, env=, stdin=, timeout=, max_output= }
--   res = {
--     code=<int>, stdout=<string>, stderr=<string>, timed_out=<bool>,
--     stdout_truncated=<bool>, stderr_truncated=<bool>
--   }
--   err : nil sauf échec de LANCEMENT (binaire introuvable, cwd invalide…).
--   Un code de retour non nul N'EST PAS une erreur (err reste nil).
--
-- Côté appelants on garde des tables « argv » { cmd, arg1, arg2, … } ;
-- util.run() les découpe en (cmd, args) pour exec. opts est transmis tel
-- quel (ex. { env = { LC_ALL = "C" } } pour parser une sortie pacman).
function util.run(argv, opts)
    local cmd = argv[1]
    if type(cmd) ~= "string" then
        return nil, i18n.t("process.command_missing", { function_name = "util.run" })
    end
    local args = {}
    for i = 2, #argv do args[#args + 1] = argv[i] end
    return babet.exec(cmd, args, opts)
end

function util.run_as(user, argv, opts)
    local cmd
    if not user then
        cmd = argv
    else
        cmd = babet.mergeTables({ "runuser", "-u", user, "--" }, argv)
    end

    return util.run(cmd, opts)
end

function util.sudo_prefix(config)
    if util.is_root() then
        return nil
    end

    return config.sudo or "sudo"
end

--------------------------------------------------------------------------
-- Encodage URL (percent-encoding) pour les requêtes AUR.
--------------------------------------------------------------------------
function util.urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

--------------------------------------------------------------------------
-- Comparaison de versions : toujours déléguée à `vercmp` (algorithme
-- officiel d'Arch). Ne JAMAIS comparer les versions à la main.
--------------------------------------------------------------------------
-- Renvoie -1 si a<b, 0 si a==b, 1 si a>b ; (nil, err) si vercmp absent.
function util.vercmp(a, b)
    local res, err = util.run({ "vercmp", a, b })
    if not res then return nil, err end
    local n = tonumber((res.stdout:gsub("%s+$", "")))
    if not n then
        return nil, i18n.t("process.unexpected_output", {
            command = "vercmp",
            output = res.stdout,
        })
    end
    if n < 0 then return -1 elseif n > 0 then return 1 else return 0 end
end

-- isset(v) : vrai si une valeur JSON décodée est réellement présente.
-- Un champ absent vaut nil ; un null JSON est décodé en babet.json.null.
function util.isset(v)
    return v ~= nil and v ~= babet.json.null
end

return util
