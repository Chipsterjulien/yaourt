-- deps.lua — résolution des dépendances AUR.
--
-- Un paquet AUR peut dépendre d'autres paquets AUR (et non seulement de
-- paquets des dépôts). makepkg -s ne sait installer QUE les dépendances des
-- dépôts ; les dépendances AUR doivent donc être construites au préalable.
-- Ce module identifie, pour un paquet donné, ses dépendances AUR à construire.
--
-- ROADMAP :
--   * aur_deps_of  : dépendances AUR DIRECTES d'un paquet.            <-- ICI
--   * resolve      : exploration récursive + ordre de build topologique.
--   * provides / contraintes de version : non gérés pour l'instant.

local util = require("lib.util")
local aur  = require("lib.aur")

local deps = {}

-- strip_version(dep) -> nom nu, sans contrainte de version.
-- « libalpm.so>=14 » -> « libalpm.so », « foo=1.0 » -> « foo », « git » -> « git ».
-- On coupe au premier caractère de contrainte (<, >, =).
local function strip_version(dep)
    return dep:match("^[^<>=]+") or dep
end

-- in_repos(name) -> bool : présent dans un dépôt officiel (pacman -Si, code 0).
-- (Dupliqué de install.lua ; à factoriser dans un module partagé plus tard.)
local function in_repos(name)
    local res = util.run({ "pacman", "-Si", name })
    return res ~= nil and res.code == 0
end

-- is_installed(name) -> bool : déjà installé (pacman -Q, code 0).
local function is_installed(name)
    local res = util.run({ "pacman", "-Q", name })
    return res ~= nil and res.code == 0
end

-- aur_deps_of(config, name) -> (liste, nil) | (nil, err)
-- Dépendances AUR DIRECTES de `name` : on lit Depends + MakeDepends via le RPC,
-- on nettoie les noms, on écarte ce qui est déjà installé ou dans les dépôts,
-- puis un seul aur.info groupé confirme lesquelles existent réellement en AUR.
function deps.aur_deps_of(config, name)
    local info, err = aur.info(config, { name })
    if not info then return nil, err end

    local entry = info[name]
    if not entry then
        -- Paquet introuvable en AUR : aucune dépendance AUR à remonter.
        return {}, nil
    end

    -- Rassembler Depends + MakeDepends (chacun peut être absent).
    local raw = {}
    for _, field in ipairs({ "Depends", "MakeDepends" }) do
        local arr = entry[field]
        if type(arr) == "table" then
            for _, d in ipairs(arr) do raw[#raw + 1] = d end
        end
    end

    -- Nettoyer + premier filtre local (ni installé, ni dépôt), en dédupliquant.
    local seen = {}
    local candidates = {}
    for _, d in ipairs(raw) do
        local n = strip_version(d)
        if n and n ~= "" and not seen[n] then
            seen[n] = true
            if not is_installed(n) and not in_repos(n) then
                candidates[#candidates + 1] = n
            end
        end
    end

    if #candidates == 0 then return {}, nil end

    -- Second filtre : un seul aur.info groupé. Ne survivent que les candidates
    -- réellement présentes dans l'AUR.
    local found, ferr = aur.info(config, candidates)
    if not found then return nil, ferr end

    local result = {}
    for _, n in ipairs(candidates) do
        if found[n] then result[#result + 1] = n end
    end
    return result, nil
end

-- repo_deps_of(config, name) -> (liste, nil) | (nil, err)
-- Dépendances de `name` (Depends + MakeDepends) qui sont dans les DÉPÔTS et
-- NON encore installées. Comme la compilation tourne en tant qu'utilisateur
-- yaourt (sans droits pacman), ces dépendances doivent être installées en root
-- AVANT de lancer makepkg (lequel est appelé sans -s). Renvoie les noms nus.
function deps.repo_deps_of(config, name)
    local info, err = aur.info(config, { name })
    if not info then return nil, err end

    local entry = info[name]
    if not entry then return {}, nil end

    local raw = {}
    for _, field in ipairs({ "Depends", "MakeDepends" }) do
        local arr = entry[field]
        if type(arr) == "table" then
            for _, d in ipairs(arr) do raw[#raw + 1] = d end
        end
    end

    local seen = {}
    local result = {}
    for _, d in ipairs(raw) do
        local n = strip_version(d)
        if n and n ~= "" and not seen[n] then
            seen[n] = true
            -- On ne garde que ce qui est dans les dépôts et pas déjà installé.
            if not is_installed(n) and in_repos(n) then
                result[#result + 1] = n
            end
        end
    end
    return result, nil
end

-- resolve(config, target) -> (ordre, nil) | (nil, err)
-- Explore récursivement le graphe des dépendances AUR de `target` et renvoie
-- la liste ORDONNÉE des dépendances AUR à construire AVANT la cible (la cible
-- elle-même n'est pas incluse). Tri topologique par parcours en profondeur :
-- on visite les dépendances d'un paquet avant de l'ajouter, donc les feuilles
-- se retrouvent en tête et les paquets les plus proches de la cible en fin.
-- L'ensemble `visited` évite les doublons et neutralise les cycles éventuels.
function deps.resolve(config, target)
    local order   = {}
    local visited = {}
    local rerr

    local function visit(pkg)
        if visited[pkg] then return true end
        visited[pkg] = true

        local direct, err = deps.aur_deps_of(config, pkg)
        if not direct then
            rerr = err
            return false
        end
        for _, d in ipairs(direct) do
            if not visit(d) then return false end
        end
        -- Post-ordre : on ajoute pkg APRÈS ses dépendances. Chaque visit(d)
        -- a déjà poussé d (et ses sous-dépendances) dans `order`, donc à ce
        -- point toutes les dépendances de pkg le précèdent dans la liste.
        -- On ajoute pkg seulement s'il n'est pas la cible (la cible est
        -- construite séparément par l'appelant).
        if pkg ~= target then
            order[#order + 1] = pkg
        end
        return true
    end

    if not visit(target) then
        return nil, rerr
    end
    return order, nil
end

-- deps.show(config, name) -> code de sortie. Outil de debug : affiche les
-- dépendances AUR directes d'un paquet, sans rien construire.
function deps.show(config, name)
    local list, err = deps.aur_deps_of(config, name)
    if not list then
        print("Erreur : " .. tostring(err))
        return 1
    end
    print("Dépendances AUR directes de " .. name .. " :")
    if #list == 0 then
        print("  (aucune)")
    else
        for _, d in ipairs(list) do print("  " .. d) end
    end
    return 0
end

-- deps.show_resolve(config, name) -> code de sortie. Outil de debug : affiche
-- l'ordre de build récursif complet des dépendances AUR, sans rien construire.
function deps.show_resolve(config, name)
    local order, err = deps.resolve(config, name)
    if not order then
        print("Erreur : " .. tostring(err))
        return 1
    end
    print("Ordre de build des dépendances AUR de " .. name .. " :")
    if #order == 0 then
        print("  (aucune dépendance AUR)")
    else
        for i, d in ipairs(order) do print("  " .. i .. ". " .. d) end
        print("  " .. (#order + 1) .. ". " .. name .. "  (cible)")
    end
    return 0
end

return deps
