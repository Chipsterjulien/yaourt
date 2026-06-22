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

# luapilot : $LUAPILOT si défini, sinon le binaire propre à l'architecture
# courante dans bin/. Les binaires y sont nommés selon le motif des releases
# luapilot : luapilot-<version>-linux-<uname -m> (ex. luapilot-1.8.0-linux-x86_64).
# On résout par glob sur l'architecture ; à défaut on tente ./bin/luapilot, puis
# le PATH. Permet de copier le dossier tel quel sur plusieurs machines (les 3
# binaires dans bin/) : chacune prend automatiquement le sien.
LUAPILOT="${LUAPILOT:-}"
if [[ -z "$LUAPILOT" ]]; then
  _arch="$(uname -m)"
  # Glob des binaires correspondant à l'architecture courante.
  _matches=( "$ROOT/bin/"luapilot-*-linux-"$_arch" )
  if [[ -e "${_matches[0]}" ]]; then
    # S'il y en a plusieurs (versions multiples), on prend le plus récent.
    LUAPILOT="$(ls -t "${_matches[@]}" 2>/dev/null | head -n1)"
    # Le binaire vient souvent d'un téléchargement/copie sans bit exécutable :
    # on le rend exécutable au passage pour éviter un échec silencieux.
    [[ -x "$LUAPILOT" ]] || chmod +x "$LUAPILOT" 2>/dev/null || true
  elif [[ -x "$ROOT/bin/luapilot" ]]; then
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