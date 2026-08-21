# Translating yaourt

yaourt uses GNU gettext PO catalogues, with one file per locale under `po/`.
The application code only refers to stable semantic keys: adding a language
must not add language-specific conditions to `main.lua` or `lib/`.

The English catalogue (`po/en.po`) defines the source text and the current
project's vocabulary. The French catalogue (`po/fr.po`) is the second reference
catalogue. Translations from the historical shell version of yaourt may be
useful to translators, but their terminology is not authoritative for this
rewrite.

## Requirements

- Python 3;
- GNU gettext (`msginit` and `msgfmt`);
- Babet 2.22.2 or newer to run the full test suite.

## Adding a locale

Start from the generated template:

```sh
msginit \
  --input=po/yaourt.pot \
  --locale=xx_YY \
  --output-file=po/xx_YY.po
```

Use the shortest standard locale name that identifies the translation. Add a
region only when the regional language differs materially, as with `pt_BR` or
`zh_TW`.

Complete the usual PO headers and these yaourt-specific headers:

```po
"Language: xx_YY\n"
"Language-Team: LANGUAGE <CONTACT>\n"
"Plural-Forms: nplurals=2; plural=(n != 1);\n"
"X-Yaourt-Yes: y,yes\n"
"X-Yaourt-No: n,no\n"
"X-Yaourt-Manual: m,manual\n"
"X-Yaourt-Aliases: xx\n"
```

`X-Yaourt-Yes`, `X-Yaourt-No`, and `X-Yaourt-Manual` define comma-separated
localized answers. Their first value should match the letter translated in the
prompt messages.
`X-Yaourt-Aliases` is optional and lists alternate locale names, also separated
by commas. It is useful when a regional catalogue should handle the base locale
(for example, the `cs_CZ` catalogue declares `cs`). The universal English
answers `y`, `yes`, `n`, `no`, `m`, and `manual` remain accepted in every
language.

Translate every entry and remove any `fuzzy` marker. The compiler rejects empty
or extra messages, missing entries, invalid plural declarations, and variables
that do not match the English catalogue.

## Variables and plurals

Named placeholders such as `{package}`, `{version}`, or `{count}` must be kept
exactly as written. Their position may change to follow the grammar of the
target language:

```po
msgctxt "update.available"
msgid "{package}: {current} -> {target}"
msgstr "… {package} … {target} … {current} …"
```

Plural entries must contain the number of forms declared by the catalogue's
`Plural-Forms` header. yaourt evaluates this expression with its own bounded
parser; catalogue contents are data and are never executed as Lua code.

## Command help

The command syntax displayed by `yaourt --help` is deliberately absent from
the catalogues. It is defined once in `lib/help.lua`; PO files contain only the
short `help.*` descriptions placed next to those commands. This keeps every
command recognizable and aligned in all languages.

Keep each help message on one line. In a help description, do not add a
`yaourt` command or translate metavariables such as `<package>`: they are
rendered by the program. The catalogue compiler rejects those structural
elements if they leak into a description. Preserve the structural markers
present in the source description as well: parentheses, `|`, `[M]`, and option
examples such as `-Q`, `-R`, and `-Sy`. Full-width CJK parentheses are accepted.

## Validate and regenerate

After editing any PO file, regenerate the embedded catalogues and template:

```sh
python3 tools/compile_catalogs.py
```

Then validate the edited locale and run the complete offline suite:

```sh
msgfmt --check --check-format \
  -o /tmp/yaourt-xx_YY.mo po/xx_YY.po

BABET=/path/to/babet-2.22.2-linux-x86_64 ./run_tests.sh
```

Commit `po/xx_YY.po`, the regenerated `po/yaourt.pot`, and
`lib/i18n_catalogs.lua`. Do not edit `lib/i18n_catalogs.lua` directly: it is a
deterministic, data-only build artifact.

To test the catalogue through locale detection:

```sh
LANGUAGE=xx_YY ./bin/babet . --help
```

Alternatively, set `language = "xx_YY"` in `~/.config/yaourt/config.toml`.

## Installing an external catalogue

External catalogues can update a translation without rebuilding yaourt:

```sh
msgfmt -o yaourt.mo po/xx_YY.po
sudo install -Dm644 yaourt.mo \
  /usr/share/locale/xx_YY/LC_MESSAGES/yaourt.mo
```

For local testing, use the same gettext directory layout below a temporary
directory and point `YAOURT_LOCALEDIR` to it. An external catalogue overrides
its embedded counterpart message by message; missing messages fall back to the
embedded catalogue and then to English.

## Reviewing an initial catalogue

The initial catalogues other than English and French were produced with local
machine-assisted translation and intentionally request native review. When a
catalogue has been reviewed:

1. update `Last-Translator` and `PO-Revision-Date`;
2. replace the machine-assisted `Language-Team` note with a real team or
   contact;
3. remove the review note from the header comments;
4. run the validation commands above.

Review meaning and tone, not only syntax. Preserve yaourt's current terms,
especially the distinction between official repositories, AUR packages,
orphaned packages, out-of-date packages, build files, and the build cache.
