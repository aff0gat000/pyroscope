#!/usr/bin/env bash
# =============================================================================
# export-to-confluence.sh — Convert Markdown docs to Confluence wiki markup
#
# Generates Confluence-compatible output (tested with Confluence 9.2.3) that
# can be pasted directly into Confluence pages. Handles tables (header vs data
# rows), code blocks, headers, links, blockquotes, and Mermaid diagrams
# (converted to code blocks with a note to render separately).
#
# Usage:
#   bash scripts/export-to-confluence.sh                    # All docs
#   bash scripts/export-to-confluence.sh docs/runbook.md    # Single file
#   bash scripts/export-to-confluence.sh --enterprise       # Enterprise docs only (from manifest)
#   bash scripts/export-to-confluence.sh --list             # List available docs
#   bash scripts/export-to-confluence.sh --output-dir /tmp  # Custom output dir
#
# Output:
#   confluence-export/<filename>.confluence.txt  (one file per doc)
#   confluence-export/INDEX.confluence.txt       (master index)
#
# Paste the contents of any .confluence.txt file into Confluence's wiki
# markup editor (Insert → Markup → Confluence Wiki) or use the Confluence
# REST API to create pages programmatically.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCS_DIR="${REPO_ROOT}/docs"
OUTPUT_DIR="${REPO_ROOT}/confluence-export"
SINGLE_FILE=""
LIST_ONLY=false
ENTERPRISE_ONLY=false
MANIFEST_FILE="${DOCS_DIR}/confluence-manifest.txt"

# --- Auto-load .env.confluence if present (never committed — in .gitignore) ---
if [[ -f "${REPO_ROOT}/.env.confluence" ]]; then
    echo "Loading config from .env.confluence"
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env.confluence"
fi

# --- Confluence settings (used for cross-doc link conversion) ---
CONFLUENCE_PREFIX="${CONFLUENCE_PREFIX:-Pyroscope - }"
MERMAID_LIVE_URL="${MERMAID_LIVE_URL:-}"

# --- Detect mermaid renderer (Docker preferred, local mmdc as fallback) ---
MERMAID_MODE="none"
if command -v docker &>/dev/null && docker info &>/dev/null; then
    MERMAID_MODE="docker"
    echo "Mermaid renderer: Docker (minlag/mermaid-cli)"
elif command -v mmdc &>/dev/null; then
    MERMAID_MODE="local"
    MMDC_ARGS=(-b white)
    if [[ -f "${REPO_ROOT}/.puppeteerrc.json" ]]; then
        MMDC_ARGS+=(-p "${REPO_ROOT}/.puppeteerrc.json")
    elif [[ -f "${REPO_ROOT}/puppeteer-config.json" ]]; then
        MMDC_ARGS+=(-p "${REPO_ROOT}/puppeteer-config.json")
    elif [[ -f "${HOME}/.puppeteerrc.json" ]]; then
        MMDC_ARGS+=(-p "${HOME}/.puppeteerrc.json")
    elif [[ -f "${HOME}/puppeteer-config.json" ]]; then
        MMDC_ARGS+=(-p "${HOME}/puppeteer-config.json")
    fi
    echo "Mermaid renderer: local mmdc"
else
    echo "Mermaid renderer: none (install Docker or mmdc to render diagrams)"
fi

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)   OUTPUT_DIR="$2"; shift 2 ;;
        --list)         LIST_ONLY=true; shift ;;
        --enterprise)   ENTERPRISE_ONLY=true; shift ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *)
            if [[ -f "$1" ]]; then
                SINGLE_FILE="$1"
            elif [[ -f "${DOCS_DIR}/$1" ]]; then
                SINGLE_FILE="${DOCS_DIR}/$1"
            else
                echo "Error: File not found: $1" >&2
                exit 1
            fi
            shift ;;
    esac
done

# --- List mode ---
if [[ "$LIST_ONLY" == true ]]; then
    echo "Available documentation files:"
    echo ""
    find "${DOCS_DIR}" -name '*.md' -type f | sort | while read -r f; do
        rel="${f#${DOCS_DIR}/}"
        title=$(head -1 "$f" | sed 's/^#* *//')
        printf "  %-45s %s\n" "$rel" "$title"
    done
    exit 0
fi

mkdir -p "${OUTPUT_DIR}"

