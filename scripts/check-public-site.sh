#!/usr/bin/env bash
# Local pre-publish checks for the public site.
#
# This script is safe to commit to the public repo: it contains generic scrub
# patterns only. If a local machine needs private exact-match rules, put them in
# PRIVATE_FORBIDDEN_REGEX_FILE; do not commit that file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SERVE=1
RESPONSIVE=1
RESPONSIVE_CHANGED=0
RESPONSIVE_BASE="${RESPONSIVE_BASE:-origin/main}"
PORT="${PORT:-}"
PRIVATE_FORBIDDEN_REGEX_FILE="${PRIVATE_FORBIDDEN_REGEX_FILE:-$HOME/.config/mitoujr-public-forbidden.regex}"

usage() {
  cat <<'USAGE'
usage:
  scripts/check-public-site.sh [--no-serve] [--no-responsive] [--responsive-changed] [--responsive-base <ref>]

Checks:
  - git diff whitespace/errors
  - HTML parse and local href/src file targets
  - sitemap.xml and robots.txt are current
  - generic public scrub patterns in HTML/CSS
  - local HTTP 200 for every HTML page, unless --no-serve is passed
  - responsive overflow and image checks with local Chrome, when available
    Use --responsive-changed to run that expensive responsive pass only against
    HTML pages changed from the base ref plus staged, unstaged, and untracked
    local HTML files.

Optional:
  RESPONSIVE_BASE=origin/main
  PRIVATE_FORBIDDEN_REGEX_FILE=/path/to/local.regex

The optional regex file is for exact private values and must stay outside this
public repository.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-serve) SERVE=0 ;;
    --no-responsive) RESPONSIVE=0 ;;
    --responsive-changed) RESPONSIVE_CHANGED=1 ;;
    --responsive-base)
      shift
      if [ "$#" -eq 0 ]; then
        echo "missing value for --responsive-base" >&2
        exit 2
      fi
      RESPONSIVE_BASE="$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

echo "==> git diff --check"
git diff --check

echo "==> html parse and local links"
python3 - <<'PY'
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote
import re
import sys

root = Path(".").resolve()
html_paths = sorted(root.rglob("*.html"))

class PageParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.refs = []
        self.ids = set()

    def handle_starttag(self, tag, attrs):
        data = dict(attrs)
        if "id" in data:
            self.ids.add(data["id"])
        if "name" in data:
            self.ids.add(data["name"])
        for attr in ("href", "src"):
            value = data.get(attr)
            if value:
                self.refs.append((tag, attr, value))

pages = {}
errors = []
for path in html_paths:
    parser = PageParser()
    text = path.read_text(encoding="utf-8")
    try:
        parser.feed(text)
    except Exception as exc:
        errors.append(f"{path.relative_to(root)}: HTML parser error: {exc}")
    pages[path] = parser

scheme_re = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.-]*:")
for path, parser in pages.items():
    for tag, attr, ref in parser.refs:
        if ref.startswith("#"):
            fragment = unquote(ref[1:])
            if fragment and fragment not in parser.ids:
                errors.append(f"{path.relative_to(root)}: missing local fragment #{fragment}")
            continue
        if scheme_re.match(ref) or ref.startswith("//"):
            continue
        target_part, _, fragment = ref.partition("#")
        target_part = unquote(target_part)
        if not target_part:
            continue
        target = (path.parent / target_part).resolve()
        try:
            target.relative_to(root)
        except ValueError:
            errors.append(f"{path.relative_to(root)}: {attr} escapes repo: {ref}")
            continue
        if not target.exists():
            errors.append(f"{path.relative_to(root)}: missing {attr} target: {ref}")
            continue
        if fragment and target.suffix == ".html":
            target_parser = pages.get(target)
            if target_parser and fragment not in target_parser.ids:
                errors.append(f"{path.relative_to(root)}: missing fragment in {ref}")

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"ok: parsed {len(html_paths)} html files")
PY

echo "==> sitemap and robots"
tmp_sitemap="$(mktemp "${TMPDIR:-/tmp}/mitoujr-public-sitemap.XXXXXX")"
python3 scripts/generate-sitemap.py >"$tmp_sitemap"
if ! cmp -s sitemap.xml "$tmp_sitemap"; then
  echo "error: sitemap.xml is stale; run scripts/generate-sitemap.py > sitemap.xml" >&2
  diff -u sitemap.xml "$tmp_sitemap" >&2 || true
  rm -f "$tmp_sitemap"
  exit 1
fi
rm -f "$tmp_sitemap"
if ! grep -Fx 'Sitemap: https://nishio.github.io/mitoujr-minecraft-web/sitemap.xml' robots.txt >/dev/null; then
  echo "error: robots.txt does not reference the public sitemap" >&2
  exit 1
fi
echo "ok: sitemap covers $(find . -name '*.html' -type f | wc -l | tr -d ' ') html files"

echo "==> generic public scrub"
SCRUB_FILES=()
while IFS= read -r file; do
  SCRUB_FILES+=("$file")
done < <(find . \( -name '*.html' -o -name '*.xml' -o -name 'robots.txt' -o -path './css/*.css' \) -type f | sort)
HTML_FILES=()
while IFS= read -r file; do
  HTML_FILES+=("$file")
