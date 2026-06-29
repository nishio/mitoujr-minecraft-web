#!/usr/bin/env bash
# Publish the public site after an explicit GO.
#
# Default mode is a dry run. Use --live only after the human has given explicit
# publish GO.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LIVE=0
REMOTE="${REMOTE:-origin}"
BRANCH="${BRANCH:-main}"
BASE_URL="${BASE_URL:-https://nishio.github.io/mitoujr-minecraft-web}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-180}"

usage() {
  cat <<'USAGE'
usage:
  scripts/publish-public-site.sh [--dry-run|--live]

Default: --dry-run

What --live does:
  1. runs scripts/check-public-site.sh
  2. pushes the current branch to origin/main
  3. waits for GitHub Pages URLs to return HTTP 200 and match local files

Run --live only after explicit publish GO.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) LIVE=0 ;;
    --live) LIVE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

echo "==> repository"
git status --short --branch
head_commit="$(git rev-parse --short HEAD)"
echo "HEAD: $(git log -1 --oneline)"

current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" != "$BRANCH" ]; then
  echo "error: expected branch $BRANCH, got $current_branch" >&2
  exit 1
fi

if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "error: remote not found: $REMOTE" >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree has uncommitted changes" >&2
  exit 1
fi

if git rev-parse --verify "$REMOTE/$BRANCH" >/dev/null 2>&1; then
  ahead_count="$(git rev-list --count "$REMOTE/$BRANCH"..HEAD)"
  behind_count="$(git rev-list --count HEAD.."$REMOTE/$BRANCH")"
else
  ahead_count="unknown"
  behind_count="unknown"
fi

echo "ahead: $ahead_count"
echo "behind: $behind_count"

if [ "$behind_count" != "0" ]; then
  echo "error: local branch is behind $REMOTE/$BRANCH; pull/rebase intentionally before publishing" >&2
  exit 1
fi

if [ "$ahead_count" = "0" ]; then
  echo "nothing to publish: HEAD is already at $REMOTE/$BRANCH"
  exit 0
fi

echo "==> prepublish check"
scripts/check-public-site.sh

changed_public_files=()
if git rev-parse --verify "$REMOTE/$BRANCH" >/dev/null 2>&1; then
  while IFS= read -r path; do
    case "$path" in
      *.html|sitemap.xml|robots.txt) changed_public_files+=("$path") ;;
    esac
  done < <(git diff --name-only "$REMOTE/$BRANCH"..HEAD)
fi
if [ "${#changed_public_files[@]}" -eq 0 ]; then
  changed_public_files=("index.html")
fi

echo "==> public files to verify"
printf '  %s\n' "${changed_public_files[@]}"
echo "verification: HTTP 200 and exact local content match"

if [ "$LIVE" -ne 1 ]; then
  cat <<EOF

dry-run complete.
To publish after explicit GO:
  scripts/publish-public-site.sh --live
EOF
  exit 0
fi

echo "==> push"
git push "$REMOTE" "HEAD:$BRANCH"

echo "==> wait for GitHub Pages content match"
deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mitoujr-pages-check.XXXXXX")"
cleanup_pages_check() {
  rm -rf "$tmp_dir"
}
trap cleanup_pages_check EXIT
while :; do
  all_ok=1
  for path in "${changed_public_files[@]}"; do
    url="$BASE_URL/${path#./}"
    live_file="$tmp_dir/$(printf '%s' "$path" | tr '/.' '__')"
    status="$(curl -fsS -o "$live_file" -w '%{http_code}' "$url" || true)"
    if [ "$status" != "200" ]; then
      all_ok=0
      printf '  waiting: %s -> %s\n' "$url" "$status"
      continue
    fi
    if ! cmp -s "$path" "$live_file"; then
      all_ok=0
      printf '  waiting: %s -> 200 but content not updated\n' "$url"
    fi
  done
  if [ "$all_ok" -eq 1 ]; then
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "error: timed out waiting for GitHub Pages" >&2
    exit 1
  fi
  sleep 5
done

cat <<EOF
published: $head_commit
live: $BASE_URL/
verified: changed public files match GitHub Pages content
EOF