# --- Render a single .mmd file to .png ---
render_mermaid_png() {
    local mmd_file="$1"
    local png_file="$2"

    if [[ "$MERMAID_MODE" == "docker" ]]; then
        local mmd_dir mmd_name png_name
        mmd_dir=$(dirname "$mmd_file")
        mmd_name=$(basename "$mmd_file")
        png_name=$(basename "$png_file")
        docker run --rm -v "${mmd_dir}:/data" minlag/mermaid-cli \
            -i "/data/${mmd_name}" -o "/data/${png_name}" -b white 2>&1
        # Docker outputs to the same dir as input; move if needed
        if [[ -f "${mmd_dir}/${png_name}" && "${mmd_dir}/${png_name}" != "$png_file" ]]; then
            mv "${mmd_dir}/${png_name}" "$png_file"
        fi
    elif [[ "$MERMAID_MODE" == "local" ]]; then
        mmdc -i "$mmd_file" -o "$png_file" "${MMDC_ARGS[@]}" 2>&1
    fi
}

# --- Pre-extract and render Mermaid diagrams to PNG ---
extract_and_render_mermaid() {
    local input_file="$1"
    local basename="$2"
    local temp_dir="${OUTPUT_DIR}/.mermaid-tmp"
    mkdir -p "$temp_dir"

    # Extract mermaid blocks to .mmd files
    awk -v dir="$temp_dir" -v base="$basename" '
    /^```mermaid/ || /^ *```mermaid/ { in_m=1; count++; buf=""; next }
    in_m && (/^```$/ || /^ *```$/) {
        in_m=0
        f = dir "/" base "-mermaid-" count ".mmd"
        printf "%s", buf > f
        close(f)
        next
    }
    in_m { buf = (buf == "" ? $0 : buf "\n" $0) }
    ' "$input_file"

    # Render each .mmd to .png
    for mmd in "${temp_dir}/${basename}"-mermaid-*.mmd; do
        [[ -f "$mmd" ]] || continue
        local num
        num=$(basename "$mmd" | grep -o 'mermaid-[0-9]*' | grep -o '[0-9]*')
        local png="${OUTPUT_DIR}/${basename}-mermaid-${num}.png"
        if render_mermaid_png "$mmd" "$png"; then
            echo "    Rendered: $(basename "$png")"
        else
            echo "    WARNING: Failed to render mermaid diagram ${num}" >&2
        fi
    done
}

