#!/usr/bin/env bash
# build.sh — génère le binaire autonome yaourt.
#
# Empaquète main.lua + lib/ dans un exécutable unique via babet
# --create-exe. On passe par un répertoire de staging propre pour
# n'embarquer QUE les sources Lua (ni build.sh, ni packaging/, ni README).
#
# Prérequis : binaire Babet >= 2.24.0 accessible (PATH ou variable $BABET).
# La récupération de babet selon l'architecture est gérée côté
# packaging (cf. packaging/PKGBUILD, TODO).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-yaourt}"

# babet : $BABET si défini, sinon le binaire propre à l'architecture
# courante dans bin/. Les binaires y sont nommés selon le motif des releases
# babet : babet-<version>-linux-<uname -m> (ex. babet-2.24.0-linux-x86_64).
# On résout par glob sur l'architecture ; à défaut on tente ./bin/babet, puis
# le PATH. Permet de copier le dossier tel quel sur plusieurs machines (les 3
# binaires dans bin/) : chacune prend automatiquement le sien.
BABET="${BABET:-}"
if [[ -z "$BABET" ]]; then
  _arch="$(uname -m)"
  # Glob des binaires correspondant à l'architecture courante.
  _matches=( "$ROOT/bin/"babet-*-linux-"$_arch" )
  if [[ -e "${_matches[0]}" ]]; then
    # S'il y en a plusieurs (versions multiples), on prend le plus récent.
    BABET="$(ls -t "${_matches[@]}" 2>/dev/null | head -n1)"
    # Le binaire vient souvent d'un téléchargement/copie sans bit exécutable :
    # on le rend exécutable au passage pour éviter un échec silencieux.
    [[ -x "$BABET" ]] || chmod +x "$BABET" 2>/dev/null || true
  elif [[ -x "$ROOT/bin/babet" ]]; then
    BABET="$ROOT/bin/babet"
  else
    BABET="babet"
  fi
fi

if ! command -v "$BABET" >/dev/null 2>&1 && [[ ! -x "$BABET" ]]; then
  echo "Erreur : babet introuvable (PATH ou \$BABET)." >&2
  exit 1
fi

BABET_MIN_VERSION="$(
  sed -n 's/.*babet_min[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ROOT/lib/version.lua"
)"
if [[ ! "$BABET_MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Erreur : version minimale de Babet invalide dans lib/version.lua." >&2
  exit 1
fi

BABET_INFO="$("$BABET" --version 2>/dev/null || true)"
if [[ ! "$BABET_INFO" =~ ^babet[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
  echo "Erreur : impossible d'identifier la version de Babet : $BABET_INFO" >&2
  exit 1
fi

BABET_MAJOR="${BASH_REMATCH[1]}"
BABET_MINOR="${BASH_REMATCH[2]}"
BABET_PATCH="${BASH_REMATCH[3]}"
IFS=. read -r MIN_MAJOR MIN_MINOR MIN_PATCH <<< "$BABET_MIN_VERSION"
if (( BABET_MAJOR < MIN_MAJOR
   || (BABET_MAJOR == MIN_MAJOR && BABET_MINOR < MIN_MINOR)
   || (BABET_MAJOR == MIN_MAJOR && BABET_MINOR == MIN_MINOR
       && BABET_PATCH < MIN_PATCH) )); then
  echo "Erreur : Babet >= $BABET_MIN_VERSION requis ($BABET_INFO détecté)." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$ROOT/main.lua" "$STAGE/"
cp -r "$ROOT/lib" "$STAGE/"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Erreur : python3 est requis pour générer les catalogues i18n." >&2
  exit 1
fi
python3 "$ROOT/tools/compile_catalogs.py" \
  --po-dir "$ROOT/po" \
  --output "$STAGE/lib/i18n_catalogs.lua" \
  --pot "$STAGE/yaourt.pot"

"$BABET" --create-exe "$STAGE" "$OUT"
chmod +x "$OUT"
echo "Binaire généré : $OUT"
