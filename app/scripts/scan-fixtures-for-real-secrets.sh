#!/bin/bash
# roadmap: S-17 · Ported from Obscura's Scripts/scan-fixtures-for-real-secrets.sh (Obscura G-41), for Vitrine's paths.
# Fails if any tracked text file outside the made-up test trees contains a string shaped like a LIVE credential.
# Every secret in this repository must be made up; this is the gate that proves the ignored trees are the only place
# token-shaped text lives, so .github/secret_scanning.yml's paths-ignore hides nothing else from push protection.
#
# The allowed trees are read from .github/secret_scanning.yml itself (one source of truth: a path added there is
# allowed here, and nothing else is), plus EXTRA_ALLOW below for files that name a key shape without holding a key.
#
#   scan-fixtures-for-real-secrets.sh [repo root]    default: the git top level of the current folder
#
# Exit 0 "fixtures clean"; exit 1 with the hits (path:line:match) otherwise. Hits inside the allowed trees are counted,
# never printed, so the log carries no token-shaped text.
set -euo pipefail
ROOT="${1:-$(git rev-parse --show-toplevel)}"
cd "$ROOT"
CONFIG=.github/secret_scanning.yml
[ -f "$CONFIG" ] || { echo "no $CONFIG in $ROOT: push protection would scan the test fixtures and refuse the push"; exit 1; }

# Files that describe a key shape (a detector's catalogue entry) without holding a key.
EXTRA_ALLOW=(
  "app/Packages/Sources/VitrineDetect/Catalog/BuiltInCatalogue.swift"   # the PEM header as a detector's anchor; no body
)

allow=()
while IFS= read -r line; do
  p="$(printf '%s' "$line" | sed -E 's/^[[:space:]]*-[[:space:]]*"?([^"]*)"?[[:space:]]*$/\1/')"
  p="${p%\*\*}"; p="${p%\*}"
  [ -n "$p" ] && allow+=("$p")
done < <(sed -n '/^paths-ignore:/,/^[^[:space:]-]/p' "$CONFIG" | grep -E '^[[:space:]]*-')
allow+=("${EXTRA_ALLOW[@]}")
[ ${#allow[@]} -gt 0 ] || { echo "no paths-ignore entries read from $CONFIG"; exit 1; }

# Obscura's shapes (almost never false positives for real keys), plus the provider shapes Vitrine's fixtures add.
PATTERN='AKIA[A-Z0-9]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{80,}|sk_live_[A-Za-z0-9]{24,}|xoxb-[0-9]{10,}-[0-9]{10,}-[A-Za-z0-9]{20,}|sk-ant-api03-[A-Za-z0-9_-]{80,}|glpat-[A-Za-z0-9_-]{20}|-----BEGIN (RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----'

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  list() { git ls-files -z; }
else
  list() { find . -type f -not -path './.git/*' -print0; }
fi

hits=""; ignored=0
while IFS= read -r -d '' f; do
  f="${f#./}"
  [ -f "$f" ] || continue
  m="$(grep -nIoE "$PATTERN" -- "$f" 2>/dev/null || true)"
  [ -n "$m" ] || continue
  allowed=0
  for a in "${allow[@]}"; do case "$f" in "$a"*) allowed=1; break;; esac; done
  if [ $allowed = 1 ]; then
    ignored=$((ignored + $(printf '%s\n' "$m" | wc -l)))
  else
    hits+="$(printf '%s\n' "$m" | sed "s#^#$f:#")"$'\n'
  fi
done < <(list)

if [ -n "$hits" ]; then
  echo "Possible real credential shapes outside the made-up test trees (allowed: ${allow[*]}):"
  printf '%s' "$hits"
  exit 1
fi
echo "fixtures clean (${ignored} made-up key shapes, all inside: ${allow[*]})"