# --- Convert one Markdown file to Confluence wiki markup ---
convert_to_confluence() {
    local input_file="$1"
    local output_file="$2"
    local page_basename="$3"

    PAGE_BASENAME="$page_basename" \
    MERMAID_MODE="$MERMAID_MODE" \
    MERMAID_LIVE_URL="$MERMAID_LIVE_URL" \
    CONFLUENCE_PREFIX="$CONFLUENCE_PREFIX" \
    awk '
    BEGIN {
        in_code = 0
        in_mermaid = 0
        mermaid_count = 0
        mermaid_buf = ""
        code_lang = ""
        in_quote = 0
        table_row = 0    # 0 = not in table, 1 = header row, 2+ = data rows
    }

    # --- Mermaid blocks (render as PNG image + expandable source) ---
    /^```mermaid/ || /^ *```mermaid/ {
        flush_quote()
        in_mermaid = 1
        mermaid_count++
        mermaid_buf = ""
        next
    }
    in_mermaid && (/^```$/ || /^ *```$/) {
        in_mermaid = 0
        png_name = ENVIRON["PAGE_BASENAME"] "-mermaid-" mermaid_count ".png"
        if (ENVIRON["MERMAID_MODE"] != "none") {
            print "!" png_name "!"
            print ""
        }
        print "{expand:title=View Mermaid Source}"
        print "{code:language=none}"
        print mermaid_buf
        print "{code}"
        print "{expand}"
        if (ENVIRON["MERMAID_LIVE_URL"] != "") {
            print ""
            print "[Open in Mermaid Live|" ENVIRON["MERMAID_LIVE_URL"] "]"
        }
        next
    }
    in_mermaid {
        if (mermaid_buf != "") mermaid_buf = mermaid_buf "\n"
        mermaid_buf = mermaid_buf $0
        next
    }

    # --- Code blocks ---
    (/^```[a-zA-Z]/ || /^ *```[a-zA-Z]/) && !in_code {
        flush_quote()
        in_code = 1
        code_lang = $0
        gsub(/^ *```/, "", code_lang)
        if (code_lang == "bash" || code_lang == "sh" || code_lang == "shell") code_lang = "bash"
        else if (code_lang == "yaml" || code_lang == "yml") code_lang = "yaml"
        else if (code_lang == "json") code_lang = "javascript"
        else if (code_lang == "properties") code_lang = "none"
        else if (code_lang == "sql") code_lang = "sql"
        else if (code_lang == "java") code_lang = "java"
        else if (code_lang == "xml") code_lang = "xml"
        else if (code_lang == "python" || code_lang == "py") code_lang = "python"
        else code_lang = "none"
        print "{code:language=" code_lang "}"
        next
    }
    (/^```$/ || /^ *```$/) && in_code {
        in_code = 0
        in_mermaid = 0
        print "{code}"
        next
    }
    (/^```/ || /^ *```/) && !in_code {
        flush_quote()
        in_code = 1
        print "{code:language=none}"
        next
    }

    # Inside code blocks — pass through unchanged
    in_code { print; next }

    # --- Headers (close any open quote first) ---
    /^######/ { flush_quote(); table_row = 0; gsub(/^###### */, ""); print "h6. " $0; next }
    /^#####/  { flush_quote(); table_row = 0; gsub(/^##### */,  ""); print "h5. " $0; next }
    /^####/   { flush_quote(); table_row = 0; gsub(/^#### */,   ""); print "h4. " $0; next }
    /^###/    { flush_quote(); table_row = 0; gsub(/^### */,    ""); print "h3. " $0; next }
    /^##/     { flush_quote(); table_row = 0; gsub(/^## */,     ""); print "h2. " $0; next }
    /^#/      { flush_quote(); table_row = 0; gsub(/^# */,      ""); print "h1. " $0; next }

    # --- Horizontal rules ---
    /^---+$/ || /^\*\*\*+$/ { flush_quote(); table_row = 0; print "----"; next }

    # --- Tables ---
    # Separator rows (|---|---| or |:---:|) — skip but mark that next rows are data
    /^\|[-: |]+\|$/ {
        # The row before this was the header; already printed. Future rows are data.
        next
    }
    /^\|.*\|$/ {
        flush_quote()
        line = $0
        # Apply inline formatting first
        line = convert_inline(line)

        table_row++
        if (table_row == 1) {
            # Header row: || col1 || col2 || col3 ||
            # Split by | and rebuild with ||
            n = split(line, cells, "|")
            result = ""
            for (i = 1; i <= n; i++) {
                # Skip empty cells from leading/trailing |
                if (i == 1 || i == n) {
                    trimmed = cells[i]
                    gsub(/^ +| +$/, "", trimmed)
                    if (trimmed == "") continue
                }
                result = result "|| " cells[i] " "
            }
            result = result "||"
            print result
        } else {
            # Data row: | col1 | col2 | col3 |
            # Just print as-is (pipes are already correct for Confluence data rows)
            print line
        }
        next
    }

    # Non-table line resets table state
    !/^\|/ { table_row = 0 }

    # --- Blockquotes (accumulate consecutive > lines) ---
    /^> / {
        line = $0
        gsub(/^> /, "", line)
        line = convert_inline(line)
        if (!in_quote) {
            in_quote = 1
            quote_buf = line
        } else {
            quote_buf = quote_buf "\n" line
        }
        next
    }

    # Non-quote line — flush any accumulated quote
    { if (in_quote) flush_quote() }

    # --- Unordered lists (up to 3 levels) ---
    /^        - / { gsub(/^        - /, ""); $0 = "**** " convert_inline($0); print; next }
    /^      - /   { gsub(/^      - /,   ""); $0 = "*** "  convert_inline($0); print; next }
    /^    - /     { gsub(/^    - /,     ""); $0 = "** "   convert_inline($0); print; next }
    /^  - /       { gsub(/^  - /,       ""); $0 = "** "   convert_inline($0); print; next }
    /^- /         { gsub(/^- /,         ""); $0 = "* "    convert_inline($0); print; next }

    # --- Ordered lists (up to 2 levels) ---
    /^   [0-9]+\. / { gsub(/^   [0-9]+\. /, ""); $0 = "## " convert_inline($0); print; next }
    /^[0-9]+\. /    { gsub(/^[0-9]+\. /,    ""); $0 = "# "  convert_inline($0); print; next }

    # --- Default: apply inline formatting and print ---
    { print convert_inline($0) }

    # ---- Functions ----

    function flush_quote() {
        if (in_quote) {
            print "{quote}"
            print quote_buf
            print "{quote}"
            in_quote = 0
            quote_buf = ""
        }
    }

    function convert_inline(s) {
        # Bold: **text** -> *text*
        while (match(s, /\*\*[^*]+\*\*/)) {
            pre = substr(s, 1, RSTART-1)
            mid = substr(s, RSTART+2, RLENGTH-4)
            post = substr(s, RSTART+RLENGTH)
            s = pre "*" mid "*" post
        }
        # Inline code: `text` -> {{text}}
        # Escape inner { and } to prevent Confluence macro parsing
        while (match(s, /`[^`]+`/)) {
            pre = substr(s, 1, RSTART-1)
            mid = substr(s, RSTART+1, RLENGTH-2)
            post = substr(s, RSTART+RLENGTH)
            # Escape curly braces inside inline code to prevent macro parsing
            gsub(/[{]/, "\\{", mid)
            gsub(/[}]/, "\\}", mid)
            s = pre "{{" mid "}}" post
        }
        # Links: [text](url) -> [text|url]
        # Cross-doc .md links are converted to Confluence page titles
        while (match(s, /\[[^\]]+\]\([^)]+\)/)) {
            pre = substr(s, 1, RSTART-1)
            full = substr(s, RSTART, RLENGTH)
            post = substr(s, RSTART+RLENGTH)
            # Extract text between [ and ]
            tstart = index(full, "[") + 1
            tend = index(full, "]")
            link_text = substr(full, tstart, tend - tstart)
            # Extract url between ( and )
            ustart = index(full, "(") + 1
            uend = index(full, ")")
            link_url = substr(full, ustart, uend - ustart)
            # Convert .md cross-references to Confluence page links
            if (match(link_url, /\.md(#|$)/)) {
                # Split into filename and optional anchor
                md_file = link_url
                anchor = ""
                if (index(md_file, "#") > 0) {
                    anchor_pos = index(md_file, "#")
                    anchor = substr(md_file, anchor_pos)
                    md_file = substr(md_file, 1, anchor_pos - 1)
                }
                # Strip path prefix and .md extension
                gsub(/.*\//, "", md_file)
                gsub(/\.md$/, "", md_file)
                # Replace hyphens with spaces to match Confluence page titles
                gsub(/-/, " ", md_file)
                # Build Confluence page link: [text|PageTitle#anchor]
                link_url = ENVIRON["CONFLUENCE_PREFIX"] md_file anchor
            }
            s = pre "[" link_text "|" link_url "]" post
        }
        return s
    }
    ' "$input_file" > "$output_file"
}

# --- Process files ---
process_file() {
    local input_file="$1"
    local basename
    basename=$(basename "$input_file" .md)
    local output_file="${OUTPUT_DIR}/${basename}.confluence.txt"

    # Pre-render mermaid diagrams to PNG if a renderer is available
    if [[ "$MERMAID_MODE" != "none" ]]; then
        extract_and_render_mermaid "$input_file" "$basename"
    fi

    convert_to_confluence "$input_file" "$output_file" "$basename"
    echo "  ${basename}.confluence.txt"
}

echo "Exporting to Confluence wiki markup..."
echo "Output directory: ${OUTPUT_DIR}"
echo ""

if [[ -n "$SINGLE_FILE" ]]; then
    process_file "$SINGLE_FILE"
elif [[ "$ENTERPRISE_ONLY" == true ]]; then
    # Process only docs listed in the enterprise manifest
    if [[ ! -f "$MANIFEST_FILE" ]]; then
        echo "Error: Manifest not found: ${MANIFEST_FILE}" >&2
        echo "Expected docs/confluence-manifest.txt with list of enterprise docs." >&2
        exit 1
    fi
    count=0
    while IFS= read -r line; do
        # Strip comments and whitespace
        entry=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -z "$entry" ]] && continue
        filepath="${DOCS_DIR}/${entry}"
        if [[ -f "$filepath" ]]; then
            process_file "$filepath"
            count=$((count + 1))
        else
            echo "  WARNING: ${entry} not found, skipping" >&2
        fi
    done < "$MANIFEST_FILE"
    echo ""
    echo "Exported ${count} enterprise docs (from confluence-manifest.txt)"
