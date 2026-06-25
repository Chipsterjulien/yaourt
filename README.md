# yaourt

Un frontend [pacman](https://wiki.archlinux.org/title/Pacman) avec support de
l'[AUR](https://wiki.archlinux.org/title/Arch_User_Repository), réécrit en Lua.

> **Statut : en développement (`0.1.0-dev`).**
> Le cœur fonctionne (passthrough pacman, récupération de PKGBUILD, affichage
> unifié des mises à jour dépôts + AUR, construction de paquets AUR), mais le
> projet est encore jeune et incomplet.

## À propos

Ce projet est une **réécriture en Lua** du yaourt original
([archlinuxfr/yaourt](https://github.com/archlinuxfr/yaourt)), aujourd'hui non
maintenu. L'objectif est d'en reprendre l'esprit — un assistant pacman/AUR
simple et lisible — sur une base de code moderne, en suivant une approche
« Strangler Fig Pattern » (figuier étrangleur) : tout ce qui n'est pas encore
porté nativement est délégué à `pacman`, puis remplacé progressivement.

Il s'appuie sur [LuaPilot](https://github.com/Chipsterjulien/luapilot_standalone),
un binaire Lua 5.5 autonome, et se distribue à terme sous forme d'un exécutable
unique.

## Fonctionnalités actuelles

- Délégation transparente à `pacman` pour les opérations standard (`-S`, `-Q`,
  `-R`, `-Sy`, …).
- `-G <paquet>` : récupération des fichiers de build AUR (clone/màj git).
- `-Syu` / `-Su` : affichage unifié des mises à jour (dépôts officiels + AUR),
  avec détection des révisions, des orphelins et des paquets périmés.
- Construction de paquets AUR : récupération, revue du PKGBUILD, compilation et
  installation. La compilation se fait toujours sous un utilisateur
  non privilégié dédié (`yaourt`), y compris lorsque le programme est lancé en
  root — `makepkg` n'étant jamais exécuté en root.

## Prérequis

- [Arch Linux](https://archlinux.org/) (ou dérivé compatible `pacman`).
- `pacman`, `git`, `base-devel` (pour `makepkg`).
- `pacman-contrib` (pour `checkupdates`).
- `package-query` (recherche AUR).

## Installation

> Le paquet n'est pas encore publié. En attendant, le projet se lance en mode
> développement avec le binaire LuaPilot placé dans `bin/` :
>
> ```sh
> ./bin/luapilot . <opération>
> ```

## Configuration

Une configuration est chargée depuis `~/.config/yaourt/config.toml`
(voir `config.example.toml` pour les options disponibles). En développement,
un fichier `cfg/config.toml` présent dans le dossier courant est détecté
automatiquement.

## Crédits et historique

yaourt a été créé par **Julien Mischkowitz** (`wain@archlinux.fr`) et **Tuxce**
(`tuxce.net@gmail.com`), avec de nombreux contributeurs, au sein du projet
[archlinuxfr/yaourt](https://github.com/archlinuxfr/yaourt). Ce dépôt en est une
réécriture indépendante, qui reprend le nom et l'esprit du projet d'origine
désormais abandonné. Voir le fichier [AUTHORS](AUTHORS) pour le détail.

## Licence

Distribué sous licence **GNU General Public License v3.0 ou ultérieure
(GPLv3+)**, comme le projet d'origine (sous GPL). Voir le fichier
[LICENSE](LICENSE).
