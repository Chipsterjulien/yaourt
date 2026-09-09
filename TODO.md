# TODO

## Fait (0.2.0 et après)

- [x] Recherche unifiée dépôts + AUR (`-Ss`), tri par votes, badges.
- [x] Limite configurable des résultats de recherche (`search_limit`).
- [x] Installation directe `-S` : routage dépôt/AUR, groupement des paquets
      dépôt, résolution récursive des dépendances AUR.
- [x] Dépendances : gestion des `provides` et des contraintes de version via
      `pacman -T` (local), `pacman -Sp` (dépôts), puis le RPC AUR
      `by=provides` avec sélection déterministe ou explicite (0.9.0).
- [x] `-Syu` approche « façon yaourt » : synchro réelle (`pacman -Sy` si demandé + transaction `-Sup`),
      sans passer par `checkupdates` (`pacman-contrib` n’est utilisé que par
      `yaourt -C` depuis la version 0.8.0).
- [x] Harmonisation `-S` / `-Syu` via `build.aur_many` (chemin de build unifié).
- [x] Sélection manuelle `[M]` dans `-Syu` : inclusion (numéros + plages) et
      exclusion (`^4` = tout sauf 4). Invite `[O/n/m]` seulement s'il y a de
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
- [x] `-Sw` / `--downloadonly` : délégation native pour les paquets dépôt et
      refus global, sans effet de bord, dès qu'une cible AUR est présente.
- [x] Split packages : plan global `pkgbase -> pkgname[]`, un seul clone/revue/
      build par `PackageBase`, installation limitée aux sous-paquets requis et
      conservation des raisons explicite/dépendance.
- [x] `CheckDepends` : résolution récursive des dépendances de test, depuis les
      dépôts ou l'AUR, et installation avant `makepkg` (0.7.0).
- [x] Nettoyage optionnel des dépendances de build nouvellement installées et
      devenues orphelines, sans toucher aux paquets antérieurs (0.11.0).
- [x] Cache de résolution strictement local à l'exécution : fiches AUR `/info`
      positives ou absentes réutilisées pendant le processus et résultats de
      `pacman -T` / `pacman -Sp` mémorisés uniquement pendant un même plan. Pas
      de cache disque ni de choix de fournisseur persistant (0.12.0).
- [x] `-C` / `--pacdiff` : gestion interactive des fichiers `.pacnew`,
      `.pacsave` et `.pacorig` via `pacdiff`, avec élévation limitée aux
      modifications et transmission de toutes ses options (0.8.0).
- [x] Paquets de développement : suivi sûr des références Git, Mercurial,
      Subversion et Bazaar via `--devel`, état validé uniquement après une
      installation réussie et aucune exécution du `PKGBUILD` pendant la
      détection (0.10.0).
- [x] Marquage `--asdeps` des dépendances AUR construites (un `-Rcs` de la cible
      les retire si elles deviennent orphelines).
- [x] Bilan typé (`build.result` : ok / refused / failed / install_failed /
      interrupted) ; `display.build_summary` groupe et fixe le code de sortie.
- [x] Suppression de `-B` (redondant avec `-S`).
- [x] Utilisateur de build via `sysusers.d` / `tmpfiles.d` dans le PKGBUILD.
- [x] Scripts de release (`build.sh` / `release.sh`) avec détection archi/binaire.
- [x] Migration Babet 2.9.1 : garde de version, API FS canoniques,
      `babet.spawn` avec flux hérités et tests dossier/embarqué.
- [x] Migration Babet 2.22.2 : contrats API réaudités, correction du nettoyage
      récursif `-Scc`, intégration HTTP `chunked` locale et test PTY réel.
- [x] Migration Babet 2.24.0 : runtime officiel complet, OpenSSL 3.5.8 et
      campagne yaourt validée en modes dossier et embarqué.
- [x] Releases 0.1.0 à 0.6.0 publiées, x86_64 + aarch64 ; jalons techniques
      0.7.0 à 0.11.0 tagués au fil de la feuille de route.
- [x] i18n extensible : catalogues gettext, détection POSIX de la locale,
      replis déterministes, pluriels, variables nommées, catalogues externes
      sûrs et 43 langues intégrées.

## Ligne directrice

Yaourt reste un **frontend pacman avec support AUR**, pas une plateforme de
construction générale. Une fonctionnalité entre dans la feuille de route si
elle remplit au moins un de ces critères : elle corrige une sémantique pacman,
elle sécurise une opération AUR ou elle simplifie un geste courant. La présence
d'une option dans Yay, Paru, Pikaur ou aurutils ne suffit pas à la justifier.

- Déléguer aux outils Arch officiels lorsqu'ils font déjà correctement le
  travail (`pacman`, `makepkg`, `pacdiff`).
- Préférer un comportement explicite à un état persistant difficile à invalider.
- Ne pas ajouter de démon, base de données, ordonnanceur de builds ou profil
  Babet propre à yaourt sans besoin mesuré.
- Chaque nouvelle fonction doit avoir des tests hors ligne et, lorsqu'elle
  modifie le système, un parcours réel sous Arch Linux.

## 0.12.0 — Corrections de l'audit validées

