#!/bin/bash
# Sets MARKETING_VERSION to <semver> and increments CURRENT_PROJECT_VERSION in app/project.yml (ported from Obscura's
# Scripts/bump-version.sh). The build number only ever goes up: the updater offers a release only when its build is
# newer than the running one (G-21). roadmap: S-13
#
#   app/scripts/bump-version.sh <semver>            edit project.yml and print the result
#   app/scripts/bump-version.sh <semver> --commit   also commit project.yml and tag v<semver> (local; nothing is pushed)
#   VITRINE_PROJECT_SPEC  the project.yml to edit (default: the one beside this script)
set -euo pipefail
NEW="${1:?usage: bump-version.sh <semver> [--commit]}"
MODE="${2:-}"
SPEC="${VITRINE_PROJECT_SPEC:-$(cd "$(dirname "$0")/.." && pwd)/project.yml}"
printf '%s' "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "not a version: $NEW (want major.minor.patch)" >&2; exit 2; }
case "$MODE" in ''|--commit) ;; *) echo "unknown option $MODE" >&2; exit 2 ;; esac

OLD=$(grep -E '^ +MARKETING_VERSION: "' "$SPEC" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
BUILD=$(grep -E '^ +CURRENT_PROJECT_VERSION: "' "$SPEC" | head -1 | grep -oE '[0-9]+')
[ -n "$OLD" ] && [ -n "$BUILD" ] || { echo "$SPEC has no quoted MARKETING_VERSION / CURRENT_PROJECT_VERSION" >&2; exit 1; }
[ "$(grep -cE '^ +MARKETING_VERSION: "' "$SPEC")" = 1 ] && [ "$(grep -cE '^ +CURRENT_PROJECT_VERSION: "' "$SPEC")" = 1 ] \
  || { echo "$SPEC sets the version in more than one place; edit it by hand" >&2; exit 1; }
# Refuse a lower marketing version (an installed copy would see it as a downgrade).
lowest=$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)
if [ "$NEW" != "$OLD" ] && [ "$lowest" = "$NEW" ]; then echo "$NEW is lower than the current $OLD" >&2; exit 1; fi

NEXT=$((BUILD + 1))
sed -i '' -E "s/^( +MARKETING_VERSION: )\"[^\"]+\"/\1\"$NEW\"/; s/^( +CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\1\"$NEXT\"/" "$SPEC"
echo "version $OLD ($BUILD) → $NEW ($NEXT) in $SPEC"

if [ "$MODE" = "--commit" ]; then
  cd "$(dirname "$SPEC")"
  git add "$(basename "$SPEC")"
  git commit -q -m "Version $NEW (build $NEXT)"
  git tag "v$NEW"
  echo "committed and tagged v$NEW (build $NEXT); nothing pushed"
fi
