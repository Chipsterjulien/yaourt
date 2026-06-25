-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Julien Freyermuth
--
-- display.lua — helpers d'affichage partagés (couleurs, rendu).
--
-- Regroupe les fonctions de présentation communes à plusieurs commandes
-- (recherche, mise à jour…), pour éviter de les dupliquer.

local display = {}

-- repo_color(C, repo) -> fonction de couleur à appliquer au nom du dépôt.
-- Convention de couleurs partagée par -Ss et -Syu :
--   core = rouge, extra = vert, multilib = cyan, aur = magenta, autre = bleu.
function display.repo_color(C, repo)
    if repo == "core" then
        return C.red
    elseif repo == "extra" then
        return C.green
    elseif repo == "multilib" then
        return C.cyan
    elseif repo == "aur" then
        return C.magenta
    else
        return C.blue
    end
end

return display