#!/usr/bin/env bash
# release.sh — prépare les artefacts de release pour l'ARCHITECTURE COURANTE.
#
# babet --create-exe doit s'EXÉCUTER sur l'architecture cible : on ne peut
# donc pas générer un binaire ARM depuis un PC x86_64. Ce script est conçu pour
# être lancé SUR CHAQUE MACHINE (PC x86_64, RPi4 aarch64, RPi Zero armv6l…).
# Chacune produit sa part dans dist/ ; on rassemble ensuite tous les dist/ pour
# la release GitHub.
#
# Pour chaque exécution, il génère dans dist/ :
#   yaourt-<version>-<arch>              le binaire autonome
#   yaourt-<version>-<arch>.sha256       sa somme de contrôle
#   yaourt-<version>-<arch>.tar.gz       l'archive compressée
#   yaourt-<version>-<arch>.tar.gz.sha256  la somme de contrôle de l'archive
#
# Prérequis : le binaire babet de CETTE architecture. build.sh le résout
# automatiquement via bin/babet-<uname -m> (ex. bin/babet-x86_64), ou à
# défaut bin/babet, $BABET, ou le PATH. On peut donc copier le dossier
# tel quel sur chaque machine (les 3 binaires dans bin/) : chacune prendra le
# sien.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# --- Architecture (convention uname -m : x86_64, aarch64, armv6l…) ----------
ARCH="$(uname -m)"

# --- Version, lue depuis lib/version.lua (source unique de vérité) -----------
# On extrait la valeur de  version = "X.Y.Z"  .
VERSION="$(sed -n 's/.*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' lib/version.lua)"
if [[ -z "$VERSION" ]]; then
  echo "Erreur : version introuvable dans lib/version.lua." >&2
  exit 1
fi

# Avertissement si la version porte encore le suffixe -dev.
case "$VERSION" in
  *-dev|*-DEV)
    echo "Attention : version « $VERSION » (suffixe -dev). Pour une vraie" >&2
    echo "release, retirez le suffixe dans lib/version.lua." >&2
    ;;
esac

BASENAME="yaourt-${VERSION}-${ARCH}"
DIST="$ROOT/dist"
mkdir -p "$DIST"

echo "==> Génération de $BASENAME (architecture : $ARCH, version : $VERSION)"

# --- Binaire autonome via build.sh ------------------------------------------
# build.sh gère la résolution de babet ($BABET / ./bin/babet / PATH).
"$ROOT/build.sh" "$DIST/$BASENAME"

# --- Sommes de contrôle + archive (chemins RELATIFS dans dist/) -------------
# On se place dans dist/ pour que les fichiers .sha256 contiennent un chemin
# relatif : ainsi « sha256sum -c » fonctionne côté utilisateur après download.
cd "$DIST"

sha256sum "$BASENAME" > "$BASENAME.sha256"

tar czf "$BASENAME.tar.gz" "$BASENAME"
sha256sum "$BASENAME.tar.gz" > "$BASENAME.tar.gz.sha256"

cd "$ROOT"

echo ""
echo "==> Artefacts générés dans dist/ :"
for f in "$BASENAME" "$BASENAME.sha256" "$BASENAME.tar.gz" "$BASENAME.tar.gz.sha256"; do
  printf '    %s\n' "$f"
done
echo ""
echo "Vérification : (cd dist && sha256sum -c $BASENAME.sha256 $BASENAME.tar.gz.sha256)"
