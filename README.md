# yaourt

**English** | [Français](README.fr.md)

A [pacman](https://wiki.archlinux.org/title/Pacman) frontend with
[AUR](https://wiki.archlinux.org/title/Arch_User_Repository) support, rewritten
in Lua.

> **Status: young, but suitable for daily use (`0.5.1`).**
> Search, installation (official repositories and AUR with recursive dependency
> resolution), unified upgrades, and cache cleanup are functional. The project
> is still evolving.

## About

This project is a **Lua rewrite** of the original yaourt
([archlinuxfr/yaourt](https://github.com/archlinuxfr/yaourt)), which is no longer
maintained. Its goal is to preserve the spirit of the original project—a simple,
readable pacman/AUR helper—on top of a modern codebase. It follows a Strangler
Fig approach: features that have not yet been ported natively are delegated to
`pacman`, then progressively replaced.

yaourt relies on [Babet](https://github.com/Chipsterjulien/babet) **2.22.2 or
newer**, a self-contained Lua 5.5 runtime, and is distributed as a single
executable. Both at startup and during builds, yaourt checks the runtime version
and rejects older versions with an explicit diagnostic.

This minimum version notably provides reliable handling of AUR HTTP `chunked`
responses and correct terminal transfer/restoration for interactive commands
started with `babet.spawn`, such as `pacman` and `makepkg`.

## Features

- Transparent delegation to `pacman` for standard operations (`-Q`, `-R`,
  `-Sy`, …).
- **`-Ss <term>`**: unified search across official repositories and the AUR,
  sorted by votes, with a configurable result limit for each section.
- **`-S <package>…`**: installation from official repositories or the AUR,
  including **recursive AUR dependency resolution**, automatic installation of
  repository dependencies, virtual package (`provides`) support, and version
  constraints.
- **`-Sw <package>…` / `-S --downloadonly <package>…`**: pacman's native
  download-only mode for repository packages. Commands containing an AUR
  target are rejected as a whole before any download or build.
- **`-Syu` / `-Su`**: unified upgrades for official repositories and the AUR,
  with revision, orphan, and out-of-date detection. The `[M]` option provides
  manual AUR package selection, with inclusion (`1 3 5`, `1-4`) and exclusion
  (`^4` for everything except item 4).
- **`-Sc` / `-Scc`**: build-cache cleanup in addition to pacman's cache. Soft
  cleanup removes sources and artifacts; full cleanup removes every cloned
  repository.
- **`-G <package>…`**: retrieve AUR build files (Git clone/update).
- **Pre-build review**: on the first clone, every version-controlled file in
  the repository (`PKGBUILD`, `.install` files, patches, scripts, etc.) is shown
  sequentially in the configured editor. On updates, yaourt displays the
  complete diff since the previous revision. Nothing is built without user
  confirmation.
- Automatically pulled AUR dependencies are marked with `--asdeps`, allowing
  `pacman -Rcs` on the requested package to remove them if they become orphaned.
- AUR packages are always built as a dedicated, unprivileged `yaourt` user,
  even when the program itself is started as root. `makepkg` is never run as
  root.
- **Internationalized interface:** 43 built-in locales, automatic POSIX locale
  detection, regional fallback, safe plural rules, and external GNU gettext
  catalogues without language-specific branches in the business code.

### AUR file security review

Before each AUR build, yaourt adapts the review to the state of its build cache:

1. **First clone in yaourt's cache:** there is no previous revision from which
   to produce a diff. Every version-controlled file is therefore opened **one
   at a time** in the configured editor: `PKGBUILD`, `.install` files, patches,
   local scripts, and so on. The files are presented for inspection and do not
   need to be modified.
2. **Repository already cached and updated:** yaourt displays the complete diff
   between the old and new commits for every tracked file.
3. **Unchanged repository:** no new review is required and the build can proceed
   directly.

“First clone” refers to yaourt's cache, not to whether the package is already
installed. An installed package may therefore trigger a full review if it was
installed using another AUR helper, if yaourt now uses a different cache
location, or if the cached clone was removed. In particular, `-Scc` deletes all
cached repositories, so the next build of each package is treated as a first
clone again.

The review intentionally covers every tracked file: an `.install` file can run
commands as root, while a patch or local script can alter the sources being
built. After the file presentation or diff, yaourt always asks for confirmation
before starting the build.

## Requirements

- [Arch Linux](https://archlinux.org/) or a compatible pacman-based derivative.
- `pacman`, `git`, and `base-devel` (for `makepkg`).
- `sudo` (for pacman operations when yaourt is not started as root).
- Python 3 to build from source; GNU gettext to validate or install external
  translation catalogues. Neither is required by the standalone binary.

## Installation

### Prebuilt binary (recommended)

Download the binary for your architecture from the
[releases page](https://github.com/Chipsterjulien/yaourt/releases), make it
executable, and install it:

```sh
chmod +x yaourt-0.5.1-x86_64
sudo install -Dm755 yaourt-0.5.1-x86_64 /usr/bin/yaourt
```

Provided architectures: `x86_64` and `aarch64`. The binaries are self-contained
and embed the Babet runtime. Their integrity can be checked with the attached
`.sha256` files.

#### Build user

yaourt builds AUR packages as a dedicated system user named `yaourt` (`makepkg`
is never run as root). When yaourt is installed as a package, this user and its
cache directory are created automatically through `sysusers.d` and
`tmpfiles.d`.

For a manual installation of a prebuilt binary, create the user yourself:

```sh
sudo useradd --system --home-dir /var/cache/yaourt --create-home \
  --shell /usr/sbin/nologin --comment "yaourt AUR build user" yaourt
```

### Development mode

With a Babet 2.22.2 (or newer) binary placed in `bin/`:

```sh
./bin/babet . <operation>
```

`build.sh` also accepts an explicit path:

```sh
BABET=/path/to/babet-2.22.2-linux-x86_64 ./build.sh
```

## Tests

The offline suite exercises process and filesystem helpers against the real
Babet runtime, tests the AUR client against a local HTTP server using `chunked`
responses, validates the interactive parent/child chain under a real
pseudo-terminal, checks both directory and embedded modes, and builds the final
executable. The integration tests use the Python 3 standard library and GNU
gettext (`msgfmt`) to validate every translation catalogue:

```sh
BABET=/path/to/babet-2.22.2-linux-x86_64 ./run_tests.sh
```

An optional live AUR RPC check can be enabled with:

```sh
YAOURT_NETWORK_TESTS=1 \
  BABET=/path/to/babet-2.22.2-linux-x86_64 \
  ./run_tests.sh
```

Unified upgrades and interactive AUR build paths have also been validated
manually on Arch Linux. Packaged installation through `sysusers.d` and
`tmpfiles.d` remains tracked in [TODO](TODO.md).

## Configuration

Configuration is loaded from `~/.config/yaourt/config.toml`. See
[`config.example.toml`](config.example.toml) for the English commented example,
or [`config.example.fr.toml`](config.example.fr.toml) for the French version.

During `-Syu`, `list_aur = "notable"` displays orphaned, out-of-date, or
non-AUR-managed packages by default. `"all"` displays the complete list, while
`false` hides the summary. The legacy value `true` remains accepted as an alias
for `"all"`. The `search_limit` option controls the number of displayed search
results.

### Interface language

`language = "auto"` is the default. yaourt checks `LANGUAGE`, `LC_ALL`,
`LC_MESSAGES`, then `LANG`. An explicit locale can be configured instead, for
example `language = "pt_BR"`. Locale names accept POSIX and BCP 47 forms; a
regional locale falls back to its base language and finally to English
(`pt_BR.UTF-8` → `pt_BR` → `pt` → `en`). `C` and `POSIX` select English.

The 43 built-in locales are:

`ar`, `ast`, `bg`, `bn`, `br`, `ca`, `cs_CZ`, `da`, `de`, `el`, `en`, `eo`,
`es`, `es_419`, `fa`, `fi`, `fr`, `he`, `hi`, `hu`, `id`, `is`, `it`, `ja`,
`ko`, `lt`, `nb`, `nl_NL`, `pl`, `pt`, `pt_BR`, `ro`, `ru`, `sk`, `sl`, `sr`,
`sv`, `th`, `tr`, `uk`, `vi`, `zh_CN`, and `zh_TW`.

The English and French catalogues define and preserve the current project's
terminology. The other catalogues are complete initial translations generated
locally and are deliberately marked as requiring review by native speakers.
Structural checks already guarantee complete messages, named variables, and
the declared plural forms; linguistic review remains welcome.

yaourt also reads external `yaourt.mo` files from the standard gettext layout,
first under the directories in `YAOURT_LOCALEDIR`, then
`$XDG_DATA_HOME/locale`, `/usr/local/share/locale`, and `/usr/share/locale`.
External catalogues override the embedded translation and fall back to the
embedded catalogue for missing messages. They are parsed as data and never
executed as Lua code.

To add or review a language without touching business logic, see
[TRANSLATING.md](TRANSLATING.md). The source of truth is `po/*.po`; running
`python3 tools/compile_catalogs.py` regenerates the safe embedded module and the
`po/yaourt.pot` template.

In development mode, a `cfg/config.toml` file in the current directory is
detected automatically.

## Credits and history

yaourt was created by **Julien Mischkowitz** (`wain@archlinux.fr`) and **Tuxce**
(`tuxce.net@gmail.com`), with contributions from many others, as part of the
[archlinuxfr/yaourt](https://github.com/archlinuxfr/yaourt) project. This
repository is an independent rewrite that retains the name and spirit of the
now-abandoned original project. See [AUTHORS](AUTHORS) for details.

## License

Distributed under the **GNU General Public License v3.0 or later (GPLv3+)**, as
was the GPL-licensed original project. See [LICENSE](LICENSE).
