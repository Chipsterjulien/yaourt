-- install.lua — installation directe de paquets (dépôts ou AUR).
--
-- Implémente `-S <paquet>...`. Pour chaque paquet demandé, route vers la bonne
-- source : présent dans les dépôts officiels -> on délègue à pacman ; sinon
-- on tente l'AUR via le pipeline de build (build.one).
--
-- ROADMAP (objectif : équivalent yay) :
--   étape 1  : routage dépôt/AUR, paquet par paquet, avec bilan.   <-- ICI
--   étape 2  : groupement des paquets dépôt dans un seul `pacman -S`.
--   étape 3  : résolution récursive des dépendances AUR (un paquet AUR
--              dépendant d'autres paquets AUR), dans l'ordre topologique.
--              Indispensable pour la parité avec yay/paru.

local util    = require("lib.util")
local log     = require("lib.log")
local build   = require("lib.build")
local pacman  = require("lib.pacman")
local color   = require("lib.color")

local install = {}

-- in_repos(name) -> bool : vrai si le paquet existe dans un dépôt officiel.
-- Détection via `pacman -Si <name>` (capturé) : code 0 = trouvé.
local function in_repos(name)
    local res = util.run({ "pacman", "-Si", name })
    return res ~= nil and res.code == 0
end

-- install_one(config, name) -> (true, nil) | (false, raison)
-- Route un paquet : dépôt -> pacman ; sinon -> AUR (build.one).
local function install_one(config, name)
    if in_repos(name) then
        local code = pacman.passthrough(config, { "-S", name })
        if code ~= 0 then
            return false, name .. " : échec de l'installation (pacman)"
        end
        return true, nil
    end
    -- Pas dans les dépôts : on tente l'AUR. build.one gère tout le pipeline
    -- et renvoie déjà (ok, "name : raison") — y compris « introuvable ».
    return build.one(config, name)
end

-- run(config, names) -> code de sortie (0 = tout ok, 1 = au moins un échec)
-- Boucle sur les paquets, route chacun, continue en cas d'échec, et affiche
-- un bilan final (réussites + échecs détaillés).
function install.run(config, names)
    local C = color.new(config.color)

    local collect = {}
    for _, name in ipairs(names) do
        local ok, err = install_one(config, name)
        if not ok then collect[#collect + 1] = err end
    end

    print(C.green("\n==> " .. #names - #collect .. " paquet(s) installé(s) avec succès"))
    if #collect > 0 then
        print(C.red("\n==> Échecs (" .. #collect .. ") :"))
        for _, e in ipairs(collect) do
            -- e vaut déjà « nom : raison ».
            print(C.red("    " .. tostring(e)))
        end
    end

    return #collect == 0 and 0 or 1
end

return install
