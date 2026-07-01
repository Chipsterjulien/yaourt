-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- config.lua — chargement de la configuration.
--
-- Deux modes :
--   * dev        : un fichier ./cfg/config.toml dans le répertoire courant
--                  (là où l'on lance `babet .`). Pratique pour tester sans
--                  toucher à sa vraie config utilisateur.
--   * production : ~/.config/yaourt/config.toml (ou $XDG_CONFIG_HOME/…).
-- On fusionne le fichier trouvé par-dessus les valeurs par défaut. TOML n'a
-- pas de decode_file : on lit le fichier puis babet.toml.decode (cf. README).

local util = require("lib.util")

local config = {}

-- Config de dev : dossier cfg/ avec config.toml dans le répertoire courant.
local DEV_CONFIG = "cfg/config.toml"

local function defaults()
    return {
        -- Répertoire de clonage/build des paquets AUR.
        builddir     = util.cache_home() .. "/yaourt",
        -- Commande sudo (pour les opérations pacman nécessitant root).
        sudo         = "sudo",
        -- Éditeur pour la revue de PKGBUILD (étape ultérieure).
        editor       = babet.env("EDITOR") or babet.env("VISUAL") or "vi",
        -- Couleur dans nos affichages (l'affichage des MAJ viendra plus tard).
        color        = true,
        -- Base de l'AUR (RPC + git).
        aur_url      = "https://aur.archlinux.org",
        -- Lister tous les paquets AUR installés (avec statut) avant les MAJ.
        list_aur     = false,
        -- Nombre maximal de résultats affichés par section lors d'une recherche
        -- (-Ss) : AUR et dépôts limités chacun à cette valeur. 0 = illimité.
        -- Pour l'AUR, ce sont les mieux notés qui sont conservés.
        search_limit = 20,
    }
end

-- Renvoie (chemin_config, est_dev). Si un cfg/config.toml existe dans le
-- répertoire courant, on est en dev ; sinon, emplacement XDG (production).
local function config_path()
    if babet.fileExists(DEV_CONFIG) then
        return DEV_CONFIG, true
    end
    return util.config_home() .. "/yaourt/config.toml", false
end

-- Renvoie la table de config effective (jamais nil).
function config.load()
    local conf = defaults()
    local path = config_path()

    if babet.fileExists(path) then
        local fh = io.open(path, "r")
        if fh then
            local content = fh:read("a")
            fh:close()
            local parsed, err = babet.toml.decode(content or "")
            if not parsed then
                io.stderr:write("yaourt: config invalide (" .. path .. ") : " .. tostring(err) .. "\n")
            else
                -- mergeTables : la dernière table gagne -> l'utilisateur écrase les défauts.
                conf = babet.mergeTables(conf, parsed)
            end
        end
    end

    -- Expansion du ~ sur les chemins.
    conf.builddir = util.expanduser(conf.builddir)

    return conf
end

return config
