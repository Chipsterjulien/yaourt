# yaourt

[English](README.md) | **Français**

Un frontend [pacman](https://wiki.archlinux.org/title/Pacman) avec support de
l'[AUR](https://wiki.archlinux.org/title/Arch_User_Repository), réécrit en Lua.

> **Statut : jeune mais utilisable au quotidien (`0.6.0`).**
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

Il s'appuie sur [Babet](https://github.com/Chipsterjulien/babet) **2.24.0 ou
plus récent**,
un binaire Lua 5.5 autonome, et se distribue sous forme d'un exécutable unique.
Au démarrage comme pendant la construction, yaourt vérifie la version du
runtime et refuse une version antérieure avec un diagnostic explicite.
Ce runtime conserve notamment la lecture fiable des réponses HTTP `chunked` de
l'AUR et le transfert/restauration du terminal pour les commandes interactives
lancées avec `babet.spawn`, comme `pacman` et `makepkg`. Il apporte aussi le
build officiel de production avec OpenSSL 3.5.8 et les validations de release
ajoutées dans Babet 2.24. yaourt utilise le runtime Babet officiel complet, sans
profil de fonctionnalités particulier.

## Fonctionnalités

- Délégation transparente à `pacman` pour les opérations standard (`-Q`, `-R`,
  `-Sy`, …).
- **`-Ss <terme>`** : recherche unifiée dépôts officiels + AUR, triée par votes,
  avec un nombre de résultats par section limité et configurable.
- **`-S <paquet>…`** : installation depuis les dépôts ou l'AUR, avec
  **résolution récursive des dépendances AUR**, installation automatique des
  dépendances des dépôts, et prise en charge des paquets virtuels (`provides`)
  et des contraintes de version.
- **Split packages** : les cibles qui partagent le même `PackageBase` AUR ne
  sont clonées, examinées et construites qu'une seule fois. yaourt installe
  uniquement les sous-paquets demandés ou requis — pas tous les artefacts du
  `PKGBUILD` — tout en préservant leur raison explicite ou dépendance.
- **`-Sw <paquet>…` / `-S --downloadonly <paquet>…`** : mode natif de pacman
  pour télécharger sans installer les paquets des dépôts. Toute commande qui
  contient une cible AUR est refusée en entier avant téléchargement ou build.
- **`-Syu` / `-Su`** : mise à jour unifiée (dépôts + AUR), avec détection des
  révisions, des orphelins et des paquets périmés. L'option `[M]` permet de
  choisir à la carte les paquets AUR à mettre à jour : inclusion (`1 3 5`,
  `1-4`) et exclusion (`^4` pour tout sauf le 4).
- **`-Sc` / `-Scc`** : nettoyage du cache de build (doux : sources et artefacts ;
  complet : tous les dépôts clonés), en complément du cache pacman.
- **`-G <paquet>…`** : récupération des fichiers de build AUR (clone/màj git).
- **Revue avant compilation** : au premier clone, tous les fichiers versionnés
  du dépôt (PKGBUILD, `.install`, patches, scripts…) sont présentés un par un
  dans l'éditeur ; lors d'une mise à jour, c'est le **diff** des modifications
  depuis la version précédente qui est affiché. Rien n'est construit sans
  validation.
- Les dépendances AUR tirées automatiquement sont marquées comme dépendances
  (`--asdeps`) : un `pacman -Rcs` de la cible les retire si elles deviennent
  orphelines.
- La compilation se fait toujours sous un utilisateur non privilégié dédié
  (`yaourt`), y compris lorsque le programme est lancé en root — `makepkg`
  n'étant jamais exécuté en root.
- **Interface internationalisée** : 43 locales intégrées, détection automatique
  de la locale POSIX, replis régionaux, pluriels sûrs et catalogues GNU gettext
  externes, sans branche propre à une langue dans le code métier.

### Revue de sécurité des fichiers AUR

Avant chaque construction AUR, yaourt adapte la revue au contenu disponible
dans son cache de build :

1. **Premier clone dans le cache de yaourt** : il n'existe aucune ancienne
   révision permettant de produire un diff. Tous les fichiers versionnés du
   dépôt sont donc ouverts **un par un** dans l'éditeur configuré : `PKGBUILD`,
   fichiers `.install`, patches, scripts locaux, etc. Ils sont présentés pour
   examen et n'ont pas besoin d'être modifiés.
2. **Dépôt déjà présent et modifié** : yaourt affiche dans le terminal le diff
   complet entre l'ancien et le nouveau commit, pour tous les fichiers suivis.
3. **Dépôt inchangé** : aucune nouvelle revue n'est nécessaire et la
   construction peut continuer directement.

Le « premier clone » concerne le cache de yaourt, pas l'état d'installation du
paquet. Un paquet déjà installé peut donc déclencher une revue complète s'il a
été installé avec un autre assistant AUR, si le cache utilise un nouvel
emplacement ou si le dépôt cloné a été supprimé. En particulier, `-Scc`
supprime tous les dépôts du cache : la prochaine construction de chacun d'eux
sera de nouveau considérée comme un premier clone.

Cette revue porte volontairement sur tous les fichiers suivis : un fichier
`.install` peut exécuter des commandes avec les droits root, tandis qu'un patch
ou un script local peut modifier les sources construites. Après la présentation
ou le diff, yaourt demande toujours confirmation avant de lancer la
construction.

## Prérequis

- [Arch Linux](https://archlinux.org/) (ou dérivé compatible `pacman`).
- `pacman`, `git`, `base-devel` (pour `makepkg`).
- `sudo` (opérations pacman lorsqu'il n'est pas lancé en root).
- Python 3 pour construire depuis les sources ; GNU gettext pour valider ou
  installer les catalogues externes. Le binaire autonome n'en dépend pas.

## Installation

### Binaire précompilé (recommandé)

Téléchargez le binaire de votre architecture depuis la
[page des releases](https://github.com/Chipsterjulien/yaourt/releases),
rendez-le exécutable et installez-le :

```sh
chmod +x yaourt-0.6.0-x86_64
sudo install -Dm755 yaourt-0.6.0-x86_64 /usr/bin/yaourt
```

Architectures fournies : `x86_64`, `aarch64`. Les binaires sont autonomes
(runtime Babet embarqué) ; vous pouvez vérifier leur intégrité avec les
fichiers `.sha256` joints.

#### Utilisateur de build

yaourt compile les paquets AUR sous un utilisateur système dédié `yaourt`
(makepkg n'est jamais exécuté en root). **Lors d'une installation par le
paquet, cet utilisateur et son répertoire de cache sont créés automatiquement**
(via `sysusers.d` / `tmpfiles.d`), sans intervention.

Pour une installation hors paquet (binaire précompilé déposé à la main),
créez-le vous-même :

```sh
sudo useradd --system --home-dir /var/cache/yaourt --create-home \
  --shell /usr/sbin/nologin --comment "yaourt AUR build user" yaourt
```

### En mode développement

Avec un binaire Babet 2.24.0 (minimum) placé dans `bin/` :

```sh
./bin/babet . <opération>
```

Le script `build.sh` accepte aussi un chemin explicite :

```sh
BABET=/chemin/vers/babet-2.24.0-linux-x86_64 ./build.sh
```

## Tests

La suite hors ligne vérifie les helpers de processus et de fichiers avec le
vrai runtime Babet, le plan de construction et la sélection des artefacts des
split packages, exerce le client AUR sur un serveur HTTP local avec des réponses
`chunked`, teste la chaîne interactive parent/enfant sous un véritable
pseudo-terminal, puis contrôle les modes dossier et embarqué et construit le
binaire final. Les tests d'intégration utilisent la bibliothèque standard de
Python 3 et GNU gettext (`msgfmt`) pour valider chaque catalogue :

```sh
BABET=/chemin/vers/babet-2.24.0-linux-x86_64 ./run_tests.sh
```

Un contrôle facultatif du RPC AUR peut être ajouté :

```sh
YAOURT_NETWORK_TESTS=1 \
  BABET=/chemin/vers/babet-2.24.0-linux-x86_64 \
  ./run_tests.sh
```

Les parcours de mise à jour unifiée et de construction AUR interactive ont
également été validés manuellement sous Arch Linux. L'installation du paquet
avec `sysusers.d` et `tmpfiles.d` reste suivie dans le fichier [TODO](TODO.md).

## Configuration

Une configuration est chargée depuis `~/.config/yaourt/config.toml`
(voir [`config.example.fr.toml`](config.example.fr.toml) pour l'exemple commenté
en français, ou [`config.example.toml`](config.example.toml) en anglais). Lors
d'un `-Syu`, `list_aur = "notable"` affiche par défaut les paquets orphelins,
périmés ou non gérés par l'AUR. La valeur `"all"` affiche la liste complète et
`false` masque le récapitulatif ; l'ancienne valeur `true` reste acceptée comme
alias de `"all"`. L'option `search_limit` règle le nombre de résultats de
recherche.

### Langue de l'interface

`language = "auto"` est la valeur par défaut. yaourt consulte `LANGUAGE`,
`LC_ALL`, `LC_MESSAGES`, puis `LANG`. Une locale peut aussi être imposée, par
exemple avec `language = "pt_BR"`. Les formes POSIX et BCP 47 sont acceptées ;
une locale régionale se replie sur sa langue de base, puis sur l'anglais
(`pt_BR.UTF-8` → `pt_BR` → `pt` → `en`). `C` et `POSIX` sélectionnent
l'anglais.

Les 43 locales intégrées sont :

`ar`, `ast`, `bg`, `bn`, `br`, `ca`, `cs_CZ`, `da`, `de`, `el`, `en`, `eo`,
`es`, `es_419`, `fa`, `fi`, `fr`, `he`, `hi`, `hu`, `id`, `is`, `it`, `ja`,
`ko`, `lt`, `nb`, `nl_NL`, `pl`, `pt`, `pt_BR`, `ro`, `ru`, `sk`, `sl`, `sr`,
`sv`, `th`, `tr`, `uk`, `vi`, `zh_CN` et `zh_TW`.

Les catalogues anglais et français définissent le vocabulaire du projet actuel
et le conservent. Les autres catalogues sont des traductions initiales complètes
produites localement et portent volontairement la mention qu'une relecture par
des locuteurs natifs est nécessaire. Les contrôles garantissent déjà la
complétude, les variables nommées et les formes de pluriel déclarées ; les
améliorations linguistiques restent les bienvenues.

yaourt lit aussi les fichiers externes `yaourt.mo` selon l'arborescence gettext
standard, d'abord dans les dossiers indiqués par `YAOURT_LOCALEDIR`, puis dans
`$XDG_DATA_HOME/locale`, `/usr/local/share/locale` et `/usr/share/locale`. Un
catalogue externe remplace la traduction embarquée et se replie sur celle-ci
pour les messages manquants. Il est analysé comme une donnée et n'est jamais
exécuté comme du code Lua.

Pour ajouter ou relire une langue sans toucher à la logique métier, voir
[TRANSLATING.fr.md](TRANSLATING.fr.md). Les fichiers `po/*.po` sont la source de
vérité ; `python3 tools/compile_catalogs.py` régénère le module embarqué sûr et
le modèle `po/yaourt.pot`.

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
