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

-- build_summary(C, results) -> code de sortie (0 ok, 1 problème, 130 interrompu)
-- Affiche un bilan groupé par statut à partir d'une liste de résultats typés
-- (build.result). Distingue les mises à jour réussies, les refus de revue (choix
-- de l'utilisateur, non alarmants), les interruptions (Ctrl+C) et les échecs.
-- Le verbe d'action (« installé(s) » / « mis à jour ») est paramétrable.
function display.build_summary(C, results, ok_verb)
    ok_verb = ok_verb or "installé(s)"
    local groups = { ok = {}, refused = {}, interrupted = {}, failed = {} }
    for _, r in ipairs(results) do
        -- failed et install_failed sont regroupés sous « Échecs ».
        local key = r.status
        if key == "install_failed" then key = "failed" end
        if groups[key] then
            groups[key][#groups[key] + 1] = r
        else
            groups.failed[#groups.failed + 1] = r
        end
    end

    print(C.green("\n==> " .. #groups.ok .. " paquet(s) " .. ok_verb))
    if #groups.ok > 0 then
        local names = {}
        for _, r in ipairs(groups.ok) do names[#names + 1] = r.name end
        print(C.green("    " .. table.concat(names, ", ")))
    end

    if #groups.refused > 0 then
        print(C.cyan("\n==> Refusé(s) par l'utilisateur (" .. #groups.refused .. ") :"))
        for _, r in ipairs(groups.refused) do
            print(C.cyan("    " .. r.name))
        end
    end

    if #groups.interrupted > 0 then
        print(C.yellow("\n==> Interrompu(s) (" .. #groups.interrupted .. ") :"))
        for _, r in ipairs(groups.interrupted) do
            print(C.yellow("    " .. tostring(r.message)))
        end
    end

    if #groups.failed > 0 then
        print(C.red("\n==> Échec(s) (" .. #groups.failed .. ") :"))
        for _, r in ipairs(groups.failed) do
            print(C.red("    " .. tostring(r.message)))
        end
    end

    -- Code de sortie : interruption prioritaire (130), puis échec (1), sinon 0.
    -- Un refus seul n'est pas une erreur.
    if #groups.interrupted > 0 then return 130 end
    if #groups.failed > 0 then return 1 end
    return 0
end

return display
