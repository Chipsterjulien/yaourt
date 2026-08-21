# Traduire yaourt

yaourt utilise des catalogues PO GNU gettext, avec un fichier par locale dans
`po/`. Le code de l'application ne manipule que des clés sémantiques stables :
l'ajout d'une langue ne doit créer aucune condition propre à cette langue dans
`main.lua` ou `lib/`.

Le catalogue anglais (`po/en.po`) définit les textes sources et le vocabulaire
du projet actuel. Le catalogue français (`po/fr.po`) est le second catalogue de
référence. Les traductions de l'ancien yaourt en shell peuvent aider les
traducteurs, mais leur terminologie ne fait pas autorité pour cette réécriture.

## Prérequis

- Python 3 ;
- GNU gettext (`msginit` et `msgfmt`) ;
- Babet 2.22.2 ou plus récent pour exécuter toute la suite de tests.

## Ajouter une locale

Partir du modèle généré :

```sh
msginit \
  --input=po/yaourt.pot \
  --locale=xx_YY \
  --output-file=po/xx_YY.po
```

Utiliser le nom de locale standard le plus court qui identifie la traduction.
Ajouter une région seulement lorsque la langue régionale diffère réellement,
comme pour `pt_BR` ou `zh_TW`.

Compléter les en-têtes PO habituels ainsi que ceux propres à yaourt :

```po
"Language: xx_YY\n"
"Language-Team: LANGUE <CONTACT>\n"
"Plural-Forms: nplurals=2; plural=(n != 1);\n"
"X-Yaourt-Yes: o,oui\n"
"X-Yaourt-No: n,non\n"
"X-Yaourt-Manual: m,manuel\n"
"X-Yaourt-Aliases: xx\n"
```

`X-Yaourt-Yes`, `X-Yaourt-No` et `X-Yaourt-Manual` définissent des réponses
localisées séparées par des virgules ; leur première valeur doit correspondre
à la lettre traduite dans les messages d'invite. `X-Yaourt-Aliases` est
facultatif et énumère, également avec des
virgules, les autres noms de la locale. Il sert par exemple à faire prendre en
charge `cs` par le catalogue régional `cs_CZ`. Les réponses anglaises
universelles `y`, `yes`, `n`, `no`, `m` et `manual` restent acceptées dans
toutes les langues.

Traduire toutes les entrées et retirer les marqueurs `fuzzy`. Le compilateur
refuse les messages vides ou supplémentaires, les entrées manquantes, les
déclarations de pluriel invalides et les variables différentes du catalogue
anglais.

## Variables et pluriels

Les variables nommées comme `{package}`, `{version}` ou `{count}` doivent être
conservées exactement. Leur position peut changer selon la grammaire de la
langue cible :

```po
msgctxt "update.available"
msgid "{package}: {current} -> {target}"
msgstr "… {package} … {target} … {current} …"
```

Les messages pluriels doivent fournir le nombre de formes déclaré par l'en-tête
`Plural-Forms` du catalogue. yaourt évalue cette expression avec son propre
analyseur borné ; le contenu d'un catalogue reste une donnée et n'est jamais
exécuté comme du code Lua.

## Aide des commandes

La syntaxe affichée par `yaourt --help` est volontairement absente des
catalogues. Elle est définie une seule fois dans `lib/help.lua` ; les fichiers
PO ne contiennent que les descriptions courtes `help.*` placées en regard des
commandes. Les commandes restent ainsi reconnaissables et alignées dans toutes
les langues.

Conserver chaque message d'aide sur une seule ligne. Ne pas ajouter de commande
`yaourt` dans une description et ne pas traduire les métavariables telles que
`<package>` : elles sont affichées par le programme. Le compilateur des
catalogues refuse ces éléments structurels s'ils apparaissent dans une
description. Conserver également les marqueurs structurels présents dans la
description source : les parenthèses, `|`, `[M]` et les exemples d'options
comme `-Q`, `-R` et `-Sy`. Les parenthèses CJK pleine largeur sont acceptées.

## Valider et régénérer

Après toute modification d'un fichier PO, régénérer les catalogues intégrés et
le modèle :

```sh
python3 tools/compile_catalogs.py
```

Valider ensuite la locale modifiée puis toute la suite hors ligne :

```sh
msgfmt --check --check-format \
  -o /tmp/yaourt-xx_YY.mo po/xx_YY.po

BABET=/chemin/vers/babet-2.22.2-linux-x86_64 ./run_tests.sh
```

Valider dans Git `po/xx_YY.po`, le fichier `po/yaourt.pot` régénéré et
`lib/i18n_catalogs.lua`. Ne jamais modifier directement
`lib/i18n_catalogs.lua` : c'est un artefact déterministe qui ne contient que des
données.

Pour tester la détection de la locale :

```sh
LANGUAGE=xx_YY ./bin/babet . --help
```

Il est également possible de définir `language = "xx_YY"` dans
`~/.config/yaourt/config.toml`.

## Installer un catalogue externe

Un catalogue externe permet d'actualiser une traduction sans reconstruire
yaourt :

```sh
msgfmt -o yaourt.mo po/xx_YY.po
sudo install -Dm644 yaourt.mo \
  /usr/share/locale/xx_YY/LC_MESSAGES/yaourt.mo
```

Pour un essai local, reproduire la même arborescence gettext sous un répertoire
temporaire et l'indiquer dans `YAOURT_LOCALEDIR`. Un catalogue externe remplace
le catalogue intégré message par message ; une entrée absente se replie sur le
catalogue intégré puis sur l'anglais.

## Relire un catalogue initial

Les catalogues initiaux autres que l'anglais et le français proviennent d'une
traduction assistée localement et demandent volontairement une relecture par un
locuteur natif. Une fois la relecture terminée :

1. actualiser `Last-Translator` et `PO-Revision-Date` ;
2. remplacer la mention de traduction assistée dans `Language-Team` par une
   équipe ou un contact réel ;
3. retirer des commentaires d'en-tête la demande de relecture ;
4. exécuter les commandes de validation ci-dessus.

La relecture doit porter sur le sens et le ton, pas seulement sur la syntaxe.
Conserver le vocabulaire du yaourt actuel, notamment la distinction entre les
dépôts officiels, les paquets AUR, les paquets orphelins, les paquets périmés,
les fichiers de construction et le cache de construction.
