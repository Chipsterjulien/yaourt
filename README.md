# yaourt

Un frontend [pacman](https://wiki.archlinux.org/title/Pacman) avec support de
l'[AUR](https://wiki.archlinux.org/title/Arch_User_Repository), réécrit en Lua.

> **Statut : jeune mais utilisable au quotidien (`0.2.0`).**
> La recherche, l'installation (dépôts et AUR avec résolution récursive des
> dépendances), la mise à jour unifiée et le nettoyage du cache fonctionnent.
> Le projet reste en évolution.

## À propos

Ce projet est une **réécriture en Lua** du yaourt original
([archlinuxfr/yaourt](https://github.com/archlinuxfr/yaourt)), aujourd'hui non
maintenu. L'objectif est d'en reprendre l'esprit — un assistant pacman/AUR
simple et lisible — sur une base de code moderne, en suivant une approche
« Strangler Fig Pattern » (figuier étrangleur) : tout ce qui n'est pas encore
porté nativement est délégué à `pacman`, puis remplacé progressivement.

Il s'appuie sur [LuaPilot](https://github.com/Chipsterjulien/luapilot_standalone),
un binaire Lua 5.5 autonome, et se distribue sous forme d'un exécutable unique.

## Fonctionnalités

- Délégation transparente à `pacman` pour les opérations standard (`-Q`, `-R`,
  `-Sy`, …).
- **`-Ss <terme>`** : recherche unifiée dépôts officiels + AUR, triée par votes,
  avec un nombre de résultats par section limité et configurable.
- **`-S <paquet>…`** : installation depuis les dépôts ou l'AUR, avec
  **résolution récursive des dépendances AUR**, installation automatique des
  dépendances des dépôts, et prise en charge des paquets virtuels (`provides`)
  et des contraintes de version.
- **`-Syu` / `-Su`** : mise à jour unifiée (dépôts + AUR), avec détection des
  révisions, des orphelins et des paquets périmés. L'option `[M]` permet de
  choisir à la carte les paquets AUR à mettre à jour.
- **`-Sc` / `-Scc`** : nettoyage du cache de build (doux : sources et artefacts ;
  complet : tous les dépôts clonés), en complément du cache pacman.
- **`-G <paquet>…`** : récupération des fichiers de build AUR (clone/màj git).
- **Revue avant compilation** : affichage du PKGBUILD au premier clone, et du
  **diff des modifications** (PKGBUILD, `.install`, patches…) lors d'une mise à
  jour, avant de construire.
- La compilation se fait toujours sous un utilisateur non privilégié dédié
  (`yaourt`), y compris lorsque le programme est lancé en root — `makepkg`
  n'étant jamais exécuté en root.

## Prérequis

- [Arch Linux](https://archlinux.org/) (ou dérivé compatible `pacman`).
- `pacman`, `git`, `base-devel` (pour `makepkg`).
- `package-query` (recherche AUR).
- `sudo` (opérations pacman lorsqu'il n'est pas lancé en root).

## Installation

### Binaire précompilé (recommandé)

Téléchargez le binaire de votre architecture depuis la
[page des releases](https://github.com/Chipsterjulien/yaourt/releases),
rendez-le exécutable et installez-le :

```sh
chmod +x yaourt-0.2.0-x86_64
sudo install -Dm755 yaourt-0.2.0-x86_64 /usr/bin/yaourt
```

Architectures fournies : `x86_64`, `aarch64`. Les binaires sont autonomes
(runtime LuaPilot embarqué) ; vous pouvez vérifier leur intégrité avec les
fichiers `.sha256` joints.

#### Utilisateur de build

yaourt compile les paquets AUR sous un utilisateur système dédié `yaourt`.
S'il n'existe pas encore, créez-le :

```sh
sudo useradd --system --home-dir /var/cache/yaourt --create-home \
  --shell /usr/sbin/nologin --comment "yaourt AUR build user" yaourt
```

### En mode développement

Avec le binaire LuaPilot placé dans `bin/` :

```sh
./bin/luapilot . <opération>
```

## Configuration

Une configuration est chargée depuis `~/.config/yaourt/config.toml`
(voir [`config.example.toml`](config.example.toml) pour les options
disponibles, dont `search_limit` pour le nombre de résultats de recherche).
En développement, un fichier `cfg/config.toml` présent dans le dossier courant
est détecté automatiquement.

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
