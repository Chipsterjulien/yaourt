-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- aur.lua — client de l'API RPC v5 de l'AUR (http + json).
--
-- C'est notre « mode parallèle » sans package-query : pur HTTP, donc
-- insensible aux mises à jour de libalpm. On l'utilise ici pour résoudre
-- le PackageBase avant le clone, et plus tard pour l'affichage des MAJ.

local util    = require("lib.util")
local version = require("lib.version")
local i18n    = require("lib.i18n")

local aur = {}

local REQUEST_ATTEMPTS = 3
local REQUEST_TIMEOUT  = 15
local RETRY_DELAY_MS   = 250
local MAX_QUERY_LENGTH = 6000

-- Cache volontairement limité à la durée du processus. Il évite de demander
-- plusieurs fois la même fiche /info pendant la résolution d'un gros graphe,
-- sans créer d'état persistant à invalider entre deux exécutions de yaourt.
-- Une absence confirmée par une réponse RPC réussie est mémorisée avec false ;
-- les erreurs réseau et HTTP ne le sont jamais.
local info_cache = {}

local function rpc_base(config)
    return (config.aur_url or "https://aur.archlinux.org") .. "/rpc/v5"
end

local function aur_base(config)
    return config.aur_url or "https://aur.archlinux.org"
end

local function request_headers()
    return {
        ["Accept"]     = "application/json",
        ["User-Agent"] = version.name .. "/" .. version.version,
    }
end

-- Les erreurs de transport sont parfois transitoires (connexion fermée par le
-- serveur, reset TLS, etc.). On retente aussi les réponses 429 et 5xx, mais
-- jamais une autre erreur HTTP déterministe.
local function get_with_retry(url, opts)
    local last_err

    for attempt = 1, REQUEST_ATTEMPTS do
        local res, err = babet.http.get(url, opts)
        if res and res.status ~= 429 and res.status < 500 then
            return res
        end

        if res then
            last_err = "HTTP " .. tostring(res.status)
        else
            last_err = tostring(err)
        end

        if attempt < REQUEST_ATTEMPTS then
            babet.sleep(RETRY_DELAY_MS, "ms")
        end
    end

    return nil, last_err
end

