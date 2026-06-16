# TODO

## Fait

- [x] Passer `-c` à makepkg + supprimer le `.pkg.tar.zst` après installation.
- [x] Brancher le build AUR dans `-Syu` (boucle, poursuite sur échec, bilan).
- [x] Gestion sudo/root unifiée (`util.sudo_prefix`).
- [x] Cas B : builddir + `~/.cache` créés en tant que `yaourt`.
- [x] Recherche unifiée dépôts + AUR (`-Ss`) : module search.lua.
- [x] Affichage `-Ss` : badge votes (fond bleu), ordre AUR/dépôts, tri par votes.
- [x] Installation directe `-S` — étape 1 : routage dépôt/AUR avec bilan.
- [x] build.install : filtrer les paquets réellement produits (ignore les
      paquets -debug fantômes des paquets sans binaire).

## Installation directe `-S` — suite de la roadmap

- [ ] Étape 2 : grouper les paquets dépôt dans un seul `pacman -S pkg1 pkg2`
      (au lieu d'un appel par paquet).
- [ ] Étape 3 : résolution récursive des dépendances AUR (paquet AUR dépendant
      d'autres paquets AUR), ordre topologique. INDISPENSABLE pour la parité
      avec yay/paru — fait partie de l'objectif final, pas optionnel.
- [ ] Transmettre les modificateurs pacman (`-Sf`, `-Sw`, `--needed`…) à pacman
      pour les paquets dépôt : actuellement `install_one` reconstruit un `-S`
      propre et jette les flags tapés par l'utilisateur.

## Autres fonctionnalités à venir

- [ ] Sélection [M]anuel dans `-Syu` : choisir à la carte les paquets AUR.
- [ ] Décider du sort de `-B` : commande de build à la demande, ou fondu dans
      `-S <aurpkg>` (qui fait déjà la même chose pour l'AUR).
- [ ] Recherche : ordre/limite configurables (firefox = ~500 résultats AUR).

## Refactoring / dette technique

- [ ] Extraire les helpers d'affichage communs (`repo_color`, `isset`, rendu
      des flags) dans un module partagé : dupliqués entre update.lua et
      search.lua.

## Build AUR — robustesse / finitions

- [ ] Diff de PKGBUILD en mise à jour : montrer ce qui a changé depuis la
      dernière validation (historique git conservé dans le builddir persistant).
- [ ] Revue des autres fichiers d'un paquet AUR (`.install`, patches, `.sh`).
- [ ] Bilan `-Syu` : distinguer un refus de revue d'un vrai échec de build.

## Correctifs / cas limites

- [ ] Mélange `-G` en cas A puis build en root sur le même builddir
      (propriété des clones préexistants). Marginal.

## Interface / UX

- [ ] Saisie mono-touche pour les prompts `[O/n]` (mode terminal raw via stty).

## Internationalisation

- [ ] i18n : externaliser les chaînes, gérer le pluriel (gettext/ngettext).

## Dépendances

- [ ] Internaliser `checkupdates` pour supprimer la dépendance à
      `pacman-contrib`.

## Packaging / publication

- [ ] Créer l'utilisateur système `yaourt` via `sysusers.d` dans le PKGBUILD.
- [ ] Ajouter les en-têtes de licence GPLv3 (version courte) dans chaque
      fichier source, en fin de projet.
