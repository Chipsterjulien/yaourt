#!/usr/bin/env bash
# Vérifications de la compatibilité avec Babet 2.24.0.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BABET="${BABET:-}"
YAOURT_VERSION="$(
  sed -n 's/.*version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ROOT/lib/version.lua"
)"

if [[ ! "$YAOURT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Erreur : version de yaourt invalide dans lib/version.lua." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Erreur : python3 est requis pour le test interactif sous PTY." >&2
  exit 1
fi

if [[ -z "$BABET" ]]; then
  ARCH="$(uname -m)"
  MATCHES=( "$ROOT/bin/"babet-*-linux-"$ARCH" )
  if [[ -e "${MATCHES[0]}" ]]; then
    BABET="$(ls -t "${MATCHES[@]}" 2>/dev/null | head -n1)"
    # Les binaires téléchargés ou copiés peuvent perdre leur bit exécutable.
    # Même comportement que build.sh : le restaurer avant la validation.
    [[ -x "$BABET" ]] || chmod +x "$BABET" 2>/dev/null || true
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

mkdir -p "$TMP/bin"
cp "$ROOT/tests/fixtures/bin/pacdiff" "$TMP/bin/pacdiff"
chmod +x "$TMP/bin/pacdiff"

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

echo "=== Catalogues i18n ==="
if ! command -v msgfmt >/dev/null 2>&1; then
  echo "Erreur : gettext (msgfmt) est requis pour valider les traductions." >&2
  exit 1
fi
python3 "$ROOT/tools/compile_catalogs.py" \
  --po-dir "$ROOT/po" \
  --output "$TMP/i18n_catalogs.lua" \
  --pot "$TMP/yaourt.pot"
cmp "$TMP/i18n_catalogs.lua" "$ROOT/lib/i18n_catalogs.lua"
cmp "$TMP/yaourt.pot" "$ROOT/po/yaourt.pot"
PO_COUNT=0
for po in "$ROOT"/po/*.po; do
  PO_COUNT=$((PO_COUNT + 1))
  msgfmt --check --check-format -o "$TMP/$(basename "${po%.po}").mo" "$po"
done
if [[ "$PO_COUNT" -ne 43 ]]; then
  echo "Erreur : 43 catalogues attendus, $PO_COUNT trouvés." >&2
  exit 1
fi
echo "[PASS] 43 catalogues complets et reproductibles"

INVALID_PO_DIR="$TMP/po-invalid"
cp -r "$ROOT/po" "$INVALID_PO_DIR"
sed -i 's/(parziale | completa)/(parziale completa)/' "$INVALID_PO_DIR/it.po"
if python3 "$ROOT/tools/compile_catalogs.py" \
    --po-dir "$INVALID_PO_DIR" --check > "$TMP/invalid-po.log" 2>&1; then
  echo "Erreur : un marqueur structurel manquant a été accepté." >&2
  exit 1
fi
grep -Fq "structural marker '|' is missing" "$TMP/invalid-po.log"
echo "[PASS] garde-fou des marqueurs structurels de l’aide"

INVALID_PACDIFF_PO_DIR="$TMP/po-invalid-pacdiff"
cp -r "$ROOT/po" "$INVALID_PACDIFF_PO_DIR"
sed -i \
  's/gère les fichiers \.pacnew, \.pacsave et \.pacorig avec pacdiff/gère les fichiers .pacnew et .pacsave avec pacdiff/' \
  "$INVALID_PACDIFF_PO_DIR/fr.po"
if python3 "$ROOT/tools/compile_catalogs.py" \
    --po-dir "$INVALID_PACDIFF_PO_DIR" --check \
    > "$TMP/invalid-pacdiff-po.log" 2>&1; then
  echo "Erreur : un suffixe pacdiff manquant a été accepté." >&2
  exit 1
fi
grep -Fq "interface token '.pacorig' is missing" \
  "$TMP/invalid-pacdiff-po.log"
echo "[PASS] garde-fou des suffixes de fichiers pacdiff"

INVALID_PROVIDER_PO_DIR="$TMP/po-invalid-provider"
cp -r "$ROOT/po" "$INVALID_PROVIDER_PO_DIR"
sed -i 's/relancez sans --noconfirm/relancez sans confirmation/' \
  "$INVALID_PROVIDER_PO_DIR/fr.po"
if python3 "$ROOT/tools/compile_catalogs.py" \
    --po-dir "$INVALID_PROVIDER_PO_DIR" --check \
    > "$TMP/invalid-provider-po.log" 2>&1; then
  echo "Erreur : la perte de --noconfirm a été acceptée." >&2
  exit 1
fi
grep -Fq "protected term '--noconfirm' was altered" \
  "$TMP/invalid-provider-po.log"
echo "[PASS] garde-fou de l’option --noconfirm des fournisseurs"

INVALID_VCS_PO_DIR="$TMP/po-invalid-vcs"
cp -r "$ROOT/po" "$INVALID_VCS_PO_DIR"
sed -i 's/nouvelles révisions VCS/nouvelles révisions/' \
  "$INVALID_VCS_PO_DIR/fr.po"
if python3 "$ROOT/tools/compile_catalogs.py" \
    --po-dir "$INVALID_VCS_PO_DIR" --check \
    > "$TMP/invalid-vcs-po.log" 2>&1; then
  echo "Erreur : la perte du terme VCS a été acceptée." >&2
  exit 1
fi
grep -Fq "protected term 'VCS' was altered" "$TMP/invalid-vcs-po.log"
echo "[PASS] garde-fou du terme VCS"

echo "=== Catalogue gettext externe ==="
EXTERNAL_LOCALE="$TMP/locale/zz/LC_MESSAGES"
mkdir -p "$EXTERNAL_LOCALE"
msgfmt --check --check-format \
  -o "$EXTERNAL_LOCALE/yaourt.mo" \
  "$ROOT/tests/fixtures/i18n/zz.po"
EXTERNAL_FR_LOCALE="$TMP/locale/fr/LC_MESSAGES"
mkdir -p "$EXTERNAL_FR_LOCALE"
msgfmt --check --check-format \
  -o "$EXTERNAL_FR_LOCALE/yaourt.mo" \
  "$ROOT/tests/fixtures/i18n/fr.po"
(
  cd "$ROOT"
  YAOURT_LOCALEDIR="$TMP/locale" LANGUAGE=zz "$BABET" tests/i18n_external
)
I18N_STAGE="$TMP/i18n-stage"
mkdir -p "$I18N_STAGE"
cp "$ROOT/tests/i18n_external/main.lua" "$I18N_STAGE/main.lua"
cp -r "$ROOT/lib" "$I18N_STAGE/lib"
"$BABET" --create-exe "$I18N_STAGE" "$TMP/yaourt-i18n-tests"
YAOURT_LOCALEDIR="$TMP/locale" LANGUAGE=zz "$TMP/yaourt-i18n-tests"
echo "[PASS] catalogue .mo externe en modes dossier et embarqué"

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

echo "=== Intégration HTTP locale AUR ==="
python3 "$ROOT/tests/test_aur_local.py" "$BABET" "$ROOT"

echo "=== Intégration VCS locale ==="
python3 "$ROOT/tests/test_vcs_local.py" "$BABET" "$ROOT"

echo "=== Test interactif sous pseudo-terminal ==="
python3 "$ROOT/tests/test_interactive_pty.py" "$BABET" "$ROOT"

if [[ "${YAOURT_NETWORK_TESTS:-0}" == "1" ]]; then
  echo "=== Tests réseau AUR ==="
  (
    cd "$ROOT"
    "$BABET" tests/network
  )
fi

echo "=== Construction et smoke tests ==="
BABET="$BABET" "$ROOT/build.sh" "$TMP/yaourt"
[[ "$("$TMP/yaourt" --version)" == "yaourt $YAOURT_VERSION" ]]
HELP_OUTPUT="$TMP/help-en.txt"
XDG_CONFIG_HOME="$TMP/config" LANGUAGE=en "$TMP/yaourt" --help > "$HELP_OUTPUT"
grep -Fq "yaourt $YAOURT_VERSION" "$HELP_OUTPUT"
grep -Fq "  yaourt -Ss <term>" "$HELP_OUTPUT"
grep -Fq "  yaourt -Syu --devel" "$HELP_OUTPUT"
grep -Fq "  yaourt -C [pacdiff options]" "$HELP_OUTPUT"
grep -Fq "  yaourt -G <package>..." "$HELP_OUTPUT"
echo "[PASS] binaire yaourt dossier/embarqué"

PACDIFF_FOLDER_OUTPUT="$TMP/pacdiff-folder.txt"
PACDIFF_EMBEDDED_OUTPUT="$TMP/pacdiff-embedded.txt"
(
  cd "$ROOT"
  PATH="$TMP/bin:$PATH" XDG_CONFIG_HOME="$TMP/config" LANGUAGE=en \
    "$BABET" . -C --output > "$PACDIFF_FOLDER_OUTPUT"
)
PATH="$TMP/bin:$PATH" XDG_CONFIG_HOME="$TMP/config" LANGUAGE=en \
  "$TMP/yaourt" --pacdiff --output > "$PACDIFF_EMBEDDED_OUTPUT"
grep -Fq "YAOURT_PACDIFF_STUB" "$PACDIFF_FOLDER_OUTPUT"
grep -Fq "<--output>" "$PACDIFF_FOLDER_OUTPUT"
grep -Fq "YAOURT_PACDIFF_STUB" "$PACDIFF_EMBEDDED_OUTPUT"
grep -Fq "<--output>" "$PACDIFF_EMBEDDED_OUTPUT"
echo "[PASS] pacdiff externe en modes dossier et embarqué"

echo "=== Résultat ==="
if [[ "${YAOURT_NETWORK_TESTS:-0}" == "1" ]]; then
  echo "Tous les tests sont passés."
else
  echo "Tous les tests hors ligne sont passés."
fi
