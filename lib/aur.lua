-- aur.lua — client de l'API RPC v5 de l'AUR (http + json).
--
-- C'est notre « mode parallèle » sans package-query : pur HTTP, donc
-- insensible aux mises à jour de libalpm. On l'utilise ici pour résoudre
-- le PackageBase avant le clone, et plus tard pour l'affichage des MAJ.

local util = require("lib.util")

local aur = {}

local function rpc_base(config)
    return (config.aur_url or "https://aur.archlinux.org") .. "/rpc/v5"
end

-- Découpe une liste en tranches de n éléments.
local function chunks(list, n)
    local out, cur = {}, {}
    for _, v in ipairs(list) do
        cur[#cur + 1] = v
        if #cur >= n then
            out[#out + 1] = cur; cur = {}
        end
    end
    if #cur > 0 then out[#out + 1] = cur end
    return out
end

-- info(config, names) -> (map Name->entry, nil) | (nil, err)
-- POST /rpc/v5/info  body: arg[]=a&arg[]=b…  (POST pour gérer beaucoup d'args)
function aur.info(config, names)
    local result = {}
    for _, batch in ipairs(chunks(names, 150)) do
        local parts = {}
        for _, n in ipairs(batch) do
            parts[#parts + 1] = "arg[]=" .. util.urlencode(n)
        end
        local body = table.concat(parts, "&")

        local res, err = luapilot.http.post(rpc_base(config) .. "/info", body, {
            headers = { ["Content-Type"] = "application/x-www-form-urlencoded" },
            timeout = 15,
        })
        if not res then return nil, "aur: " .. tostring(err) end
        if res.status ~= 200 then
            return nil, "aur: HTTP " .. tostring(res.status)
        end

        local data, derr = luapilot.json.decode(res.body)
        if not data then return nil, "aur: json: " .. tostring(derr) end
        if data.type == "error" then
            return nil, "aur: " .. tostring(data.error or "erreur RPC")
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
    local res, err = luapilot.http.get(url, {
        query   = { by = by },
        timeout = 15,
    })
    if not res then return nil, "aur: " .. tostring(err) end
    if res.status ~= 200 then return nil, "aur: HTTP " .. tostring(res.status) end

    local data, derr = luapilot.json.decode(res.body)
    if not data then return nil, "aur: json: " .. tostring(derr) end
    if data.type == "error" then
        return nil, "aur: " .. tostring(data.error or "erreur RPC")
    end
    return data.results or {}
end

return aur
