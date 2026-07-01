#!/usr/bin/env bash
# build.sh — génère le binaire autonome yaourt.
#
# Empaquète main.lua + lib/ dans un exécutable unique via babet
# --create-exe. On passe par un répertoire de staging propre pour
# n'embarquer QUE les sources Lua (ni build.sh, ni packaging/, ni README).
#
# Prérequis : binaire babet accessible (PATH ou variable $BABET).
# La récupération de babet selon l'architecture est gérée côté
# packaging (cf. packaging/PKGBUILD, TODO).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-yaourt}"

# babet : $BABET si défini, sinon le binaire propre à l'architecture
# courante dans bin/. Les binaires y sont nommés selon le motif des releases
# babet : babet-<version>-linux-<uname -m> (ex. babet-1.8.0-linux-x86_64).
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

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp "$ROOT/main.lua" "$STAGE/"
cp -r "$ROOT/lib" "$STAGE/"

"$BABET" --create-exe "$STAGE" "$OUT"
chmod +x "$OUT"
echo "Binaire généré : $OUT"