done < <(find . -name '*.html' -type f | sort)
GENERIC_PATTERNS=(
  'server[.]properties'
  '/Users/'
  '(^|[^[:alnum:]_])tools/'
  '[.]nix([^[:alnum:]_-]|$)'
  '\b[a-z]{1,6}-[0-9a-f]{8,}\b'
  '\b(token|secret|password)\b'
)
for pattern in "${GENERIC_PATTERNS[@]}"; do
  if rg -n -i -e "$pattern" -- "${SCRUB_FILES[@]}" >/tmp/mitoujr-public-scrub-hit.txt; then
    cat /tmp/mitoujr-public-scrub-hit.txt >&2
    echo "error: generic public scrub pattern matched: $pattern" >&2
    exit 1
  fi
done

HTML_ONLY_PATTERNS=(
  '\(-?[0-9]{1,5},[[:space:]]*-?[0-9]{1,5},[[:space:]]*-?[0-9]{1,5}\)'
  '\b-?[0-9]{1,5},[[:space:]]*-?[0-9]{1,5},[[:space:]]*-?[0-9]{1,5}\b'
)
for pattern in "${HTML_ONLY_PATTERNS[@]}"; do
  if rg -n -i -e "$pattern" -- "${HTML_FILES[@]}" >/tmp/mitoujr-public-scrub-hit.txt; then
    cat /tmp/mitoujr-public-scrub-hit.txt >&2
    echo "error: generic public scrub pattern matched: $pattern" >&2
    exit 1
  fi
done

if [ -f "$PRIVATE_FORBIDDEN_REGEX_FILE" ]; then
  echo "==> private local scrub rules: $PRIVATE_FORBIDDEN_REGEX_FILE"
  while IFS= read -r pattern; do
    case "$pattern" in
      ''|'#'*) continue ;;
    esac
    if rg -n -i -e "$pattern" -- "${SCRUB_FILES[@]}" >/tmp/mitoujr-public-private-hit.txt; then
      cat /tmp/mitoujr-public-private-hit.txt >&2
      echo "error: private local scrub pattern matched" >&2
      exit 1
    fi
  done < "$PRIVATE_FORBIDDEN_REGEX_FILE"
else
  echo "skip: no private local scrub regex file"
fi

if [ "$SERVE" -eq 1 ]; then
  echo "==> local HTTP 200"
  if [ -z "$PORT" ]; then
    PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    print(s.getsockname()[1])
PY
)"
  fi
  log_dir="$(mktemp -d "${TMPDIR:-/tmp}/mitoujr-public-site.XXXXXX")"
  log_file="$log_dir/server.log"
  python3 -m http.server "$PORT" --bind 127.0.0.1 >"$log_file" 2>&1 &
  server_pid="$!"
  cleanup_server() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    rm -rf "$log_dir"
  }
  trap cleanup_server EXIT
  sleep 1
  if ! kill -0 "$server_pid" 2>/dev/null; then
    cat "$log_file" >&2
    echo "error: local server failed to start" >&2
    exit 1
  fi
  for file in "${SCRUB_FILES[@]}"; do
    case "$file" in
      *.html|*.xml|./robots.txt)
        url_path="${file#./}"
        curl -fsS -o /dev/null "http://127.0.0.1:$PORT/$url_path"
        ;;
    esac
  done
  echo "ok: local HTTP served public html/xml/robots files"

  if [ "$RESPONSIVE" -eq 1 ]; then
    echo "==> responsive overflow check"
    if command -v node >/dev/null 2>&1; then
      if [ "$RESPONSIVE_CHANGED" -eq 1 ]; then
        changed_pages="$log_dir/responsive-pages.txt"
        {
          if git rev-parse --verify --quiet "$RESPONSIVE_BASE" >/dev/null; then
            git diff --name-only --diff-filter=ACMRT "$RESPONSIVE_BASE"...HEAD -- '*.html'
          else
            echo "warning: responsive base not found, skipping committed diff: $RESPONSIVE_BASE" >&2
          fi
          git diff --name-only --diff-filter=ACMRT -- '*.html'
          git diff --cached --name-only --diff-filter=ACMRT -- '*.html'
          git ls-files --others --exclude-standard -- '*.html'
        } | sed '/^$/d' | sort -u >"$changed_pages"
        if [ ! -s "$changed_pages" ]; then
          echo "skip: no changed HTML pages for responsive check"
        else
          page_count="$(wc -l <"$changed_pages" | tr -d ' ')"
          echo "checking $page_count changed HTML page(s) against $RESPONSIVE_BASE"
          responsive_args=(--base-url "http://127.0.0.1:$PORT")
          while IFS= read -r page; do
            responsive_args+=(--page "$page")
          done <"$changed_pages"
          node scripts/check-responsive.mjs "${responsive_args[@]}"
        fi
      else
        node scripts/check-responsive.mjs --base-url "http://127.0.0.1:$PORT"
      fi
    else
      echo "skip: node not found for responsive check"
    fi
  fi
fi

echo "ok: public site checks complete"
