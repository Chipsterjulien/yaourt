-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- util.lua — fonctions utilitaires partagées.
--
-- IMPORTANT — tous les appels à `luapilot.exec` passent par util.run().
-- Centralisé ici : si l'API exec bouge, il n'y a QUE ce bloc à toucher.

local util = {}

local function shquote(s)
    return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

function util.cache_home()
    return luapilot.env("XDG_CACHE_HOME") or (util.home() .. "/.cache")
end

function util.config_home()
    return luapilot.env("XDG_CONFIG_HOME") or (util.home() .. "/.config")
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
    return luapilot.env("HOME") or "/root"
end

function util.is_root()
    local res, err = util.run({ "id", "-u" })
    if not res then return false end -- en cas d'échec, on suppose non-root (prudent)
    return tonumber(res.stdout) == 0
end

-- mkdir -p (luapilot n'expose pas de mkdir ; on délègue).
function util.mkdirp(path)
    local res, err = util.run({ "mkdir", "-p", path })
    if not res then return nil, err end
    if res.code ~= 0 then return nil, "mkdir: " .. res.stderr end
    return true
end

-- Passthrough interactif : rend la main au terminal (sudo, couleurs,
-- barres de progression de pacman fonctionnent). On utilise os.execute
-- car exec capture la sortie (« limites de sortie » dans le README),
-- ce qui casserait une session interactive.
-- Passthrough interactif : rend la main au terminal (sudo, couleurs, barres de
-- progression de pacman). On utilise os.execute (et non util.run qui capture la
-- sortie, ce qui casserait l'interactivité).
--
-- Convention de retour, alignée sur les shells POSIX :
--   0           : succès
--   1..127      : échec normal de la commande (code de sortie)
--   128 + N     : terminé par le signal N (130 = SIGINT/Ctrl+C)
-- os.execute (Lua 5.4/5.5) renvoie (true|nil, "exit"|"signal", code) ; on lit la
-- 2e valeur pour distinguer une mort par signal d'un simple code d'échec.
function util.passthrough(argv, cwd)
    local parts = {}
    if cwd ~= nil then
        parts = { "cd", shquote(cwd), "&&" }
    end

    local size_parts = #parts
    for i, a in ipairs(argv) do parts[size_parts + i] = shquote(a) end
    local ok, kind, code = os.execute(table.concat(parts, " "))
    if ok == true then return 0 end
    if kind == "signal" then return 128 + (code or 0) end
    return code or 1
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
-- API luapilot.exec (v1.6.0, confirmée) :
--
--   local res, err = luapilot.exec(commande, args, opts)
--     commande : string            ("git", "vercmp", …)
--     args     : table de strings  ({ "clone", url, dest })
--     opts     : table optionnelle  { cwd=, env=, stdin=, timeout= }
--   res = { code=<int>, stdout=<string>, stderr=<string>, timed_out=<bool> }
--   err : nil sauf échec de LANCEMENT (binaire introuvable, cwd invalide…).
--   Un code de retour non nul N'EST PAS une erreur (err reste nil).
--
-- Côté appelants on garde des tables « argv » { cmd, arg1, arg2, … } ;
-- util.run() les découpe en (cmd, args) pour exec. opts est transmis tel
-- quel (ex. { env = { LC_ALL = "C" } } pour parser une sortie pacman).
function util.run(argv, opts)
    local cmd = argv[1]
    if type(cmd) ~= "string" then
        return nil, "util.run: commande manquante"
    end
    local args = {}
    for i = 2, #argv do args[#args + 1] = argv[i] end
    return luapilot.exec(cmd, args, opts)
end

function util.run_as(user, argv, opts)
    local cmd
    if not user then
        cmd = argv
    else
        cmd = luapilot.mergeTables({ "runuser", "-u", user, "--" }, argv)
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
    if not n then return nil, "vercmp: sortie inattendue: " .. res.stdout end
    if n < 0 then return -1 elseif n > 0 then return 1 else return 0 end
end

-- isset(v) : vrai si une valeur JSON décodée est réellement présente.
-- Un champ absent vaut nil ; un null JSON est décodé en luapilot.json.null.
function util.isset(v)
    return v ~= nil and v ~= luapilot.json.null
end

return util
