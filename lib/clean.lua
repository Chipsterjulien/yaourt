-- clean.lua — nettoyage du cache de build yaourt.
--
-- Deux niveaux, façon yay/pacman :
--   -Sc  (doux)  : dans chaque dépôt cloné, supprime tout ce qui n'est PAS
--                  suivi par git (sources téléchargées, restes de build) via
--                  `git clean -fdx`, en conservant le clone (PKGBUILD, .git).
--                  Puis délègue à `pacman -Sc` pour le cache pacman.
--   -Scc (total) : supprime TOUT le contenu du cache de build (tous les dépôts
--                  clonés). Le prochain build re-clonera. Puis `pacman -Scc`.
--
-- Le cache de build est config.builddir (ex. /var/cache/yaourt/.cache/yaourt
-- ou ~/.cache/yaourt). Chaque sous-dossier est le clone d'un paquet AUR.

local util   = require("lib.util")
local log    = require("lib.log")
local color  = require("lib.color")
local pacman = require("lib.pacman")

local clean  = {}

-- list_pkg_dirs(builddir) -> liste des chemins des dépôts de paquets.
-- Renvoie une liste (éventuellement vide). nil si le cache n'existe pas.
local function list_pkg_dirs(builddir)
    local is_dir = luapilot.isdir(builddir)
    if not is_dir then return nil end
    -- `ls -1` capturé : un nom par ligne. On reconstruit les chemins absolus
    -- et on ne garde que les répertoires.
    local res = util.run({ "ls", "-1", builddir })
    if not res or res.code ~= 0 then return {} end
    local dirs = {}
    for name in (res.stdout or ""):gmatch("[^\n]+") do
        local path = builddir .. "/" .. name
        if luapilot.isdir(path) then
            dirs[#dirs + 1] = path
        end
    end
    return dirs
end

-- confirm(C, prompt) -> bool : invite [O/n], vrai si l'utilisateur accepte.
local function confirm(C, prompt)
    io.write(C.cyan("==> ") .. prompt .. " [O/n] ")
    io.flush()
    local ans = (io.read("l") or ""):lower()
    return not (ans == "n" or ans == "non")
end

-- soft(config) : nettoyage doux. Pour chaque dépôt, `git clean -fdx` (supprime
-- les fichiers non suivis : sources téléchargées, artefacts), en gardant le
-- clone. Puis pacman -Sc.
function clean.soft(config)
    local C = color.new(config.color)
    local dirs = list_pkg_dirs(config.builddir)

    if dirs == nil then
        print(C.dim("Cache de build absent (" .. config.builddir .. ") : rien à nettoyer."))
    elseif #dirs == 0 then
        print(C.dim("Cache de build vide : rien à nettoyer côté AUR."))
    else
        print(C.cyan("==> ") .. C.bold("Nettoyage des sources de build (" .. #dirs .. " paquet(s))"))
        print(C.dim("    " .. config.builddir))
        if confirm(C, "Supprimer les fichiers non suivis par git dans chaque dépôt ?") then
            local cleaned = 0
            for _, dir in ipairs(dirs) do
                -- git clean -fdx en tant que build_user (le dépôt lui appartient
                -- en cas B). -f force, -d inclut les répertoires, -x les fichiers
                -- ignorés par .gitignore (sources, artefacts).
                local res = util.run_as(config.build_user,
                    { "git", "-C", dir, "clean", "-fdx" })
                if res and res.code == 0 then
                    cleaned = cleaned + 1
                else
                    log.warn("échec du nettoyage de " .. dir)
                end
            end
            print(C.green("==> " .. cleaned .. " dépôt(s) nettoyé(s)."))
        else
            print("Nettoyage AUR ignoré.")
        end
    end

    -- Cache pacman (délégué, avec sa propre confirmation).
    print("")
    print(C.cyan("==> ") .. C.bold("Cache pacman"))
    local cmd = {}
    local p = util.sudo_prefix(config)
    if p then cmd[#cmd + 1] = p end
    cmd[#cmd + 1] = "pacman"
    cmd[#cmd + 1] = "-Sc"
    return util.passthrough(cmd)
end

-- full(config) : nettoyage total. Supprime tout le contenu du cache de build
-- (tous les dépôts clonés). Puis pacman -Scc.
function clean.full(config)
    local C = color.new(config.color)
    local dirs = list_pkg_dirs(config.builddir)

    if dirs == nil then
        print(C.dim("Cache de build absent (" .. config.builddir .. ") : rien à nettoyer."))
    elseif #dirs == 0 then
        print(C.dim("Cache de build vide : rien à nettoyer côté AUR."))
    else
        print(C.cyan("==> ") .. C.bold("Suppression COMPLÈTE du cache de build (" .. #dirs .. " paquet(s))"))
        print(C.dim("    " .. config.builddir))
        print(C.red("    Tous les dépôts clonés seront supprimés (re-clonage au prochain build)."))
        if confirm(C, "Confirmer la suppression de tous les dépôts ?") then
            local removed = 0
            for _, dir in ipairs(dirs) do
                local ok, err = luapilot.remove(dir)
                if ok then
                    removed = removed + 1
                else
                    log.warn("impossible de supprimer " .. dir .. " : " .. tostring(err))
                end
            end
            print(C.green("==> " .. removed .. " dépôt(s) supprimé(s)."))
        else
            print("Suppression AUR ignorée.")
        end
    end

    -- Cache pacman complet (délégué).
    print("")
    print(C.cyan("==> ") .. C.bold("Cache pacman (complet)"))
    local cmd = {}
    local p = util.sudo_prefix(config)
    if p then cmd[#cmd + 1] = p end
    cmd[#cmd + 1] = "pacman"
    cmd[#cmd + 1] = "-Scc"
    return util.passthrough(cmd)
end

return clean
