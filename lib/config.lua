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
local i18n = require("lib.i18n")

local config = {}

-- Config de dev : dossier cfg/ avec config.toml dans le répertoire courant.
local DEV_CONFIG = "cfg/config.toml"

-- Valeurs intégrées au programme. Cette fonction reste accessible afin que
-- les tests puissent verrouiller les choix d'interface par défaut sans
-- dépendre d'un fichier de configuration local.
function config.defaults()
    return {
        -- Répertoire de clonage/build des paquets AUR.
        builddir     = util.cache_home() .. "/yaourt",
        -- Commande sudo (pour les opérations pacman nécessitant root).
        sudo         = "sudo",
        -- Éditeur pour la revue de PKGBUILD.
        editor       = babet.env("EDITOR") or babet.env("VISUAL") or "vi",
        -- Couleur dans les affichages.
        color        = true,
        -- Langue de l'interface : "auto" suit l'environnement POSIX. Toute
        -- locale peut être indiquée (ex. "fr", "pt_BR", "zh_TW").
        language     = "auto",
        -- Base de l'AUR (RPC + git).
        aur_url      = "https://aur.archlinux.org",
        -- Récapitulatif AUR avant les MAJ : "notable" affiche seulement les
        -- paquets à surveiller, "all" la liste complète, false masque tout.
        -- La valeur historique true reste acceptée comme alias de "all".
        list_aur     = "notable",
        -- Vérifier les nouvelles révisions des paquets AUR de développement
        -- (-git, -hg, -svn, -bzr) pendant -Syu. Désactivé par défaut pour ne
        -- pas ajouter de requêtes réseau à la mise à jour ordinaire.
        devel        = false,
        -- Nettoyage des dépendances de build devenues orphelines pendant une
        -- opération AUR : false (défaut), "ask" ou "always".
        cleanup_build_deps = false,
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
    local conf = config.defaults()
    local path = config_path()

    if babet.fileExists(path) then
        local fh = io.open(path, "r")
        if fh then
            local content = fh:read("a")
            fh:close()
            local parsed, err = babet.toml.decode(content or "")
            if not parsed then
                io.stderr:write(i18n.t("config.invalid", {
                    path = path,
                    error = tostring(err),
                }) .. "\n")
            else
                -- mergeTables : la dernière table gagne -> l'utilisateur écrase les défauts.
                conf = babet.mergeTables(conf, parsed)
            end
        end
    end

    -- Expansion du ~ sur les chemins.
    conf.builddir = util.expanduser(conf.builddir)
    if conf.vcs_state_file then
        conf.vcs_state_file = util.expanduser(conf.vcs_state_file)
    end

    return conf
end

return config
