#!/bin/bash
# full_text.sh - Concat doc + tests + .h + .c + .py + .sh dans cet ordre
# en un seul .txt brut (separateurs ASCII, sans markdown fences).
# Pour ingestion LLM / archive plate.

set -uo pipefail

OUT="${1:-./calypso-full.txt}"
SCOPE="${SCOPE:-.}"
EXCLUDE_RE="${EXCLUDE:-subprojects|build|pc-bios|tests/functional|tests/qtest|tests/unit|tests/migration|tests/qemu-iotests|node_modules|\.git|\.pytest_cache}"

# Si $OUT est un dossier, append le nom de fichier par defaut.
if [ -d "$OUT" ]; then
    OUT="${OUT%/}/calypso-full.txt"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "=== full_text.sh ==="
echo "Scope    : $SCOPE"
echo "Output   : $OUT"
echo "Exclude  : $EXCLUDE_RE"
echo

: > "$OUT" || { echo "ERROR: cannot write to '$OUT' (permission ? path invalide ?)" >&2; exit 1; }

# ---- Header ----
cat >> "$OUT" <<EOF
================================================================================
Calypso QEMU - Full text bundle
Generated : $(date -Iseconds)
Scope     : $SCOPE
Sections  : 1.docs  2.tests  3.headers  4.sources  5.python  6.shell
================================================================================

EOF

# Helper : add a file with ASCII separator and notify CLI
_add() {
    local f="$1"
    local rel="${f#./}"
    local size=$(wc -c < "$f" 2>/dev/null || echo 0)
    local nlines=$(wc -l < "$f" 2>/dev/null || echo 0)
    
    # Affichage en direct sur le terminal (CLI)
    echo "  -> Traitement de : $rel ($nlines lignes)"
    
    {
        echo ""
        echo "================================================================================"
        echo "FILE: $rel"
        echo "SIZE: $size bytes, $nlines lines"
        echo "================================================================================"
        cat "$f"
        echo ""
    } >> "$OUT"
}

# ---- 1) Documentation ----
echo "--------------------------------------------------------------------------------"
echo "Section 1 : DOCUMENTATION (.md, .mmd, .qmd)"
echo "--------------------------------------------------------------------------------"
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 1 : DOCUMENTATION (.md, .mmd, .qmd)"
    echo "################################################################################"
} >> "$OUT"
DOCS=$(find "$SCOPE" -type f \( -name "*.md" -o -name "*.mmd" -o -name "*.qmd" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$DOCS" | grep -c . || echo 0)
echo "Total docs files : $N" >> "$OUT"
for f in $DOCS; do _add "$f"; done

# ---- 2) Tests ----
echo ""
echo "--------------------------------------------------------------------------------"
echo "Section 2 : TESTS (tests/*.py)"
echo "--------------------------------------------------------------------------------"
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 2 : TESTS (tests/*.py)"
    echo "################################################################################"
} >> "$OUT"
TESTS=$(find "$SCOPE" -type f \( -name "test_*.py" -o -name "conftest.py" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$TESTS" | grep -c . || echo 0)
echo "Total tests files : $N" >> "$OUT"
for f in $TESTS; do _add "$f"; done

# ---- 3) Headers ----
echo ""
echo "--------------------------------------------------------------------------------"
echo "Section 3 : HEADERS (.h)"
echo "--------------------------------------------------------------------------------"
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 3 : HEADERS (.h)"
    echo "################################################################################"
} >> "$OUT"
HDRS=$(find "$SCOPE" -type f -name "*.h" 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$HDRS" | grep -c . || echo 0)
echo "Total headers files : $N" >> "$OUT"
for f in $HDRS; do _add "$f"; done

# ---- 4) Sources ----
echo ""
echo "--------------------------------------------------------------------------------"
echo "Section 4 : SOURCES (.c, .cpp)"
echo "--------------------------------------------------------------------------------"
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 4 : SOURCES (.c, .cpp)"
    echo "################################################################################"
} >> "$OUT"
SRCS=$(find "$SCOPE" -type f \( -name "*.c" -o -name "*.cpp" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$SRCS" | grep -c . || echo 0)
echo "Total sources files : $N" >> "$OUT"
for f in $SRCS; do _add "$f"; done

# ---- 5) Python scripts (hors tests/) ----
echo ""
echo "--------------------------------------------------------------------------------"
echo "Section 5 : PYTHON SCRIPTS"
echo "--------------------------------------------------------------------------------"
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 5 : PYTHON SCRIPTS (hors tests/)"
    echo "################################################################################"
} >> "$OUT"
PYS=$(find "$SCOPE" -type f -name "*.py" 2>/dev/null \
       | grep -vE "$EXCLUDE_RE|/tests/|test_.*\.py$|conftest\.py$" | sort)
N=$(echo "$PYS" | grep -c . || echo 0)
echo "Total python files : $N" >> "$OUT"
for f in $PYS; do _add "$f"; done

# ---- 6) Shell scripts ----
echo ""
echo "--------------------------------------------------------------------------------"
echo "Section 6 : SHELL SCRIPTS (.sh)"
echo "--------------------------------------------------------------------------------"
{
    echo ""
    echo "################################################################################"
    echo "# SECTION 6 : SHELL SCRIPTS (.sh)"
    echo "################################################################################"
} >> "$OUT"
SHS=$(find "$SCOPE" -type f \( -name "*.sh" -o -name "*.bash" \) 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" | sort)
N=$(echo "$SHS" | grep -c . || echo 0)
echo "Total shell files : $N" >> "$OUT"
for f in $SHS; do _add "$f"; done

# ---- Footer ----
{
    echo ""
    echo "================================================================================"
    echo "END OF BUNDLE - generated $(date -Iseconds)"
    echo "================================================================================"
} >> "$OUT"

echo
echo "=== DONE ==="
echo "Output : $OUT"
echo "Size   : $(du -h "$OUT" | cut -f1)"
echo "Lines  : $(wc -l < "$OUT")"
