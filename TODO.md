# TODO

## Fait

- [x] Passer `-c` à makepkg + supprimer le `.pkg.tar.zst` après installation
      réussie, sans toucher au clone git.
- [x] Brancher le build AUR dans `-Syu` (boucle, poursuite sur échec, bilan).
- [x] Gestion sudo/root unifiée (`util.sudo_prefix`) : pas de sudo en root.
- [x] Cas B : builddir + parent `~/.cache` créés en tant que `yaourt`
      (corrige la compilation des paquets Go/Rust/Node comme yay).
- [x] Recherche unifiée dépôts + AUR (`-Ss`) : module search.lua, tri par
      votes, votes/popularité, flags, marqueur installé.

## En cours / à peaufiner

- [ ] Affichage de la recherche `-Ss` : améliorer la lisibilité pour se
      rapprocher de yaourt (format des votes/popularité, contraste des
      couleurs, alignement éventuel). [détails à préciser]
- [ ] Retirer le `inspect` de debug dans search.lua (aur_search) s'il reste.

## Fonctionnalités à venir

- [ ] Installation directe d'un paquet AUR par son nom (`yaourt -S <aurpkg>`) :
      router entre dépôts et AUR, gérer la résolution de dépendances.
- [ ] Sélection [M]anuel dans `-Syu` : choisir à la carte quels paquets AUR
      mettre à jour.
- [ ] Décider du sort de `-B` : commande de build à la demande, ou fondu dans
      le futur `-S <aurpkg>`.
- [ ] Recherche : envisager un ordre inversé (plus votés près du prompt) ou
      une limite de résultats configurable (firefox = ~500 résultats AUR).

## Refactoring / dette technique

- [ ] Extraire les helpers d'affichage communs (`repo_color`, `isset`, rendu
      des flags) dans un module partagé : actuellement dupliqués entre
      update.lua et search.lua.

## Build AUR — robustesse / finitions

- [ ] Gestion fine des split packages : n'installer que les paquets demandés,
      pas tout ce que `makepkg --packagelist` renvoie.
- [ ] Diff de PKGBUILD en mise à jour : montrer ce qui a changé depuis la
      dernière validation (historique git conservé dans le builddir persistant).
- [ ] Revue des autres fichiers d'un paquet AUR (`.install`, patches, `.sh`).
- [ ] Bilan `-Syu` : distinguer un refus de revue (choix utilisateur) d'un vrai
      échec de build.

## Correctifs / cas limites

- [ ] Mélange `-G` en cas A (clone appartenant à l'utilisateur courant) puis
      build en root sur le même builddir : clones préexistants restant à
      l'ancien propriétaire. Marginal.

## Interface / UX

- [ ] Saisie mono-touche pour les prompts `[O/n]` (sans Entrée) — mode terminal
      *raw* via `stty` avec restauration sûre (luapilot n'a pas de `readchar`).

## Internationalisation

- [ ] i18n : externaliser les chaînes, gérer le pluriel (gettext/ngettext).

## Dépendances

- [ ] Internaliser `checkupdates` (base de sync temporaire) pour supprimer la
      dépendance à `pacman-contrib`.

## Packaging / publication

- [ ] Créer l'utilisateur système `yaourt` via `sysusers.d` dans le PKGBUILD
      (dédié, sans shell de login, home `/var/cache/yaourt`).
- [ ] Ajouter les en-têtes de licence GPLv3 (version courte) dans chaque
      fichier source, en fin de projet.
