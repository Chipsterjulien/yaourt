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

local function rpc_base(config)
    return (config.aur_url or "https://aur.archlinux.org") .. "/rpc/v5"
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

    for _, name in ipairs(names) do
        local part = "arg%5B%5D=" .. util.urlencode(name)
        local added = #part + (#parts > 0 and 1 or 0)

        if #parts > 0 and length + added > MAX_QUERY_LENGTH then
            out[#out + 1] = table.concat(parts, "&")
            parts, length = {}, 0
            added = #part
        end

        parts[#parts + 1] = part
        length = length + added
    end

    if #parts > 0 then out[#out + 1] = table.concat(parts, "&") end
    return out
end

-- info(config, names) -> (map Name->entry, nil) | (nil, err)
-- GET /rpc/v5/info?arg[]=a&arg[]=b… avec découpage des URL trop longues.
function aur.info(config, names)
    local result = {}
    for _, query in ipairs(info_queries(names)) do
        local res, err = get_with_retry(rpc_base(config) .. "/info?" .. query, {
            headers = request_headers(),
            timeout = REQUEST_TIMEOUT,
        })
        if not res then return nil, "aur: " .. tostring(err) end
        if res.status ~= 200 then
            return nil, "aur: HTTP " .. tostring(res.status)
        end

        local data, derr = babet.json.decode(res.body)
        if not data then return nil, "aur: json: " .. tostring(derr) end
        if data.type == "error" then
            return nil, "aur: " .. tostring(data.error or i18n.t("aur.rpc_error"))
        end
        for _, entry in ipairs(data.results or {}) do
            result[entry.Name] = entry
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
    if data.type == "error" then
        return nil, "aur: " .. tostring(data.error or i18n.t("aur.rpc_error"))
    end
    return data.results or {}
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

return aur
