-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- vcs.lua — suivi sûr des paquets de développement AUR.
--
-- La détection ne lance jamais makepkg et n'exécute jamais le PKGBUILD. Elle
-- lit uniquement le .SRCINFO déclaratif publié par l'AUR, puis interroge les
-- références distantes avec les clients VCS. La révision observée n'est
-- enregistrée qu'après une installation réussie.

local aur  = require("lib.aur")
local util = require("lib.util")

local vcs = {}

local STATE_HEADER = "YAOURT-VCS-1"
local QUERY_TIMEOUT = 20
local SUFFIXES = { "git", "hg", "svn", "bzr" }

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function state_path(config)
    return config.vcs_state_file
        or babet.joinPath(util.cache_home(), "yaourt", "vcs-state-v1")
end

local function decode(value)
    return (tostring(value or ""):gsub("%%(%x%x)", function(hex)
        return string.char(tonumber(hex, 16))
    end))
end

local function parent(path)
    return path:match("^(.*)/[^/]+$") or "."
end

function vcs.is_candidate(name)
    name = tostring(name or "")
    for _, suffix in ipairs(SUFFIXES) do
        if name:match("%-" .. suffix .. "$") then return true end
    end
    return false
end

local function architecture(config)
    if config.vcs_arch then return config.vcs_arch end
    local res = util.run({ "uname", "-m" }, { env = { LC_ALL = "C" } })
    local arch = res and res.code == 0 and trim(res.stdout) or ""
    if arch == "armv6l" then return "armv6h" end
    if arch == "armv7l" then return "armv7h" end
    return arch
end

local function fragment_map(fragment)
    local result = {}
    for item in tostring(fragment or ""):gmatch("[^&]+") do
        local key, value = item:match("^([^=]+)=(.*)$")
        if key then result[key] = value end
    end
    return result
end

local function parse_source(value)
    value = trim(value)
    value = value:match("^[^:]+::(.+)$") or value
    local kind, rest = value:match("^([%a]+)%+(.+)$")
    if kind ~= "git" and kind ~= "hg" and kind ~= "svn" and kind ~= "bzr" then
        return nil
    end

    local url, fragment = rest:match("^([^#]+)#?(.*)$")
    local params = fragment_map(fragment)
    local ref = "HEAD"

    if kind == "git" then
        if params.commit or params.tag then return nil end
        if params.branch and params.branch ~= "" then
            ref = "refs/heads/" .. params.branch
        end
    elseif kind == "hg" then
        if params.revision or params.tag then return nil end
        ref = params.branch or "tip"
    elseif kind == "svn" then
        if params.revision then return nil end
    elseif kind == "bzr" then
        if params.revision then return nil end
    end

    return { kind = kind, url = url, ref = ref }
end

