#!/usr/bin/env bash
# =============================================================================
# build-docs-site.sh — Build a local HTML documentation site from Markdown
#
# Generates a polished, browsable HTML site from the docs/ directory with:
#   - Sidebar navigation with collapsible categories
#   - Table of contents per page
#   - Mermaid diagram rendering (client-side via mermaid.js)
#   - Code syntax highlighting (via highlight.js)
#   - Responsive design for desktop and tablet
#   - Full-text search (client-side)
#   - Support for enterprise-only or all docs
#
# Prerequisites:
#   Python 3.8+ (auto-installs markdown and pygments via pip)
#
# Usage:
#   bash scripts/build-docs-site.sh                # All docs
#   bash scripts/build-docs-site.sh --enterprise   # Enterprise docs only (from manifest)
#   bash scripts/build-docs-site.sh --open         # Build and open in browser
#   bash scripts/build-docs-site.sh --output-dir /tmp/docs  # Custom output
#
# Output:
#   docs-site/index.html    (landing page)
#   docs-site/<name>.html   (one page per doc)
#   docs-site/assets/       (CSS, search index)
#
# To view:
#   open docs-site/index.html
#   # or
#   python3 -m http.server 8000 -d docs-site
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCS_DIR="${REPO_ROOT}/docs"
OUTPUT_DIR="${REPO_ROOT}/docs-site"
MANIFEST_FILE="${DOCS_DIR}/confluence-manifest.txt"
ENTERPRISE_ONLY=false
OPEN_BROWSER=false

for arg in "$@"; do
    case "$arg" in
        --enterprise)   ENTERPRISE_ONLY=true ;;
        --open)         OPEN_BROWSER=true ;;
        --output-dir)   shift; OUTPUT_DIR="$2" ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# ====/p' "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
    esac
done

# --- Ensure Python dependencies ---
ensure_python_deps() {
    local missing=false
    python3 -c "import markdown" 2>/dev/null || missing=true
    if [[ "$missing" == "true" ]]; then
        echo "Installing Python dependencies (markdown, pygments)..."
        pip3 install --quiet markdown pygments 2>/dev/null || \
            python3 -m pip install --quiet markdown pygments 2>/dev/null || {
                echo "Error: Failed to install Python markdown library." >&2
                echo "Run: pip3 install markdown pygments" >&2
                exit 1
            }
    fi
}

ensure_python_deps

# --- Build file list ---
build_file_list() {
    if [[ "$ENTERPRISE_ONLY" == "true" ]]; then
        if [[ ! -f "$MANIFEST_FILE" ]]; then
            echo "Error: Manifest not found: ${MANIFEST_FILE}" >&2
            exit 1
        fi
        while IFS= read -r line; do
            entry=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
            [[ -z "$entry" ]] && continue
            filepath="${DOCS_DIR}/${entry}"
            if [[ -f "$filepath" ]]; then
                echo "$filepath"
            else
                echo "  WARNING: ${entry} not found, skipping" >&2
            fi
        done < "$MANIFEST_FILE"
    else
        find "${DOCS_DIR}" -name '*.md' -type f | sort
    fi
}

