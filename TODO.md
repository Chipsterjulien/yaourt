# TODO

## Fait

- [x] Passer `-c` à makepkg + supprimer le `.pkg.tar.zst` après installation
      réussie, sans toucher au clone git.

## Packaging / publication

- [ ] Créer l'utilisateur système `yaourt` via `sysusers.d` dans le PKGBUILD
      (utilisateur dédié, sans shell de login, pour compiler les paquets AUR
      quand yaourt tourne en root sans sudo). Doit refléter exactement les
      attributs du `useradd` de dev : home `/var/cache/yaourt`, shell nologin.
- [ ] Ajouter les en-têtes de licence GPLv3 (version courte) dans chaque fichier
      source, en fin de projet (pas pendant le dev, ça en mettrait partout).

## Build AUR

- [ ] Gestion fine des split packages : n'installer que les paquets demandés,
      pas tout ce que `makepkg --packagelist` renvoie.
- [ ] Diff de PKGBUILD en mise à jour : montrer seulement ce qui a changé depuis
      la dernière validation (repose sur l'historique git conservé dans le
      builddir persistant).
- [ ] Revue des autres fichiers d'un paquet AUR (`.install`, patches, `.sh`)
      en plus du seul PKGBUILD.

## Interface / UX

- [ ] Saisie mono-touche pour les prompts `[O/n]` (sans Entrée) — nécessite un
      mode terminal *raw* via `stty` avec restauration sûre, car luapilot
      n'expose pas de `readchar`.

## Internationalisation

- [ ] i18n : externaliser toutes les chaînes et gérer le pluriel proprement
      (gettext/ngettext). La pluralisation manuelle actuelle est un palliatif.

## Dépendances

- [ ] Internaliser `checkupdates` (base de sync temporaire) pour supprimer la
      dépendance à `pacman-contrib`.

## Cas limites à surveiller

- [ ] Mélange `-G` en cas A (clone appartenant à l'utilisateur courant) puis
      build en root sur le même builddir : les clones préexistants restent à
      l'ancien propriétaire alors que le parent passe à `yaourt`. Marginal, mais
      à garder en tête.
