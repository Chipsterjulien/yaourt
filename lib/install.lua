-- install.lua — installation directe de paquets (dépôts ou AUR).
--
-- Implémente `-S <paquet>...`. Les paquets sont classés en deux groupes :
-- ceux présents dans les dépôts officiels (installés en UN seul `pacman -S`)
-- et ceux de l'AUR. Pour chaque paquet AUR, ses dépendances AUR sont résolues
-- récursivement (deps.resolve) et construites AVANT lui, dans l'ordre
-- topologique. Les dépendances des dépôts restent gérées par makepkg.
--
-- ROADMAP (objectif : équivalent yay) :
--   étape 1  : routage dépôt/AUR, paquet par paquet, avec bilan.
--   étape 2  : groupement des paquets dépôt dans un seul `pacman -S`.
--   étape 3  : résolution récursive des dépendances AUR.              <-- ICI
--   à venir  : provides / contraintes de version, --asdeps sur les deps.

local util    = require("lib.util")
local log     = require("lib.log")
local build   = require("lib.build")
local pacman  = require("lib.pacman")
local color   = require("lib.color")
local deps    = require("lib.deps")

local install = {}

-- in_repos(name) -> bool : vrai si le paquet existe dans un dépôt officiel.
-- Détection via `pacman -Si <name>` (capturé) : code 0 = trouvé.
local function in_repos(name)
    local res = util.run({ "pacman", "-Si", name })
    return res ~= nil and res.code == 0
end

-- classify(names) -> (repos, auras) : répartit les paquets demandés entre
-- ceux des dépôts et les autres (candidats AUR), en préservant l'ordre.
local function classify(names)
    local repos, auras = {}, {}
    for _, name in ipairs(names) do
        if in_repos(name) then
            repos[#repos + 1] = name
        else
            auras[#auras + 1] = name
        end
    end
    return repos, auras
end

-- ensure_repo_deps(config, name) -> (true, nil) | (false, raison)
-- Installe en root les dépendances dépôt manquantes de `name` (pacman -S
-- --asdeps --needed) AVANT la compilation. Nécessaire car makepkg tourne en
-- tant que l'utilisateur yaourt (sans droits pacman) et est appelé sans -s ;
-- les dépendances dépôt doivent donc être déjà présentes. --asdeps les marque
-- comme dépendances (pour un futur nettoyage), --needed évite de réinstaller.
local function ensure_repo_deps(config, name)
    local rdeps, err = deps.repo_deps_of(config, name)
    if not rdeps then
        return false, name .. " : échec résolution des dépendances dépôt ("
            .. tostring(err) .. ")"
    end
    if #rdeps == 0 then
        return true, nil
    end
    local argv = luapilot.mergeTables({ "-S", "--asdeps", "--needed" }, rdeps)
    local code = pacman.passthrough(config, argv)
    if code ~= 0 then
        return false, name .. " : échec installation des dépendances dépôt ("
            .. table.concat(rdeps, ", ") .. ")"
    end
    return true, nil
end

-- build_aur_with_deps(config, name, built, ok_names, collect)
-- Construit un paquet AUR après avoir construit ses dépendances AUR dans
-- l'ordre résolu. `built` est l'ensemble partagé des paquets déjà construits
-- dans cette session (anti-doublon entre plusieurs cibles). Si une dépendance
-- échoue, la cible est abandonnée (sa dépendance manquerait de toute façon).
-- Renseigne ok_names (succès) et collect (échecs « nom : raison »).
local function build_aur_with_deps(config, name, built, ok_names, collect)
    -- Résolution des dépendances AUR (ordre topologique, cible non incluse).
    local order, rerr = deps.resolve(config, name)
    if not order then
        collect[#collect + 1] = name .. " : échec de résolution des dépendances ("
            .. tostring(rerr) .. ")"
        return
    end

    -- Construit un paquet AUR : d'abord ses dépendances dépôt (en root), puis
    -- makepkg (en tant que yaourt). Renvoie (true) ou (false, raison).
    local function build_one_full(pkg)
        local ok, derr = ensure_repo_deps(config, pkg)
        if not ok then return false, derr end
        return build.one(config, pkg)
    end

    -- Construire chaque dépendance AUR d'abord, dans l'ordre.
    for _, dep in ipairs(order) do
        if not built[dep] then
            local ok, err = build_one_full(dep)
            built[dep] = true
            if ok then
                ok_names[#ok_names + 1] = dep
            else
                -- Une dépendance échoue : inutile de tenter la cible.
                collect[#collect + 1] = err
                collect[#collect + 1] = name
                    .. " : abandonné (échec de la dépendance " .. dep .. ")"
                return
            end
        end
    end

    -- Construire enfin la cible.
    if not built[name] then
        local ok, err = build_one_full(name)
        built[name] = true
        if ok then
            ok_names[#ok_names + 1] = name
        else
            collect[#collect + 1] = err
        end
    end
end

-- run(config, names) -> code de sortie (0 = tout ok, 1 = au moins un échec)
-- Dépôts d'abord (un seul pacman -S), puis chaque AUR avec ses dépendances AUR.
function install.run(config, names)
    local C            = color.new(config.color)

    local repos, auras = classify(names)

    local ok_names     = {} -- noms des paquets installés avec succès
    local collect      = {} -- messages d'échec
    local built        = {} -- paquets AUR déjà construits (anti-doublon)

    -- 1) Dépôts : un seul appel pacman pour tout le groupe (atomique).
    if #repos > 0 then
        local argv = luapilot.mergeTables({ "-S" }, repos)
        local code = pacman.passthrough(config, argv)
        if code == 0 then
            for _, r in ipairs(repos) do ok_names[#ok_names + 1] = r end
        else
            collect[#collect + 1] =
                "dépôts (" .. table.concat(repos, ", ") .. ") : échec de l'installation"
            print(C.red("\n==> Échec de l'installation des paquets des dépôts ; "
                .. "poursuite avec l'AUR."))
        end
    end

    -- 2) AUR : chaque cible avec ses dépendances AUR résolues d'abord.
    for _, name in ipairs(auras) do
        build_aur_with_deps(config, name, built, ok_names, collect)
    end

    -- 3) Bilan combiné. Le compte porte sur les paquets DEMANDÉS (cibles
    -- dépôt + AUR construits) ; pacman a pu installer en plus des dépendances
    -- (dépôt via --asdeps, déjà affichées par pacman), non comptées ici.
    print(C.green("\n==> " .. #ok_names .. " paquet(s) demandé(s) installé(s)"))
    if #ok_names > 0 then
        print(C.green("    " .. table.concat(ok_names, ", ")))
    end
    if #collect > 0 then
        print(C.red("\n==> Échecs (" .. #collect .. ") :"))
        for _, e in ipairs(collect) do
            print(C.red("    " .. tostring(e)))
        end
    end

    return #collect == 0 and 0 or 1
end

return install