-- Extrait uniquement les sources globales et celles de l'architecture active.
-- Les valeurs fixes (#commit, #tag, #revision) ne sont volontairement pas
-- suivies : elles ne représentent pas une branche de développement mouvante.
function vcs.sources(srcinfo, arch)
    local result, seen = {}, {}
    for line in tostring(srcinfo or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "source" or (arch ~= "" and key == "source_" .. arch) then
            local source = parse_source(value)
            if source then
                local identity = table.concat({
                    source.kind, source.url, source.ref,
                }, "\t")
                if not seen[identity] then
                    seen[identity] = true
                    source.identity = identity
                    result[#result + 1] = source
                end
            end
        end
    end
    table.sort(result, function(a, b) return a.identity < b.identity end)
    return result
end

local function safe_url(source)
    local url = tostring(source.url or "")
    if url:find("[%z\1-\32\127]") then return false end
    if source.allow_local and url:match("^/") then return true end
    if url:match("^https?://") then return true end
    if source.kind == "git" and url:match("^git://") then return true end
    if source.kind == "svn" and url:match("^svn://") then return true end
    if source.kind == "bzr" and url:match("^bzr://") then return true end
    return false
end

local function command_for(source)
    if not safe_url(source) then
        return nil, "unsafe or unsupported VCS URL: " .. tostring(source.url)
    end
    if source.kind == "git" then
        return {
            "git",
            "-c", "protocol.ext.allow=never",
            "-c", "protocol.file.allow=" .. (source.allow_local and "always" or "never"),
            "ls-remote", "--exit-code", "--", source.url, source.ref,
        }
    elseif source.kind == "hg" then
        return {
            "hg", "identify", "--debug", "-r", source.ref, "--", source.url,
        }
    elseif source.kind == "svn" then
        return {
            "svn", "info", "--show-item", "revision", "--", source.url,
        }
    elseif source.kind == "bzr" then
        return { "bzr", "revno", "--", source.url }
    end
end

function vcs.query(source)
    local argv, command_err = command_for(source)
    if not argv then return nil, command_err or "unsupported VCS" end
    local res, err = util.run(argv, {
        env = {
            LC_ALL = "C",
            GIT_TERMINAL_PROMPT = "0",
        },
        timeout = QUERY_TIMEOUT,
    })
    if not res then return nil, tostring(err) end
    if res.code ~= 0 then
        local detail = trim(res.stderr)
        if detail == "" then detail = "exit " .. tostring(res.code) end
        return nil, argv[1] .. ": " .. detail
    end

    local output = trim(res.stdout)
    local revision
    if source.kind == "git" then
        revision = output:match("^(%x+)%s")
    elseif source.kind == "hg" then
        revision = output:match("^(%x+)")
    else
        revision = output:match("^(%d+)")
    end
    if not revision then
        return nil, argv[1] .. ": unexpected output: " .. output
    end
    return revision, nil
end

function vcs.snapshot_from_srcinfo(config, srcinfo)
    local sources = vcs.sources(srcinfo, architecture(config))
    if #sources == 0 then return nil, nil end

    local rows = {}
    for _, source in ipairs(sources) do
        local revision, err = vcs.query(source)
        if not revision then return nil, err end
        rows[#rows + 1] = source.identity .. "\t" .. revision
    end
    return table.concat(rows, "\n"), nil
end

function vcs.snapshot(config, pkgbase)
    local content, err = aur.srcinfo(config, pkgbase)
    if not content then return nil, err end
    return vcs.snapshot_from_srcinfo(config, content)
end

function vcs.snapshot_file(config, path)
    local file, err = io.open(path, "rb")
    if not file then return nil, tostring(err) end
    local content = file:read("a") or ""
    file:close()
    return vcs.snapshot_from_srcinfo(config, content)
end

function vcs.load(config)
    local path = state_path(config)
    local file = io.open(path, "rb")
    if not file then return {}, nil end
    local content = file:read("a") or ""
    file:close()

    local first, rest = content:match("^([^\n]*)\n?(.*)$")
    if first ~= STATE_HEADER then
        return nil, "invalid VCS state header: " .. path
    end

    local state = {}
    for line in rest:gmatch("[^\r\n]+") do
        local name, snapshot = line:match("^([^\t]+)\t(.*)$")
        if not name then return nil, "invalid VCS state entry: " .. path end
        state[decode(name)] = decode(snapshot)
    end
    return state, nil
end

local function save(config, state)
    local path = state_path(config)
    local ok, err = util.mkdirp(parent(path))
    if not ok then return nil, tostring(err) end

    local names = {}
    for name in pairs(state) do names[#names + 1] = name end
    table.sort(names)

    local temporary = path .. ".tmp." .. tostring(babet.pid())
    local file, ferr = io.open(temporary, "wb")
    if not file then return nil, tostring(ferr) end
    local lines = { STATE_HEADER }
    for _, name in ipairs(names) do
        lines[#lines + 1] = util.urlencode(name)
            .. "\t" .. util.urlencode(state[name])
    end
    local written, werr = file:write(table.concat(lines, "\n"), "\n")
    if not written then
        file:close()
        babet.remove(temporary)
        return nil, tostring(werr)
    end
    local closed, cerr = file:close()
    if not closed then
        babet.remove(temporary)
        return nil, tostring(cerr)
    end

    local renamed, rerr = os.rename(temporary, path)
    if not renamed then
        babet.remove(temporary)
        return nil, tostring(rerr)
    end
    return true, nil
end

function vcs.remember(config, pkgbase, snapshot)
    if not snapshot then return true, nil end
    local state, err = vcs.load(config)
    if not state then return nil, err end
    state[pkgbase] = snapshot
    return save(config, state)
end

-- Marque les entrées installées dont la branche VCS distante a changé. Une
-- base encore inconnue est proposée une première fois : l'ignorer en silence
-- risquerait de conserver indéfiniment un paquet déjà obsolète.
function vcs.mark_updates(config, entries)
    local state, state_err = vcs.load(config)
    if not state then return { state_err } end

    local groups = {}
    for _, entry in ipairs(entries) do
        local base = entry.pkgbase or entry.name
        if entry.in_aur and (
            vcs.is_candidate(entry.name) or vcs.is_candidate(base)
        ) then
            groups[base] = groups[base] or {}
            groups[base][#groups[base] + 1] = entry
        end
    end

    local errors, bases = {}, {}
    for base in pairs(groups) do bases[#bases + 1] = base end
    table.sort(bases)
    for _, base in ipairs(bases) do
        local snapshot, err = vcs.snapshot(config, base)
        if err then
            errors[#errors + 1] = base .. ": " .. tostring(err)
        elseif snapshot and state[base] ~= snapshot then
            for _, entry in ipairs(groups[base]) do
                entry.vcs_update = true
                if not entry.has_update then entry.vcs_only = true end
                entry.has_update = true
            end
        end
    end
    return errors
end

vcs._state_path = state_path
vcs._parse_source = parse_source
vcs._save = save
vcs._safe_url = safe_url

return vcs
