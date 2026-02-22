#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# mermaid-to-svg.sh — Convert Mermaid diagrams in Markdown files to SVG images
#
# Requires: Node.js, @mermaid-js/mermaid-cli (mmdc)
#
# Usage:
#   bash scripts/mermaid-to-svg.sh                    # all docs/*.md files
#   bash scripts/mermaid-to-svg.sh docs/deployment-guide.md  # single file
#   bash scripts/mermaid-to-svg.sh --install          # install mmdc
#   bash scripts/mermaid-to-svg.sh --check            # verify prerequisites
#   bash scripts/mermaid-to-svg.sh --list             # list files with mermaid blocks
#   bash scripts/mermaid-to-svg.sh --clean            # remove generated SVGs
#
# Output: SVG files written to docs/diagrams/<filename>-<index>.svg
# Markdown files are NOT modified. Use the SVGs for presentations, PDFs, or
# embedding in rendered documentation.
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_DIR="${REPO_ROOT}/docs"
OUTPUT_DIR="${DOCS_DIR}/diagrams"
MMDC="npx --yes @mermaid-js/mermaid-cli"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_check() {
    local errors=0

    echo "Checking prerequisites..."

    if command -v node &>/dev/null; then
        ok "Node.js $(node --version)"
    else
        fail "Node.js not found. Install from https://nodejs.org/"
        errors=$((errors + 1))
    fi

    if command -v npx &>/dev/null; then
        ok "npx available"
    else
        fail "npx not found. Comes with Node.js >= 8"
        errors=$((errors + 1))
    fi

    # Test mmdc
    if npx --yes @mermaid-js/mermaid-cli --version &>/dev/null 2>&1; then
        ok "mermaid-cli (mmdc) available"
    else
        warn "mermaid-cli not cached yet. Will be downloaded on first run via npx."
    fi

    if [ "$errors" -gt 0 ]; then
        fail "$errors prerequisite(s) missing"
        return 1
    fi
    ok "All prerequisites satisfied"
}

cmd_install() {
    info "Installing @mermaid-js/mermaid-cli globally..."
    npm install -g @mermaid-js/mermaid-cli
    ok "Installed. Run 'mmdc --version' to verify."
}

cmd_list() {
    local count=0
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && files=("${DOCS_DIR}"/*.md)

    for md_file in "${files[@]}"; do
        local n
        n=$(grep -c '```mermaid' "$md_file" 2>/dev/null || true)
        if [ "$n" -gt 0 ]; then
            echo "  ${md_file##*/}: $n diagram(s)"
            count=$((count + n))
        fi
    done
    echo "Total: $count mermaid diagram(s)"
}

cmd_clean() {
    if [ -d "$OUTPUT_DIR" ]; then
        local count
        count=$(find "$OUTPUT_DIR" -name '*.svg' | wc -l)
        rm -rf "$OUTPUT_DIR"
        ok "Removed $count SVG file(s) from $OUTPUT_DIR"
    else
        info "No diagrams directory to clean"
    fi
}

cmd_convert() {
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && files=("${DOCS_DIR}"/*.md)

    mkdir -p "$OUTPUT_DIR"

    local total=0
    local converted=0
    local failed=0

    for md_file in "${files[@]}"; do
        [ -f "$md_file" ] || continue

        local basename
        basename="$(basename "$md_file" .md)"
        local index=0
        local in_mermaid=false
        local buffer=""

        while IFS= read -r line || [ -n "$line" ]; do
            if [ "$in_mermaid" = false ] && [[ "$line" == '```mermaid' ]]; then
                in_mermaid=true
                buffer=""
                continue
            fi

            if [ "$in_mermaid" = true ]; then
                if [[ "$line" == '```' ]]; then
                    in_mermaid=false
                    index=$((index + 1))
                    total=$((total + 1))

                    local mmd_file="${OUTPUT_DIR}/${basename}-${index}.mmd"
                    local svg_file="${OUTPUT_DIR}/${basename}-${index}.svg"

                    echo "$buffer" > "$mmd_file"

                    if $MMDC -i "$mmd_file" -o "$svg_file" -b transparent 2>/dev/null; then
                        ok "${basename}-${index}.svg"
                        converted=$((converted + 1))
                    else
                        fail "${basename}-${index}.svg — mmdc error"
                        failed=$((failed + 1))
                    fi

                    rm -f "$mmd_file"
                else
                    if [ -n "$buffer" ]; then
                        buffer="${buffer}"$'\n'"${line}"
                    else
                        buffer="${line}"
                    fi
                fi
            fi
        done < "$md_file"
    done

    echo ""
    echo "──────────────────────────────────"
    echo "Total:     $total diagram(s)"
    echo "Converted: $converted"
    [ "$failed" -gt 0 ] && echo "Failed:    $failed"
    echo "Output:    $OUTPUT_DIR/"
    echo "──────────────────────────────────"
}

# ── Main ─────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --check)   cmd_check ;;
    --install) cmd_install ;;
    --list)    shift; cmd_list "$@" ;;
    --clean)   cmd_clean ;;
    --help|-h)
        echo "Usage: bash scripts/mermaid-to-svg.sh [OPTIONS] [FILES...]"
        echo ""
        echo "Convert Mermaid diagrams in Markdown files to SVG images."
        echo ""
        echo "Options:"
        echo "  --check    Verify prerequisites (Node.js, mmdc)"
        echo "  --install  Install @mermaid-js/mermaid-cli globally"
        echo "  --list     List files containing Mermaid diagrams"
        echo "  --clean    Remove all generated SVG files"
        echo "  --help     Show this help"
        echo ""
        echo "Examples:"
        echo "  bash scripts/mermaid-to-svg.sh                          # convert all docs/*.md"
        echo "  bash scripts/mermaid-to-svg.sh docs/deployment-guide.md # convert one file"
        echo "  bash scripts/mermaid-to-svg.sh --list                   # count diagrams"
        ;;
    *)         cmd_convert "$@" ;;
esac
