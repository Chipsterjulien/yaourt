# TODO

## Fait (0.2.0 et après)

- [x] Recherche unifiée dépôts + AUR (`-Ss`), tri par votes, badges.
- [x] Limite configurable des résultats de recherche (`search_limit`).
- [x] Installation directe `-S` : routage dépôt/AUR, groupement des paquets
      dépôt, résolution récursive des dépendances AUR.
- [x] Dépendances : gestion des `provides` et des contraintes de version
      (`pacman -T` local + `pacman -Sp` dépôts).
- [x] `-Syu` approche « façon yaourt » : synchro réelle (`pacman -Sy` + `-Qu`),
      suppression de la dépendance `pacman-contrib`.
- [x] Harmonisation `-S` / `-Syu` via `build.aur` (chemin de build unifié).
- [x] Sélection manuelle `[M]` dans `-Syu` : inclusion (numéros + plages) et
      exclusion (`^4` = tout sauf 4). Invite `[O/n/M]` seulement s'il y a de
      l'AUR ; saisie vide = rien.
- [x] Diff des fichiers de build (PKGBUILD, .install, patches) à la mise à jour.
- [x] Revue de TOUS les fichiers versionnés au premier clone, ouverts un par un
      (sécurité : .install, patches, scripts).
- [x] Bannière de build (nom + version installée -> cible).
- [x] Nettoyage du cache `-Sc` / `-Scc` (doux / complet).
- [x] Factorisation : `display.lua` (repo_color, build_summary), `util.isset`.
- [x] En-têtes SPDX GPL-3.0-or-later sur tous les fichiers.
- [x] Nettoyage des paquets résiduels avant build (`clean_stale`) : évite le
      blocage « paquet déjà compilé » après une interruption.
- [x] Détection propre du Ctrl+C : `util.passthrough` lit le signal (128+N),
      `util.is_interrupted`, message « interrompu » distinct, code de sortie 130.
- [x] Transmission des modificateurs en `-S` : `-f` -> makepkg (force rebuild
      cible), `--needed` -> pacman + makepkg, flags inconnus -> pacman (dépôts).
- [x] Marquage `--asdeps` des dépendances AUR construites (un `-Rcs` de la cible
      les retire si elles deviennent orphelines).
- [x] Bilan typé (`build.result` : ok / refused / failed / install_failed /
      interrupted) ; `display.build_summary` groupe et fixe le code de sortie.
- [x] Suppression de `-B` (redondant avec `-S`).
- [x] Utilisateur de build via `sysusers.d` / `tmpfiles.d` dans le PKGBUILD.
- [x] Scripts de release (`build.sh` / `release.sh`) avec détection archi/binaire.
- [x] Deux releases publiées (0.1.0, 0.2.0), x86_64 + aarch64.

## Packaging (prioritaire — runtime babet en place)

- [ ] Deux paquets AUR : `yaourt` (compile tout depuis les sources, y compris
      le runtime) et `yaourt-bin` (récupère le binaire du runtime selon `$CARCH`
      depuis les releases). Pipeline du runtime déjà en place.
- [ ] Revoir le `makedepends` du runtime dans le PKGBUILD (aujourd'hui il bloque
      `makepkg` car le runtime n'est pas un paquet installé : `--nodeps` requis).
- [ ] Tester l'installation du paquet (sysusers/tmpfiles appliqués par les hooks
      pacman, création auto de l'utilisateur `yaourt`).

## Robustesse

- [ ] Nettoyage optionnel des dépendances de build devenues orphelines après
      compilation.
- [ ] Cache des résolutions (aur.info / pacman répétés) pour les gros graphes.

## Finitions

- [ ] i18n : externaliser les chaînes, gérer le pluriel.
- [ ] Mode de revue avancé optionnel (ex. onglets vim `-p`) via la config, en
      gardant l'ouverture séquentielle par défaut pour les néophytes.
- [ ] `-w` / `--downloadonly` côté AUR : sens à définir (sources seules ?
      build sans installation ?) — laissé de côté volontairement.

## Commandes internes (non documentées dans -h)

- `--debug-deps <pkg>`     : dépendances AUR directes d'un paquet.
- `--debug-resolve <pkg>`  : ordre de build récursif des dépendances AUR.
