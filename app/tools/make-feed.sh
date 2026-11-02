#!/bin/bash
# Writes the signed update feed (G-21, ported from Obscura's make-feed.sh) for one release disk image.
#   tools/make-feed.sh <Vitrine.app> <Vitrine-<version>_<build>.dmg> <https download url> [<https release notes url>]
# The update key is read from the login-Keychain item named by VITRINE_UPDATE_KEY_ITEM (created once with
# `vitrine-release keygen`, the maintainer's release step); the private key is never printed or written. Output:
# dist/vitrine-update.json, published at the app's VitrineUpdateFeedURL together with the DMG at <download url>.
# The DMG must be served WITHOUT a redirect to another host (Vitrine refuses cross-host redirects), so it goes next to
# the feed (for example on GitHub Pages), not on a GitHub Releases asset link, which redirects. roadmap: S-13
set -euo pipefail
APP="${1:?path to the Vitrine.app inside the DMG}"; DMG="${2:?path to the DMG}"; URL="${3:?https download URL of the DMG}"
NOTES="${4:-}"
: "${VITRINE_UPDATE_KEY_ITEM:?set VITRINE_UPDATE_KEY_ITEM to the Keychain item holding the update key}"
OUT="${FEED_OUT:-dist/vitrine-update.json}"
mkdir -p "$(dirname "$OUT")"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$HERE/Packages" -c release --product vitrine-release >/dev/null
TOOL="$(swift build --package-path "$HERE/Packages" -c release --show-bin-path)/vitrine-release"
args=(feed --app "$APP" --dmg "$DMG" --url "$URL" --key-item "$VITRINE_UPDATE_KEY_ITEM" --out "$OUT")
[ -n "$NOTES" ] && args+=(--notes-url "$NOTES")
"$TOOL" "${args[@]}"
