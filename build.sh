#!/usr/bin/env bash
# build.sh — génère le binaire autonome yaourt.
#
# Empaquète main.lua + lib/ dans un exécutable unique via luapilot
# --create-exe. On passe par un répertoire de staging propre pour
# n'embarquer QUE les sources Lua (ni build.sh, ni packaging/, ni README).
#
# Prérequis : binaire luapilot accessible (PATH ou variable $LUAPILOT).
# La récupération de luapilot selon l'architecture est gérée côté
# packaging (cf. packaging/PKGBUILD, TODO).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-yaourt}"

# luapilot : $LUAPILOT si défini, sinon ./bin/luapilot (binaire local
# vendu par archi, non versionné), sinon le PATH.
LUAPILOT="${LUAPILOT:-}"
if [[ -z "$LUAPILOT" ]]; then
  if [[ -x "$ROOT/bin/luapilot" ]]; then
    LUAPILOT="$ROOT/bin/luapilot"
  else
    LUAPILOT="luapilot"
  fi
fi

if ! command -v "$LUAPILOT" >/dev/null 2>&1 && [[ ! -x "$LUAPILOT" ]]; then
  echo "Erreur : luapilot introuvable (PATH ou \$LUAPILOT)." >&2
  exit 1
fi

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$ROOT/main.lua" "$STAGE/"
cp -r "$ROOT/lib" "$STAGE/"

"$LUAPILOT" --create-exe "$STAGE" "$OUT"
chmod +x "$OUT"
echo "Binaire généré : $OUT"