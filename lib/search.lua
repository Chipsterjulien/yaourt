-- search.lua — recherche unifiée AUR + dépôts (pacman).
--
-- Implémente `-Ss` : interroge le RPC AUR (aur.search) et `pacman -Ss`,
-- puis affiche le tout dans un format homogène et coloré.
--
-- Ordre d'affichage (façon yay) : l'AUR d'abord, les dépôts officiels ensuite.
-- Les résultats AUR sont triés par votes CROISSANT, de sorte que les paquets
-- les mieux notés se retrouvent en bas de la section AUR (au plus près du
-- prompt, donc visibles sans scroller). Chaque ligne AUR affiche un badge
-- « votes » en vidéo inversée et le détail « (votes : N, popularité : P) »
-- pour que ces chiffres soient explicites — beaucoup d'utilisateurs ignorent
-- à quoi correspond le couple de nombres affiché par les helpers AUR.
--
-- Couleurs par dépôt et drapeaux (orphelin)/(périmé) sont cohérents avec
-- l'affichage des mises à jour.

local aur     = require("lib.aur")
local color   = require("lib.color")
local log     = require("lib.log")
local util    = require("lib.util")
local display = require("lib.display")

local search  = {}

--------------------------------------------------------------------------
-- Helpers communs
--------------------------------------------------------------------------

-- Map nom -> version installée, via `pacman -Q`. Sert à marquer [installé]
-- et à repérer une version différente. Renvoie une table (vide si erreur).
local function installed_map()
    local res = util.run({ "pacman", "-Q" })
    local m = {}
    if res and res.code == 0 then
        for line in (res.stdout or ""):gmatch("[^\n]+") do
            local name, ver = line:match("^(%S+)%s+(%S+)")
            if name then m[name] = ver end
        end
    end
    return m
end

--------------------------------------------------------------------------
-- Collecte : dépôts officiels (pacman -Ss)
--------------------------------------------------------------------------

-- repo_search(term) -> liste d'entrées { repo, name, version, desc, installed }
-- Parse la sortie de `pacman -Ss` : une ligne d'entête « dépôt/nom version … »
-- suivie d'une ligne de description indentée.
local function repo_search(term)
    local res, err = util.run({ "pacman", "-Ss", term })
    -- pacman -Ss renvoie un code non nul quand il n'y a aucun résultat :
    -- ce n'est pas une erreur de lancement, juste « rien trouvé ».
    if not res then
        log.error("pacman -Ss: " .. tostring(err))
        return {}
    end

    local results = {}
    local current
    for line in (res.stdout or ""):gmatch("[^\n]+") do
        if line:match("^%s") then
            -- Ligne indentée -> description du résultat courant.
            if current then current.desc = line:match("^%s+(.*)") or "" end
        else
            -- Ligne d'entête : « dépôt/nom version [groupes] [installé] ».
            local repo, name = line:match("^(%S+)/(%S+)")
            if repo then
                current = {
                    repo      = repo,
                    name      = name,
                    version   = line:match("^%S+%s+(%S+)") or "",
                    desc      = "",
                    installed = line:find("%[install") ~= nil,
                }
                results[#results + 1] = current
            end
        end
    end
    return results
end

--------------------------------------------------------------------------
-- Collecte : AUR (RPC)
--------------------------------------------------------------------------

-- aur_search(config, term, inst) -> liste d'entrées normalisées | (nil, err).
-- Réutilise aur.search et complète chaque entrée (statut installé, votes,
-- popularité, drapeaux). Tri par votes CROISSANT : les mieux notés en dernier.
local function aur_search(config, term, inst)
    local raw, err = aur.search(config, term)
    if not raw then return nil, err end

    local list = {}
    for _, e in ipairs(raw) do
        list[#list + 1] = {
            repo       = "aur",
            name       = e.Name,
            version    = e.Version,
            desc       = util.isset(e.Description) and e.Description or "",
            votes      = e.NumVotes or 0,
            popularity = e.Popularity or 0,
            orphan     = not util.isset(e.Maintainer),
            outofdate  = util.isset(e.OutOfDate),
            installed  = inst[e.Name] ~= nil,
            inst_ver   = inst[e.Name],
        }
    end
    -- Votes croissant -> les paquets les mieux notés finissent en bas,
    -- au plus près du prompt. Nom en cas d'égalité.
    table.sort(list, function(a, b)
        if a.votes ~= b.votes then return a.votes < b.votes end
        return a.name < b.name
    end)
    return list
end

--------------------------------------------------------------------------
-- Affichage
--------------------------------------------------------------------------

-- Affiche une entrée dépôt : entête colorée + description indentée.
local function print_repo(C, e)
    local rc   = display.repo_color(C, e.repo)
    local head = "  " .. rc(e.repo .. "/") .. C.bold(e.name) .. " " .. C.green(e.version)
    if e.installed then head = head .. " " .. C.blue("[installé]") end
    print(head)
    if e.desc ~= "" then print("      " .. e.desc) end
end

-- Affiche une entrée AUR : entête + badge votes + détail explicite + statut.
local function print_aur(C, e)
    local rc   = display.repo_color(C, e.repo)
    local head = "  " .. rc(e.repo .. "/") .. C.bold(e.name) .. " " .. C.green(e.version)

    -- Votes + popularité explicites, en cyan pour ressortir sans entrer en
    -- conflit avec les autres couleurs de la ligne (orphelin/installé/version).
    -- Le libellé en toutes lettres lève l'ambiguïté du couple de nombres.
    head       = head .. " " .. C.badge("44", "37",
        string.format(" votes : %d, popularité : %.2f ", e.votes, e.popularity))

    if e.installed then
        if e.inst_ver and e.inst_ver ~= e.version then
            head = head .. " " .. C.blue("[installé : " .. e.inst_ver .. "]")
        else
            head = head .. " " .. C.blue("[installé]")
        end
    end
    if e.orphan then head = head .. "  " .. C.yellow("(orphelin)") end
    if e.outofdate then head = head .. "  " .. C.red("(périmé)") end

    print(head)
    if e.desc ~= "" then print("      " .. e.desc) end
end

--------------------------------------------------------------------------
-- Orchestration
--------------------------------------------------------------------------

-- run(config, term) -> code de sortie (0 = des résultats, 1 = aucun/erreur)
function search.run(config, term)
    local C           = color.new(config.color)

    local inst        = installed_map()
    local repos       = repo_search(term)
    local auras, aerr = aur_search(config, term, inst)
    if not auras then
        log.warn("AUR: " .. tostring(aerr))
        auras = {}
    end

    -- AUR d'abord (mieux notés en bas de section), dépôts ensuite.
    if #auras > 0 then
        print(C.cyan("==> AUR (votes, popularité) (" .. #auras .. ")"))
        for _, e in ipairs(auras) do print_aur(C, e) end
    end
    if #repos > 0 then
        if #auras > 0 then print("") end
        print(C.cyan("==> Dépôts officiels (" .. #repos .. ")"))
        for _, e in ipairs(repos) do print_repo(C, e) end
    end

    if #repos == 0 and #auras == 0 then
        print(":: Aucun paquet trouvé pour « " .. term .. " ».")
        return 1
    end
    return 0
end

return search
