# Todo list

[ ] passer -c à makepkg + supprimer le .pkg.tar.zst après install réussie, sans toucher au clone git
[ ] Packaging : créer l'utilisateur système `yaourt` (en temps que root) via sysusers.d dans le PKGBUILD (utilisateur dédié, sans shell de login, pour compiler les paquets AUR quand yaourt tourne en root sans sudo).
[ ] saisie mono-touche pour les prompts [O/n] (sans Entrée) — nécessite un mode terminal raw via stty avec restauration sûre, car luapilot n'expose pas de readchar.
[ ] internationalisation (i18n) — externaliser toutes les chaînes et gérer le pluriel proprement (gettext/ngettext), le jour venu ; l'internalisation de checkupdates (base de sync temporaire) pour supprimer la dépendance à pacman-contrib
[ ] la revue des autres fichiers d'un paquet AUR (.install, patches, .sh) en plus du seul PKGBUILD
[ ] diff de PKGBUILD en mise à jour (montrer seulement ce qui a changé depuis la dernière validation)