- [x] Approbations liées au contenu, revues refusées persistantes, erreurs/EOF bloquants.
- [x] Routage commun des options, refus des combinaisons non prises en charge.
- [x] Suppressions d'artefacts sous le compte de build et cache root cohérent.
- [x] Arrêt sur interruption ou contrôle incomplet ; remplacements pacman inclus.
- [x] Raisons explicites antérieures et contraintes de dépendances préservées.
- [x] Révisions VCS enregistrées par sous-paquet installé ; validation RPC avant cache.
- [x] `--needed` traité dans le plan et dans la transaction d'installation.
- [x] Tests de régression en modes dossier et embarqué, avec dépôts Git locaux.
- [x] Essais réels Arch des corrections et push du commit `13788c8` : mise à
      jour dépôts + AUR, 97 tests par mode, 13 régressions de revue par mode,
      plan de nettoyage avec pacman réel et contrôle des privilèges.

## 2.0.0 — Nouvelle génération Lua/Babet

- [x] Harmoniser la version du programme, du packaging et des catalogues.
- [x] Documenter la filiation avec le yaourt historique 1.9 et l'historique Git
      indépendant de cette réécriture.
- [x] Reprendre le socle fonctionnel validé dans la 0.12.0.
- [ ] Construire et vérifier les binaires x86_64 et aarch64 de la 2.0.0, puis
      publier le tag et les artefacts.

Les complétions, la consultation unifiée et le packaging AUR restent des
améliorations à réaliser. Le passage en 2.0.0 marque la nouvelle génération ;
il ne clôt pas la feuille de route.

## Suite — Consultation unifiée

- [ ] Étendre `-Si` aux paquets AUR tout en laissant les paquets des dépôts à
      `pacman`, y compris pour une liste de cibles mélangées.
- [ ] Étendre `-Qu` pour afficher les mises à jour dépôts + AUR sans rien
      synchroniser ni installer ; accepter `--devel` pour les révisions VCS.
- [ ] Préserver les formats sobres et les codes de sortie utiles aux scripts.

Ces deux opérations complètent le cœur « pacman + AUR » sans introduire de
nouveau sous-système.

## Suite — Complétions shell

- [ ] Fournir les complétions Bash, Zsh et Fish pour les opérations et options
      propres à yaourt, en réutilisant les mécanismes pacman lorsqu'ils sont
      disponibles.
- [ ] Installer ces fichiers depuis le PKGBUILD et les inclure dans les
      artefacts de source.
- [ ] Ne pas télécharger la liste entière de l'AUR à chaque tabulation et ne
      pas créer de cache global de noms de paquets dans cette première version.

## Suite — PKGBUILD local

- [ ] Construire et installer un `PKGBUILD` local avec ses dépendances dépôts
      et AUR en réutilisant le solveur, l'utilisateur de build, la revue et le
      nettoyage déjà existants.
- [ ] Garder une commande explicite et limitée à un répertoire local ; ne pas
      introduire de dépôt binaire local ni de chroot dans ce chantier.

## Packaging et validation de la distribution

- [ ] Deux paquets AUR : `yaourt` (compile tout depuis les sources, y compris
      le runtime) et `yaourt-bin` (récupère le binaire du runtime selon `$CARCH`
      depuis les releases). Pipeline du runtime déjà en place ; publication en
      attente de la réouverture de l'AUR.
- [ ] Revoir le `makedepends` du runtime dans le PKGBUILD (aujourd'hui il bloque
      `makepkg` car le runtime n'est pas un paquet installé : `--nodeps` requis).
- [ ] Tester l'installation du paquet (sysusers/tmpfiles appliqués par les hooks
      pacman, création auto de l'utilisateur `yaourt`).
- [ ] Établir une matrice de compatibilité des options pacman interceptées
      (`--needed`, `--ignore`, `--asdeps`, `--asexplicit`, `--noconfirm`,
      interruptions et échecs partiels) et ajouter les tests manquants.
- [ ] Rejouer les parcours réels `-S`, `-Syu`, `--devel`, split packages,
      fournisseurs, `-C`, nettoyage des dépendances et commandes de
      consultation avec le paquet installé, en x86_64 puis aarch64.

## Idées conditionnelles — seulement sur besoin réel

- Actualités Arch avant `-Syu` : utile pour les mises à jour manuelles, mais à
  ajouter uniquement si l'intégration reste facultative et ne bloque pas la
  mise à jour lorsque le flux est indisponible.
- Diagnostic assisté des clés PGP inconnues : expliquer la clé et la commande
  à employer peut être utile ; l'import automatique n'est pas souhaité.
- Dépôt binaire local ou builds en chroot : à reconsidérer uniquement si des
  utilisateurs en ont réellement besoin. Paru et aurutils couvrent déjà très
  bien ce cas avancé.

## Explicitement hors feuille de route

- Cache disque du graphe de dépendances ou mémorisation implicite des choix de
  fournisseurs : invalidation fragile pour un gain faible.
- Menus propres à un éditeur, gestionnaire de fichiers ou interface graphique :
  la revue séquentielle et le diff actuels restent portables et prévisibles.
- Vote, dévote et commentaires AUR : impliquent des identifiants et n'améliorent
  ni l'installation ni la sécurité.
- Builds parallèles et ordonnanceur maison : complexité, sorties entremêlées et
  risques de concurrence disproportionnés pour l'usage visé.
- Import automatique de clés PGP ou contournement automatique des contrôles de
  signature.
- `-Sw` AUR tant qu'une sémantique non ambiguë entre clone, sources et paquet
  construit n'apporte pas un besoin utilisateur démontré.

## Commandes internes (non documentées dans -h)

- `--debug-deps <pkg>`     : dépendances AUR directes d'un paquet.
- `--debug-resolve <pkg>`  : ordre de build récursif des dépendances AUR.
