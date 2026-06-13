# TODO

## Fait

- [x] Passer `-c` à makepkg + supprimer le `.pkg.tar.zst` après installation
      réussie, sans toucher au clone git.
- [x] Brancher le build AUR dans `-Syu` (boucle sur les paquets AUR à mettre à
      jour, on continue en cas d'échec, bilan succès/échecs à la fin).

## Fonctionnalités à venir

- [ ] Recherche `-Ss` incluant l'AUR (aujourd'hui `-Ss` passe à pacman = dépôts
      seulement). `aur.search` existe déjà dans `aur.lua`, reste à brancher +
      afficher.
- [ ] Installation directe d'un paquet AUR par son nom (`yaourt -S <aurpkg>`) :
      router entre dépôts et AUR, gérer la résolution de dépendances.
- [ ] Sélection [M]anuel dans `-Syu` : choisir à la carte quels paquets AUR
      mettre à jour.
- [ ] Décider du sort de `-B` : le garder comme commande de build à la demande,
      ou le fondre dans le futur `-S <aurpkg>`.

## Build AUR — robustesse / finitions

- [ ] Gestion fine des split packages : n'installer que les paquets demandés,
      pas tout ce que `makepkg --packagelist` renvoie.
- [ ] Diff de PKGBUILD en mise à jour : montrer seulement ce qui a changé depuis
      la dernière validation (repose sur l'historique git conservé dans le
      builddir persistant).
- [ ] Revue des autres fichiers d'un paquet AUR (`.install`, patches, `.sh`)
      en plus du seul PKGBUILD.
- [ ] Bilan `-Syu` : distinguer un refus de revue (choix de l'utilisateur) d'un
      vrai échec de build, plutôt que tout ranger dans « Échecs ». Corriger
      aussi le nom affiché en double (err contient déjà « nom : raison »).

## Correctifs connus

- [ ] `pacman -Syu` dans `update.run` utilise `config.sudo or "sudo"` : casse
      en root sans sudo. Gérer le cas root (pas de sudo nécessaire).
- [ ] Mélange `-G` en cas A (clone appartenant à l'utilisateur courant) puis
      build en root sur le même builddir : les clones préexistants restent à
      l'ancien propriétaire alors que le parent passe à `yaourt`. Marginal.

## Interface / UX

- [ ] Saisie mono-touche pour les prompts `[O/n]` (sans Entrée) — nécessite un
      mode terminal *raw* via `stty` avec restauration sûre, car luapilot
      n'expose pas de `readchar`.
- [ ] Harmoniser les titres de section : préfixe `==>` partout (le bilan des
      échecs dans `-Syu` ne l'a pas encore).

## Internationalisation

- [ ] i18n : externaliser toutes les chaînes et gérer le pluriel proprement
      (gettext/ngettext). La pluralisation manuelle actuelle est un palliatif.

## Dépendances

- [ ] Internaliser `checkupdates` (base de sync temporaire) pour supprimer la
      dépendance à `pacman-contrib`.

## Packaging / publication

- [ ] Créer l'utilisateur système `yaourt` via `sysusers.d` dans le PKGBUILD
      (dédié, sans shell de login, home `/var/cache/yaourt`).
- [ ] Ajouter les en-têtes de licence GPLv3 (version courte) dans chaque fichier
      source, en fin de projet.