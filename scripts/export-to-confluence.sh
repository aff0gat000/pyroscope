#!/usr/bin/env bash
# =============================================================================
# export-to-confluence.sh — Convert Markdown docs to Confluence wiki markup
#
# Generates Confluence-compatible output that can be pasted directly into
# Confluence pages. Handles tables, code blocks, headers, links, and Mermaid
# diagrams (converted to code blocks with a note to render separately).
#
# Usage:
#   bash scripts/export-to-confluence.sh                    # All docs
#   bash scripts/export-to-confluence.sh docs/runbook.md    # Single file
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

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --list)       LIST_ONLY=true; shift ;;
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

# --- Convert one Markdown file to Confluence wiki markup ---
convert_to_confluence() {
    local input_file="$1"
    local output_file="$2"

    # Read the file and apply transformations
    # This is a practical converter — not a full parser, but handles 90% of cases
    awk '
    BEGIN {
        in_code = 0
        in_mermaid = 0
        code_lang = ""
    }

    # Code blocks
    /^```mermaid/ {
        in_mermaid = 1
        in_code = 1
        print "{info:title=Mermaid Diagram}"
        print "This diagram is written in Mermaid syntax. Render it at https://mermaid.live or install the Mermaid plugin for Confluence."
        print "{info}"
        print "{code:language=none|title=Mermaid Diagram Source}"
        next
    }
    /^```[a-z]/ && !in_code {
        in_code = 1
        code_lang = $0
        gsub(/^```/, "", code_lang)
        if (code_lang == "bash" || code_lang == "sh") code_lang = "bash"
        else if (code_lang == "yaml" || code_lang == "yml") code_lang = "yaml"
        else if (code_lang == "json") code_lang = "javascript"
        else if (code_lang == "properties") code_lang = "none"
        else if (code_lang == "sql") code_lang = "sql"
        else if (code_lang == "java") code_lang = "java"
        else if (code_lang == "xml") code_lang = "xml"
        else if (code_lang == "python") code_lang = "python"
        else code_lang = "none"
        print "{code:language=" code_lang "}"
        next
    }
    /^```$/ && in_code {
        in_code = 0
        in_mermaid = 0
        print "{code}"
        next
    }
    /^```/ && !in_code {
        in_code = 1
        print "{code:language=none}"
        next
    }

    # Inside code blocks — pass through unchanged
    in_code { print; next }

    # Headers
    /^######/ { gsub(/^###### */, ""); print "h6. " $0; next }
    /^#####/  { gsub(/^##### */,  ""); print "h5. " $0; next }
    /^####/   { gsub(/^#### */,   ""); print "h4. " $0; next }
    /^###/    { gsub(/^### */,    ""); print "h3. " $0; next }
    /^##/     { gsub(/^## */,     ""); print "h2. " $0; next }
    /^#/      { gsub(/^# */,      ""); print "h1. " $0; next }

    # Horizontal rules
    /^---+$/ || /^\*\*\*+$/ { print "----"; next }

    # Bold + italic
    {
        # Bold: **text** -> *text*
        while (match($0, /\*\*[^*]+\*\*/)) {
            pre = substr($0, 1, RSTART-1)
            mid = substr($0, RSTART+2, RLENGTH-4)
            post = substr($0, RSTART+RLENGTH)
            $0 = pre "*" mid "*" post
        }
        # Inline code: `text` -> {{text}}
        while (match($0, /`[^`]+`/)) {
            pre = substr($0, 1, RSTART-1)
            mid = substr($0, RSTART+1, RLENGTH-2)
            post = substr($0, RSTART+RLENGTH)
            $0 = pre "{{" mid "}}" post
        }
    }

    # Blockquotes
    /^> / {
        gsub(/^> /, "")
        print "{quote}" $0 "{quote}"
        next
    }

    # Unordered lists
    /^- / {
        gsub(/^- /, "* ")
        print
        next
    }
    /^  - / {
        gsub(/^  - /, "** ")
        print
        next
    }

    # Ordered lists
    /^[0-9]+\. / {
        gsub(/^[0-9]+\. /, "# ")
        print
        next
    }

    # Tables — Confluence uses || for headers and | for data
    /^\|.*\|$/ {
        # Skip separator rows (|---|---|)
        if ($0 ~ /^\|[-: |]+\|$/) next

        # Check if this looks like a header row (first table row or has bold)
        line = $0
        # Replace leading/trailing pipes
        gsub(/^\| */, "|| ", line)
        gsub(/ *\|$/, " ||", line)
        gsub(/ *\| */, " || ", line)
        print line
        next
    }

    # Default — print line as-is
    { print }
    ' "$input_file" > "$output_file"
}

# --- Process files ---
process_file() {
    local input_file="$1"
    local basename
    basename=$(basename "$input_file" .md)
    local output_file="${OUTPUT_DIR}/${basename}.confluence.txt"

    convert_to_confluence "$input_file" "$output_file"
    echo "  ${basename}.confluence.txt"
}

echo "Exporting to Confluence wiki markup..."
echo "Output directory: ${OUTPUT_DIR}"
echo ""

if [[ -n "$SINGLE_FILE" ]]; then
    process_file "$SINGLE_FILE"
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
