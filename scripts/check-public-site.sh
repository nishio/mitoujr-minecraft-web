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
PORT="${PORT:-}"
PRIVATE_FORBIDDEN_REGEX_FILE="${PRIVATE_FORBIDDEN_REGEX_FILE:-$HOME/.config/mitoujr-public-forbidden.regex}"

usage() {
  cat <<'USAGE'
usage:
  scripts/check-public-site.sh [--no-serve]

Checks:
  - git diff whitespace/errors
  - HTML parse and local href/src file targets
  - generic public scrub patterns in HTML/CSS
  - local HTTP 200 for every HTML page, unless --no-serve is passed

Optional:
  PRIVATE_FORBIDDEN_REGEX_FILE=/path/to/local.regex

The optional regex file is for exact private values and must stay outside this
public repository.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-serve) SERVE=0 ;;
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

echo "==> generic public scrub"
SCRUB_FILES=()
while IFS= read -r file; do
  SCRUB_FILES+=("$file")
done < <(find . \( -name '*.html' -o -path './css/*.css' \) -type f | sort)
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
      *.html)
        url_path="${file#./}"
        curl -fsS -o /dev/null "http://127.0.0.1:$PORT/$url_path"
        ;;
    esac
  done
  echo "ok: local HTTP served $(find . -name '*.html' -type f | wc -l | tr -d ' ') html files"
fi

echo "ok: public site checks complete"
