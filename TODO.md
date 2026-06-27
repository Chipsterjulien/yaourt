# TODO

## Fait (jusqu'à la 0.2.0 et après)

- [x] Recherche unifiée dépôts + AUR (`-Ss`), tri par votes, badges.
- [x] Limite configurable des résultats de recherche (`search_limit`).
- [x] Installation directe `-S` : routage dépôt/AUR, groupement des paquets
      dépôt, résolution récursive des dépendances AUR.
- [x] Dépendances : gestion des `provides` et des contraintes de version
      (`pacman -T` local + `pacman -Sp` dépôts).
- [x] `-Syu` approche « façon yaourt » : synchro réelle (`pacman -Sy` + `-Qu`),
      suppression de la dépendance `pacman-contrib`.
- [x] Harmonisation `-S` / `-Syu` via `build.aur` (chemin de build unifié).
- [x] Sélection manuelle `[M]` dans `-Syu` (inclusion, numéros + plages).
      Invite `[O/n/M]` proposée seulement s'il y a des paquets AUR.
- [x] Diff des fichiers de build (PKGBUILD, .install, patches) à la mise à jour.
- [x] Bannière de build (nom + version installée -> cible).
- [x] Nettoyage du cache `-Sc` / `-Scc` (doux / complet).
- [x] Factorisation : `display.lua` (repo_color), `util.isset`.
- [x] En-têtes SPDX GPL-3.0-or-later sur tous les fichiers.
- [x] Nettoyage des paquets résiduels avant build (`clean_stale`) : évite le
      blocage « paquet déjà compilé » après une interruption.
- [x] Messages neutres « non terminée (échec ou interruption) » (le code de
      retour ne distingue pas Ctrl+C d'un vrai échec).
- [x] Transmission des modificateurs en `-S` : `-f` -> makepkg (force rebuild
      cible), `--needed` -> pacman + makepkg, flags inconnus -> pacman (dépôts).
- [x] Scripts de release (`build.sh` / `release.sh`) avec détection de l'archi
      et du binaire luapilot (`luapilot-*-linux-<arch>`).
- [x] Deux releases publiées (0.1.0, 0.2.0), x86_64 + aarch64.

## Fonctionnalités à venir

- [ ] Marquer les dépendances AUR construites comme dépendances (`--asdeps`)
      pour qu'un `-Rcs` de la cible les retire si elles deviennent orphelines.
- [ ] Sort de `-B` : le garder comme outil interne (non documenté) ou le
      fondre dans `-S`. Actuellement présent mais hors de l'aide.
- [ ] Inversion `^4` dans la sélection `[M]` (tout sauf 4) — l'inclusion
      simple (numéros + plages) suffit pour l'instant.
- [ ] `-w` / `--downloadonly` côté AUR : sens à définir (sources seules ?
      build sans installation ?) — laissé de côté volontairement.

## Robustesse

- [ ] Revue des autres fichiers d'un paquet (`.install`, patches) au premier
      clone (le diff les couvre déjà en mise à jour).
- [ ] Bilan `-Syu` : distinguer un refus de revue d'un vrai échec de build.
- [ ] Nettoyage optionnel des dépendances de build devenues orphelines après
      compilation.
- [ ] Cache des résolutions (aur.info / pacman répétés) pour les gros graphes.

## Finitions / packaging

- [ ] Créer l'utilisateur système `yaourt` via `sysusers.d` dans le PKGBUILD
      (au lieu du `useradd` manuel documenté dans le README).
- [ ] i18n : externaliser les chaînes, gérer le pluriel.
- [ ] Saisie mono-touche pour les prompts `[O/n]` (mode terminal raw).

## Amélioration LuaPilot (autre dépôt)

- [ ] Exposer proprement l'état « SIGINT reçu » pour que yaourt puisse afficher
      un message précis sur Ctrl+C et sortir avec le code 130.

## Commandes internes (non documentées dans -h)

- `-B <paquet>`            : build d'un seul paquet AUR (test du pipeline).
- `--debug-deps <pkg>`     : dépendances AUR directes d'un paquet.
- `--debug-resolve <pkg>`  : ordre de build récursif des dépendances AUR.
- 