# --- Parse manifest for categories ---
parse_manifest_categories() {
    # Outputs: category|filepath|description
    local current_category=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^#\ ---\ (.+)\ --- ]]; then
            current_category="${BASH_REMATCH[1]}"
            # Clean up: remove parenthetical
            current_category=$(echo "$current_category" | sed 's/ (.*//')
            continue
        fi
        entry=$(echo "$line" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//')
        [[ -z "$entry" ]] && continue
        desc=$(echo "$line" | sed -n 's/.*# *\[.\] *//p')
        [[ -z "$desc" ]] && desc="$entry"
        echo "${current_category}|${entry}|${desc}"
    done < "$MANIFEST_FILE"
}

echo "Building documentation site..."
echo "  Mode: $([ "$ENTERPRISE_ONLY" == "true" ] && echo "Enterprise only" || echo "All docs")"
echo "  Output: ${OUTPUT_DIR}"
echo ""

mkdir -p "${OUTPUT_DIR}/assets"

# --- Collect files ---
FILES=()
while IFS= read -r f; do
    [[ -n "$f" ]] && FILES+=("$f")
done < <(build_file_list)

echo "  Found ${#FILES[@]} documents"

# --- Build navigation structure ---
if [[ "$ENTERPRISE_ONLY" == "true" ]]; then
    NAV_JSON=$(parse_manifest_categories | python3 -c "
import sys, json
categories = {}
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    parts = line.split('|', 2)
    if len(parts) != 3: continue
    cat, filepath, desc = parts
    if cat not in categories:
        categories[cat] = []
    basename = filepath.replace('.md', '.html').replace('/', '-')
    categories[cat].append({'file': basename, 'title': desc, 'source': filepath})
print(json.dumps(categories))
")
else
    NAV_JSON=$(python3 -c "
import sys, json, os
docs_dir = sys.argv[1]
categories = {'All Documentation': []}
for root, dirs, files in os.walk(docs_dir):
    for f in sorted(files):
        if not f.endswith('.md'): continue
        rel = os.path.relpath(os.path.join(root, f), docs_dir)
        basename = rel.replace('.md', '.html').replace('/', '-')
        title = f.replace('.md', '').replace('-', ' ').title()
        # Read first heading for better title
        try:
            with open(os.path.join(root, f)) as fh:
                first_line = fh.readline().strip()
                if first_line.startswith('#'):
                    title = first_line.lstrip('#').strip()
        except: pass
        categories['All Documentation'].append({'file': basename, 'title': title, 'source': rel})
print(json.dumps(categories))
" "$DOCS_DIR")
fi

# --- Generate CSS ---
cat > "${OUTPUT_DIR}/assets/style.css" << 'CSSEOF'
:root {
    --sidebar-width: 280px;
    --bg: #ffffff;
    --bg-sidebar: #f8f9fa;
    --bg-code: #f4f5f7;
    --text: #1a1a2e;
    --text-muted: #6c757d;
    --accent: #4361ee;
    --accent-light: #e8ecff;
    --border: #dee2e6;
    --success: #10b981;
    --warning: #f59e0b;
    --danger: #ef4444;
    --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    --font-mono: "SF Mono", "Fira Code", "Fira Mono", Menlo, Consolas, monospace;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
    font-family: var(--font-sans);
    color: var(--text);
    line-height: 1.7;
    background: var(--bg);
}

/* --- Layout --- */
.layout { display: flex; min-height: 100vh; }

.sidebar {
    width: var(--sidebar-width);
    background: var(--bg-sidebar);
    border-right: 1px solid var(--border);
    padding: 20px 0;
    position: fixed;
    top: 0;
    left: 0;
    bottom: 0;
    overflow-y: auto;
    z-index: 100;
    transition: transform 0.3s;
}

.sidebar-header {
    padding: 0 20px 16px;
    border-bottom: 1px solid var(--border);
    margin-bottom: 12px;
}

.sidebar-header h2 {
    font-size: 16px;
    font-weight: 700;
    color: var(--accent);
    margin-bottom: 4px;
}

.sidebar-header .subtitle {
    font-size: 11px;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.5px;
}

.search-box {
    padding: 0 16px;
    margin-bottom: 12px;
}

.search-box input {
    width: 100%;
    padding: 8px 12px;
    border: 1px solid var(--border);
    border-radius: 6px;
    font-size: 13px;
    outline: none;
    background: var(--bg);
}

.search-box input:focus { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-light); }

.nav-category {
    padding: 0;
    margin: 0;
}

.nav-category-title {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-muted);
    padding: 12px 20px 6px;
    cursor: pointer;
    user-select: none;
    display: flex;
    justify-content: space-between;
    align-items: center;
}

.nav-category-title::after {
    content: "\25B6";
    font-size: 8px;
    transition: transform 0.2s;
}

.nav-category-title.open::after { transform: rotate(90deg); }

.nav-items { list-style: none; padding: 0; overflow: hidden; }
.nav-items.collapsed { display: none; }

.nav-items a {
    display: block;
    padding: 5px 20px 5px 28px;
    color: var(--text);
    text-decoration: none;
    font-size: 13px;
    border-left: 3px solid transparent;
    transition: all 0.15s;
    line-height: 1.4;
}

.nav-items a:hover { background: var(--accent-light); color: var(--accent); }
.nav-items a.active { border-left-color: var(--accent); background: var(--accent-light); color: var(--accent); font-weight: 600; }

.content {
    flex: 1;
    margin-left: var(--sidebar-width);
    max-width: 900px;
    padding: 40px 48px 80px;
}

/* --- Typography --- */
.content h1 { font-size: 2em; font-weight: 800; margin: 0 0 16px; padding-bottom: 12px; border-bottom: 2px solid var(--border); }
.content h2 { font-size: 1.5em; font-weight: 700; margin: 32px 0 12px; padding-bottom: 8px; border-bottom: 1px solid var(--border); }
.content h3 { font-size: 1.2em; font-weight: 600; margin: 24px 0 8px; }
.content h4 { font-size: 1.05em; font-weight: 600; margin: 20px 0 6px; }
.content h5, .content h6 { font-size: 0.95em; font-weight: 600; margin: 16px 0 4px; }

.content p { margin: 0 0 14px; }
.content a { color: var(--accent); text-decoration: none; }
.content a:hover { text-decoration: underline; }

.content ul, .content ol { margin: 0 0 14px; padding-left: 24px; }
.content li { margin-bottom: 4px; }
.content li > ul, .content li > ol { margin: 4px 0 0; }

.content blockquote {
    border-left: 4px solid var(--accent);
    background: var(--accent-light);
    padding: 12px 16px;
    margin: 0 0 14px;
    border-radius: 0 6px 6px 0;
}

.content blockquote p:last-child { margin-bottom: 0; }

/* --- Code --- */
.content code {
    font-family: var(--font-mono);
    font-size: 0.88em;
    background: var(--bg-code);
    padding: 2px 6px;
    border-radius: 4px;
}

.content pre {
    background: #1e1e2e;
    color: #cdd6f4;
    padding: 16px 20px;
    border-radius: 8px;
    overflow-x: auto;
    margin: 0 0 16px;
    font-size: 13px;
    line-height: 1.5;
}

.content pre code {
    background: none;
    padding: 0;
    color: inherit;
    font-size: inherit;
}

/* --- Tables --- */
.content table {
    width: 100%;
    border-collapse: collapse;
    margin: 0 0 16px;
    font-size: 14px;
}

.content th {
    background: var(--bg-sidebar);
    font-weight: 600;
    text-align: left;
    padding: 10px 12px;
    border: 1px solid var(--border);
}

.content td {
    padding: 8px 12px;
    border: 1px solid var(--border);
    vertical-align: top;
}

.content tr:hover td { background: #fafbfc; }

/* --- Horizontal rule --- */
.content hr { border: none; border-top: 1px solid var(--border); margin: 24px 0; }

/* --- Images --- */
.content img { max-width: 100%; height: auto; border-radius: 6px; margin: 8px 0; }

/* --- Mermaid --- */
.mermaid {
    background: var(--bg);
    text-align: center;
    padding: 16px;
    margin: 12px 0;
    border: 1px solid var(--border);
    border-radius: 8px;
}

/* --- TOC --- */
.toc {
    background: var(--bg-sidebar);
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 16px 20px;
    margin: 0 0 24px;
    font-size: 14px;
}

.toc-title {
    font-weight: 700;
    font-size: 13px;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    color: var(--text-muted);
    margin-bottom: 8px;
}

.toc ul { list-style: none; padding-left: 0; margin: 0; }
.toc ul ul { padding-left: 16px; }
.toc li { margin: 3px 0; }
.toc a { color: var(--text); font-size: 13px; }
.toc a:hover { color: var(--accent); }

/* --- Mobile --- */
.menu-toggle {
    display: none;
    position: fixed;
    top: 12px;
    left: 12px;
    z-index: 200;
    background: var(--accent);
    color: white;
    border: none;
    border-radius: 6px;
    padding: 8px 12px;
    cursor: pointer;
    font-size: 14px;
}

@media (max-width: 768px) {
    .sidebar { transform: translateX(-100%); }
    .sidebar.open { transform: translateX(0); box-shadow: 4px 0 20px rgba(0,0,0,0.15); }
    .content { margin-left: 0; padding: 60px 20px 40px; }
    .menu-toggle { display: block; }
}

/* --- Index page --- */
.index-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 16px;
    margin: 20px 0;
}

.index-card {
    border: 1px solid var(--border);
    border-radius: 8px;
    padding: 16px;
    transition: all 0.2s;
}

.index-card:hover { border-color: var(--accent); box-shadow: 0 2px 8px rgba(67, 97, 238, 0.12); }
.index-card h3 { font-size: 14px; margin: 0 0 4px; }
.index-card h3 a { color: var(--text); }
.index-card h3 a:hover { color: var(--accent); }
.index-card p { font-size: 12px; color: var(--text-muted); margin: 0; line-height: 1.4; }
.category-badge {
    display: inline-block;
    font-size: 10px;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.5px;
    padding: 2px 8px;
    border-radius: 4px;
    margin-bottom: 8px;
}

.badge-explanation { background: #dbeafe; color: #1e40af; }
.badge-tutorials { background: #d1fae5; color: #065f46; }
.badge-how-to { background: #fef3c7; color: #92400e; }
.badge-reference { background: #f3e8ff; color: #6b21a8; }
.badge-adr { background: #fce7f3; color: #9d174d; }
.badge-templates { background: #e5e7eb; color: #374151; }
CSSEOF

echo "  Generated CSS"

# --- Generate the Python converter script ---
cat > "${OUTPUT_DIR}/assets/convert.py" << 'PYEOF'
#!/usr/bin/env python3
"""Convert markdown files to HTML with mermaid support and TOC generation."""

import sys
import os
import re
import json
import markdown
from markdown.extensions.toc import TocExtension
from markdown.extensions.tables import TableExtension
from markdown.extensions.fenced_code import FencedCodeExtension
from markdown.extensions.codehilite import CodeHiliteExtension

def extract_mermaid_blocks(md_text):
    """Replace mermaid code blocks with div placeholders, return modified text."""
    counter = [0]
    def replacer(match):
        counter[0] += 1
        diagram = match.group(1).strip()
        return f'\n<div class="mermaid" id="mermaid-{counter[0]}">\n{diagram}\n</div>\n'
    # Match ```mermaid ... ```
    result = re.sub(
        r'```mermaid\s*\n(.*?)```',
        replacer,
        md_text,
        flags=re.DOTALL
    )
    return result, counter[0] > 0

def fix_internal_links(html_text):
    """Convert .md links to .html links."""
    def replacer(match):
        prefix = match.group(1)
        path = match.group(2)
        anchor = match.group(3) or ''
        # Convert path: strip .md, replace / with -
        html_path = path.replace('.md', '').replace('/', '-') + '.html'
        return f'{prefix}"{html_path}{anchor}"'
    return re.sub(
        r'(href=")([^"]*?)\.md(#[^"]*)?(")',
        lambda m: f'{m.group(1)}{m.group(2).replace("/", "-")}.html{m.group(3) or ""}{m.group(4)}',
        html_text
    )

def convert_file(input_path, docs_dir):
    """Convert a markdown file to HTML body + TOC."""
    with open(input_path, 'r', encoding='utf-8') as f:
        text = f.read()

    # Extract mermaid before markdown processing
    text, has_mermaid = extract_mermaid_blocks(text)

    md = markdown.Markdown(extensions=[
        TocExtension(permalink=False, toc_depth='2-3'),
        TableExtension(),
        FencedCodeExtension(),
        'markdown.extensions.sane_lists',
        'markdown.extensions.smarty',
    ])

    html_body = md.convert(text)
    toc_html = md.toc

    # Fix internal links
    html_body = fix_internal_links(html_body)

    return html_body, toc_html, has_mermaid

def build_page(title, body, toc, nav_html, has_mermaid, current_file):
    """Wrap body in full HTML page."""
    mermaid_script = ""
    if has_mermaid:
        mermaid_script = '''
    <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
    <script>
        mermaid.initialize({
            startOnLoad: true,
            theme: 'default',
            securityLevel: 'loose',
            flowchart: { useMaxWidth: true, htmlLabels: true },
            sequence: { useMaxWidth: true },
            themeVariables: {
                fontSize: '14px'
            }
        });
    </script>'''

    toc_section = ""
    if toc and toc.strip() and '<li>' in toc:
        toc_section = f'''
        <div class="toc">
            <div class="toc-title">On This Page</div>
            {toc}
        </div>'''

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>{title} — Pyroscope Documentation</title>
    <link rel="stylesheet" href="assets/style.css">
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
    <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
    <script>hljs.highlightAll();</script>
    {mermaid_script}
</head>
<body>
    <button class="menu-toggle" onclick="document.querySelector('.sidebar').classList.toggle('open')">Menu</button>
    <div class="layout">
        <nav class="sidebar">
            <div class="sidebar-header">
                <h2>Pyroscope Docs</h2>
                <div class="subtitle">Continuous Profiling Platform</div>
            </div>
            <div class="search-box">
                <input type="text" id="search" placeholder="Search docs..." oninput="filterNav(this.value)">
            </div>
            <div id="nav-container">
                {nav_html}
            </div>
        </nav>
        <main class="content">
            {toc_section}
            {body}
        </main>
    </div>
    <script>
        // Sidebar navigation
        document.querySelectorAll('.nav-category-title').forEach(el => {{
            el.classList.add('open');
            el.addEventListener('click', () => {{
                el.classList.toggle('open');
                el.nextElementSibling.classList.toggle('collapsed');
            }});
        }});

        // Mark active page
        document.querySelectorAll('.nav-items a').forEach(a => {{
            if (a.getAttribute('href') === '{current_file}') {{
                a.classList.add('active');
            }}
        }});

        // Search filter
        function filterNav(query) {{
            query = query.toLowerCase();
            document.querySelectorAll('.nav-items a').forEach(a => {{
                const text = a.textContent.toLowerCase();
                a.style.display = text.includes(query) || !query ? '' : 'none';
            }});
            // Show all categories when searching
            document.querySelectorAll('.nav-items').forEach(ul => {{
                if (query) ul.classList.remove('collapsed');
            }});
        }}
    </script>
</body>
</html>'''

if __name__ == '__main__':
    # Args: docs_dir output_dir nav_json files...
    docs_dir = sys.argv[1]
    output_dir = sys.argv[2]
    nav_data = json.loads(sys.argv[3])
    files = sys.argv[4:]

    # Build nav HTML
    badge_classes = {
        'Explanation': 'badge-explanation',
        'Tutorials': 'badge-tutorials',
        'How-to guides': 'badge-how-to',
        'Reference': 'badge-reference',
        'Architecture Decision Records': 'badge-adr',
        'Templates': 'badge-templates',
        'All Documentation': 'badge-reference',
    }

    nav_html = '<a href="index.html" class="nav-items" style="display:block;padding:8px 20px;font-weight:600;font-size:13px;color:var(--accent);text-decoration:none;margin-bottom:4px;">Home</a>\n'
    for category, items in nav_data.items():
        nav_html += f'<div class="nav-category">\n'
        nav_html += f'  <div class="nav-category-title">{category}</div>\n'
        nav_html += f'  <ul class="nav-items">\n'
        for item in items:
            nav_html += f'    <li><a href="{item["file"]}">{item["title"]}</a></li>\n'
        nav_html += f'  </ul>\n</div>\n'

    # Build index data for the landing page
    index_cards = []

    # Convert each file
    for filepath in files:
        rel_path = os.path.relpath(filepath, docs_dir)
        out_name = rel_path.replace('.md', '.html').replace('/', '-')
        out_path = os.path.join(output_dir, out_name)

        # Get title from first heading
        with open(filepath, 'r', encoding='utf-8') as f:
            first_line = f.readline().strip()
        title = first_line.lstrip('#').strip() if first_line.startswith('#') else rel_path.replace('.md', '').replace('-', ' ').title()

        # Find category for this file
        file_category = 'Documentation'
        file_desc = ''
        for cat, items in nav_data.items():
            for item in items:
                if item['file'] == out_name:
                    file_category = cat
                    file_desc = item.get('title', '')
                    break

        try:
            body, toc, has_mermaid = convert_file(filepath, docs_dir)
            html = build_page(title, body, toc, nav_html, has_mermaid, out_name)

            with open(out_path, 'w', encoding='utf-8') as f:
                f.write(html)

            index_cards.append({
                'file': out_name,
                'title': title,
                'desc': file_desc,
                'category': file_category,
            })
            print(f"  {out_name}")
        except Exception as e:
            print(f"  ERROR: {rel_path} — {e}", file=sys.stderr)

    # Build index page
    cards_html = ''
    current_cat = ''
    for card in index_cards:
        if card['category'] != current_cat:
            if current_cat:
                cards_html += '</div>\n'
            current_cat = card['category']
            badge = badge_classes.get(current_cat, 'badge-reference')
            cards_html += f'<h2>{current_cat}</h2>\n<div class="index-grid">\n'
        badge = badge_classes.get(card['category'], 'badge-reference')
        cards_html += f'''<div class="index-card">
    <span class="category-badge {badge}">{card['category']}</span>
    <h3><a href="{card['file']}">{card['title']}</a></h3>
    <p>{card['desc']}</p>
</div>\n'''
    if current_cat:
        cards_html += '</div>\n'

    index_body = f'''
        <h1>Pyroscope Documentation</h1>
        <p>Enterprise documentation for Pyroscope continuous profiling platform.
        {len(index_cards)} documents organized by the
        <a href="https://diataxis.fr/">Diataxis framework</a>.</p>
        <hr>
        {cards_html}
    '''

    index_html = build_page('Home', index_body, '', nav_html, False, 'index.html')
    with open(os.path.join(output_dir, 'index.html'), 'w', encoding='utf-8') as f:
        f.write(index_html)
    print("  index.html")
PYEOF

echo "  Generated converter"

# --- Run the converter ---
echo ""
echo "Converting documents..."

python3 "${OUTPUT_DIR}/assets/convert.py" \
    "$DOCS_DIR" \
    "$OUTPUT_DIR" \
    "$NAV_JSON" \
    "${FILES[@]}"

echo ""
echo "Done. Site built at: ${OUTPUT_DIR}/"
echo ""
echo "To view:"
echo "  open ${OUTPUT_DIR}/index.html"
echo "  # or serve locally:"
echo "  python3 -m http.server 8000 -d ${OUTPUT_DIR}"

# --- Open in browser ---
if [[ "$OPEN_BROWSER" == "true" ]]; then
    if command -v open &>/dev/null; then
        open "${OUTPUT_DIR}/index.html"
    elif command -v xdg-open &>/dev/null; then
        xdg-open "${OUTPUT_DIR}/index.html"
    else
        echo "Cannot auto-open browser. Open ${OUTPUT_DIR}/index.html manually."
    fi
fi