-- Construit des query strings bornées pour GET /info. L'API AUR accepte les
-- paramètres répétés arg[]. Le GET évite le chemin POST qui peut échouer avec
-- certains couples serveur/client HTTP, tandis que la borne évite les URL
-- démesurées lorsque beaucoup de paquets étrangers sont installés.
local function info_queries(names)
    local out, parts, length = {}, {}, 0
    local batch_names = {}

    for _, name in ipairs(names) do
        local part = "arg%5B%5D=" .. util.urlencode(name)
        local added = #part + (#parts > 0 and 1 or 0)

        if #parts > 0 and length + added > MAX_QUERY_LENGTH then
            out[#out + 1] = {
                query = table.concat(parts, "&"),
                names = batch_names,
            }
            parts, batch_names, length = {}, {}, 0
            added = #part
        end

        parts[#parts + 1] = part
        batch_names[#batch_names + 1] = name
        length = length + added
    end

    if #parts > 0 then
        out[#out + 1] = {
            query = table.concat(parts, "&"),
            names = batch_names,
        }
    end
    return out
end

local function info_cache_for(config)
    local key = rpc_base(config)
    if not info_cache[key] then info_cache[key] = {} end
    return info_cache[key]
end

-- Utilisé par les tests et utile à tout futur mode long-vivant. L'exécutable
-- actuel ne traite qu'une opération puis quitte, donc aucun nettoyage manuel
-- n'est nécessaire en usage normal.
function aur.clear_cache()
    info_cache = {}
end

-- A syntactically valid JSON value is not necessarily an AUR RPC response.
local function rpc_results(data, kind)
    if type(data) ~= "table" then return nil, "aur: invalid RPC envelope" end
    if data.type == "error" then return nil, "aur: " .. tostring(data.error or i18n.t("aur.rpc_error")) end
    if data.version ~= 5 or data.type ~= kind or type(data.results) ~= "table"
            or type(data.resultcount) ~= "number" or data.resultcount ~= #data.results
            or (#data.results == 0 and babet.json.encode(data.results) ~= "[]") then
        return nil, "aur: invalid RPC envelope"
    end
    local count, seen = 0, {}
    for index, entry in pairs(data.results) do
        count=count+1
        if type(index) ~= "number" or index%1~=0 or index<1 or index>#data.results
                or type(entry) ~= "table" or type(entry.Name) ~= "string"
                or not entry.Name:match("^[%w@_+][%w@._+%-]*$")
                or seen[entry.Name] or type(entry.Version) ~= "string" or entry.Version==""
                or type(entry.PackageBase) ~= "string"
                or not entry.PackageBase:match("^[%w@_+][%w@._+%-]*$") then
            return nil, "aur: invalid RPC package"
        end
        seen[entry.Name]=true
        for _, field in ipairs({"Depends","MakeDepends","CheckDepends","Provides","Conflicts","Replaces"}) do
            local items=entry[field]
            if items~=nil and items~=babet.json.null then
                if type(items)~="table" then return nil,"aur: invalid "..field end
                local length=0
                for k,v in pairs(items) do
                    if type(k)~="number" or k%1~=0 or k<1 or k>#items or type(v)~="string" then return nil,"aur: invalid "..field end
                    length=length+1
                end
                if length~=#items then return nil,"aur: invalid "..field end
            end
        end
    end
    if count~=data.resultcount then return nil,"aur: invalid RPC result count" end
    return data.results
end

-- info(config, names) -> (map Name->entry, nil) | (nil, err)
-- GET /rpc/v5/info?arg[]=a&arg[]=b… avec découpage des URL trop longues.
function aur.info(config, names)
    local cache = info_cache_for(config)
    local result, pending, seen = {}, {}, {}

    for _, name in ipairs(names or {}) do
        if not seen[name] then
            seen[name] = true
            local cached = cache[name]
            if cached == nil then
                pending[#pending + 1] = name
            elseif cached ~= false then
                result[name] = cached
            end
        end
    end

    for _, batch in ipairs(info_queries(pending)) do
        local res, err = get_with_retry(
            rpc_base(config) .. "/info?" .. batch.query,
            {
                headers = request_headers(),
                timeout = REQUEST_TIMEOUT,
            }
        )
        if not res then return nil, "aur: " .. tostring(err) end
        if res.status ~= 200 then
            return nil, "aur: HTTP " .. tostring(res.status)
        end

        local data, derr = babet.json.decode(res.body)
        if not data then return nil, "aur: json: " .. tostring(derr) end
        local entries, validation_err = rpc_results(data, "multiinfo")
        if not entries then return nil, validation_err end
        local requested = {}
        for _, name in ipairs(batch.names) do requested[name]=true end
        for _, entry in ipairs(entries) do
            if not requested[entry.Name] then return nil, "aur: unsolicited RPC package" end
        end
        local returned = {}
        for _, entry in ipairs(entries) do
            cache[entry.Name]=entry
            returned[entry.Name]=true
        end
        for _, name in ipairs(batch.names) do
            if not returned[name] then cache[name] = false end
            if cache[name] ~= false then result[name] = cache[name] end
        end
    end
    return result
end

-- search(config, term, by) -> (results[], nil) | (nil, err)
-- by ∈ name | name-desc (défaut) | maintainer | depends | …
function aur.search(config, term, by)
    by = by or "name-desc"
    local url = rpc_base(config) .. "/search/" .. util.urlencode(term)
    local res, err = get_with_retry(url, {
        headers = request_headers(),
        query   = { by = by },
        timeout = REQUEST_TIMEOUT,
    })
    if not res then return nil, "aur: " .. tostring(err) end
    if res.status ~= 200 then return nil, "aur: HTTP " .. tostring(res.status) end

    local data, derr = babet.json.decode(res.body)
    if not data then return nil, "aur: json: " .. tostring(derr) end
    return rpc_results(data, "search")
end

-- providers(config, capability) -> (entries[], nil) | (nil, err)
--
-- La recherche RPC `by=provides` ne garantit pas que ses résultats contiennent
-- tous les champs de /info (notamment Provides). On l'utilise donc uniquement
-- pour découvrir des noms, puis on recharge les fiches complètes en une requête
-- groupée. Le tri rend le choix interactif reproductible.
function aur.providers(config, capability)
    local results, err = aur.search(config, capability, "provides")
    if not results then return nil, err end

    local seen, names = {}, {}
    for _, entry in ipairs(results) do
        local name = entry and entry.Name
        if type(name) == "string" and name ~= "" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    table.sort(names)
    if #names == 0 then return {}, nil end

    local infos, ierr = aur.info(config, names)
    if not infos then return nil, ierr end

    local providers = {}
    for _, name in ipairs(names) do
        if infos[name] then providers[#providers + 1] = infos[name] end
    end
    return providers, nil
end

-- srcinfo(config, pkgbase) -> (texte, nil) | (nil, err)
--
-- Le fichier .SRCINFO est une représentation déclarative générée par
-- makepkg. Le lire depuis cgit permet d'identifier les sources VCS sans
-- cloner le paquet et surtout sans exécuter son PKGBUILD avant la revue.
function aur.srcinfo(config, pkgbase)
    local res, err = get_with_retry(
        aur_base(config) .. "/cgit/aur.git/plain/.SRCINFO",
        {
            headers = request_headers(),
            query = { h = pkgbase },
            timeout = REQUEST_TIMEOUT,
        }
    )
    if not res then return nil, "aur: " .. tostring(err) end
    if res.status ~= 200 then
        return nil, "aur: HTTP " .. tostring(res.status)
    end
    return res.body or "", nil
end

return aur