else
    # Process all docs
    find "${DOCS_DIR}" -name '*.md' -maxdepth 1 -type f | sort | while read -r f; do
        process_file "$f"
    done

    # Also process deploy READMEs
    for f in \
        "${REPO_ROOT}/deploy/monolith/README.md" \
        "${REPO_ROOT}/deploy/microservices/README.md" \
        "${REPO_ROOT}/deploy/helm/pyroscope/README.md" \
        "${REPO_ROOT}/deploy/grafana/README.md"; do
        if [[ -f "$f" ]]; then
            local_base=$(echo "$f" | sed "s|${REPO_ROOT}/||" | tr '/' '-' | sed 's/\.md$//')
            output_file="${OUTPUT_DIR}/${local_base}.confluence.txt"
            convert_to_confluence "$f" "$output_file"
            echo "  ${local_base}.confluence.txt"
        fi
    done
fi

echo ""
echo "Done. Files are in: ${OUTPUT_DIR}/"
echo ""
echo "To use:"
echo "  1. Open a Confluence page → Edit → Insert → Markup → Confluence Wiki"
echo "  2. Paste the contents of any .confluence.txt file"
echo "  3. Save the page"
echo ""
echo "Or use the Confluence REST API:"
echo '  curl -u user:token -X POST "https://wiki.company.com/rest/api/content" \'
echo '    -H "Content-Type: application/json" \'
echo '    -d "{\"type\":\"page\",\"title\":\"Page Title\",\"space\":{\"key\":\"SPACE\"},\"body\":{\"wiki\":{\"value\":\"$(cat file.confluence.txt)\"}}}"'
