#!/bin/bash
# Prints one line per target in app/project.yml that names an entitlements file:
#   <bundle id><TAB><entitlements file, relative to app/>
# make-dmg.sh signs each bundle with the file its target names; check-app-signature.sh compares each signed bundle's
# entitlements with that same file. project.yml stays the one place the pairing is written. roadmap: S-13
#   app/scripts/entitlements-map.sh [path/to/project.yml]
set -euo pipefail
SPEC="${1:-$(cd "$(dirname "$0")/.." && pwd)/project.yml}"
[ -f "$SPEC" ] || { echo "entitlements-map: no project spec at $SPEC" >&2; exit 2; }
# A target starts at a two-space key under `targets:`; its settings name PRODUCT_BUNDLE_IDENTIFIER, then
# CODE_SIGN_ENTITLEMENTS. Values in project.yml are unquoted.
awk '
  /^targets:/ { in_targets = 1; next }
  /^[A-Za-z]/ { in_targets = 0 }
  in_targets && /^  [A-Za-z][A-Za-z0-9]*:/ { id = "" }
  in_targets && /PRODUCT_BUNDLE_IDENTIFIER:/ { id = $2 }
  in_targets && /CODE_SIGN_ENTITLEMENTS:/ && id != "" { print id "\t" $2; id = "" }
' "$SPEC"
