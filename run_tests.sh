#!/usr/bin/env bash
# Vérifications hors ligne de la migration vers Babet 2.9.0.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BABET="${BABET:-}"

if [[ -z "$BABET" ]]; then
  ARCH="$(uname -m)"
  MATCHES=( "$ROOT/bin/"babet-*-linux-"$ARCH" )
  if [[ -e "${MATCHES[0]}" ]]; then
    BABET="$(ls -t "${MATCHES[@]}" 2>/dev/null | head -n1)"
  elif [[ -x "$ROOT/bin/babet" ]]; then
    BABET="$ROOT/bin/babet"
  else
    BABET="babet"
  fi
fi

if command -v "$BABET" >/dev/null 2>&1; then
  BABET="$(command -v "$BABET")"
elif [[ -x "$BABET" ]]; then
  BABET="$(realpath "$BABET")"
else
  echo "Erreur : babet introuvable (PATH ou \$BABET)." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "=== Babet ==="
"$BABET" --version

echo "=== Syntaxe shell ==="
bash -n "$ROOT/build.sh" "$ROOT/release.sh" "$ROOT/run_tests.sh"

echo "=== API dépréciée/interdite ==="
if grep -REn --include='*.lua' 'babet\.isdir|babet\.isfile|os\.execute' \
    "$ROOT/main.lua" "$ROOT/lib" "$ROOT/tests"; then
  echo "Erreur : API dépréciée ou os.execute encore présent." >&2
  exit 1
fi
echo "[PASS] aucune API dépréciée ciblée"

echo "=== Tests en mode dossier ==="
(
  cd "$ROOT"
  "$BABET" tests
)

echo "=== Tests en mode embarqué ==="
TEST_STAGE="$TMP/test-stage"
mkdir -p "$TEST_STAGE"
cp "$ROOT/tests/main.lua" "$TEST_STAGE/main.lua"
cp -r "$ROOT/lib" "$TEST_STAGE/lib"
"$BABET" --create-exe "$TEST_STAGE" "$TMP/yaourt-tests"
"$TMP/yaourt-tests"

if [[ "${YAOURT_NETWORK_TESTS:-0}" == "1" ]]; then
  echo "=== Tests réseau AUR ==="
  (
    cd "$ROOT"
    "$BABET" tests/network
  )
fi

echo "=== Construction et smoke tests ==="
BABET="$BABET" "$ROOT/build.sh" "$TMP/yaourt"
[[ "$("$TMP/yaourt" --version)" == "yaourt 0.4.1" ]]
"$TMP/yaourt" --help | grep -Fq "yaourt 0.4.1"
echo "[PASS] binaire yaourt dossier/embarqué"

echo "=== Résultat ==="
echo "Tous les tests hors ligne sont passés."
