#!/bin/bash
# The signature gate for a built Vitrine.app, ported from Obscura's Scripts/check-app-signature.sh for Vitrine's bundle
# (an app with an embedded framework, ten sandboxed extensions, a launch-agent helper, a command and a Spotlight
# importer). make-dmg.sh runs it before it makes a disk image; a non-zero exit stops the release. roadmap: S-13
#
#   app/scripts/check-app-signature.sh <Vitrine.app>            the install gate
#   app/scripts/check-app-signature.sh <Vitrine.app> --release  also the release-only values (G-21): the real update
#                                                               public key (set VITRINE_UPDATE_PUBLIC_KEY to
#                                                               `vitrine-release public-key`), an https feed address,
#                                                               no placeholder, no build-Mac folder, no ad-hoc signature
# Checks:
#   - the app verifies (deep, strict), and so does every nested code object on its own;
#   - every Mach-O file is signed, universal (arm64 + x86_64) and has the hardened runtime;
#   - each bundle whose target names an entitlements file in project.yml carries exactly that file's entitlements
#     (the extensions' sandbox, app group, read-only file exception and the helper's mach-lookup exception; the web
#     extensions' network client; the app's app group); every other code object carries none;
#   - no get-task-allow and no hardened-runtime exception (com.apple.security.cs.*) anywhere, with one exception
#     (G-36): when the app's signature has no Team ID (ad hoc or self-signed), the bundles with an entitlements
#     file must carry com.apple.security.cs.disable-library-validation as well, and only that one; with a Team ID
#     they must not carry it;
#   - the helper's launchd property list advertises exactly the mach service the extensions may look up;
#   - every rpath stays inside the bundle or the system Swift libraries; no Sparkle keys.
# Prints one table row per code object, then ok/FAIL lines.
#   VITRINE_PROJECT_SPEC  project.yml to read the entitlements pairing from (default: the one beside this script)
set -euo pipefail
APP="${1:-}"
MODE="${2:-install}"
[ -d "$APP" ] || { echo "usage: $0 <Vitrine.app> [--release]" >&2; exit 2; }
APP="$(cd "$APP" && pwd)"
HERE="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$(cd "$HERE/.." && pwd)"
SPEC="${VITRINE_PROJECT_SPEC:-$APPDIR/project.yml}"
ENTMAP="$("$HERE/entitlements-map.sh" "$SPEC")"
fail=0
ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $1"; fail=1; }
note() { echo "note  $1"; }

# A plist (XML or binary, file or stdin) as compact JSON with sorted keys; empty input prints {}.
plist_json() {
  python3 -I -c '
import json, plistlib, sys
data = open(sys.argv[1], "rb").read() if len(sys.argv) > 1 else sys.stdin.buffer.read()
print(json.dumps(plistlib.loads(data) if data.strip() else {}, sort_keys=True, separators=(",", ":")))
' "$@"
}
# One field of entitlements JSON: true/false for a boolean key, the array joined with "," for an array key.
ent_field() {
  python3 -I -c '
import json, sys
value = json.loads(sys.argv[1]).get(sys.argv[2])
print("-" if value is None else ("yes" if value is True else ("no" if value is False else ",".join(value))))
' "$1" "$2"
}
entitlements_for() { printf '%s\n' "$ENTMAP" | awk -F '\t' -v id="$1" '$1 == id { print $2; exit }'; }

if codesign --verify --deep --strict "$APP" 2>/dev/null; then ok "Vitrine.app verifies (deep, strict)"
else bad "Vitrine.app does not verify: $(codesign --verify --deep --strict "$APP" 2>&1 | tail -1)"; fi

# Code objects: the app, every nested bundle with an executable, and every loose Mach-O file.
objects=("$APP")
while IFS= read -r bundle; do
  if [ -f "$bundle/Contents/Info.plist" ]; then plist="$bundle/Contents/Info.plist"
  elif [ -f "$bundle/Resources/Info.plist" ]; then plist="$bundle/Resources/Info.plist"
  else continue; fi
  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" >/dev/null 2>&1 && objects+=("$bundle")
done < <(find "$APP/Contents" -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.mdimporter' -o -name '*.xpc' \
          -o -name '*.app' -o -name '*.bundle' -o -name '*.plugin' \) | sort)
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' && objects+=("$file")
done < <(find "$APP/Contents/Helpers" -type f -print0 2>/dev/null; find "$APP/Contents" -type f -name '*.dylib' -print0)

HELPER_PLIST="$(find "$APP/Contents/Library/LaunchAgents" -name '*.plist' 2>/dev/null | head -1)"
HELPER_MACH=""
[ -n "$HELPER_PLIST" ] && HELPER_MACH="$(python3 -I -c '
import plistlib, sys
print(",".join(sorted(plistlib.load(open(sys.argv[1], "rb")).get("MachServices", {}))))' "$HELPER_PLIST")"

printf '\n%-58s %-44s %-8s %-7s %-6s %-30s %-5s %-5s %-5s %-4s\n' \
  "code object" "identifier" "signed" "runtime" "verify" "entitlements" "sbox" "group" "mach" "net"
printf '%s\n' "$(printf '%.0s-' {1..182})"
# G-36: library validation needs a Team ID, which an ad-hoc or self-signed identity lacks.
APP_TEAM="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
case "$APP_TEAM" in ""|"not set") NO_TEAM=yes ;; *) NO_TEAM="" ;; esac
LV_KEY='"com.apple.security.cs.disable-library-validation":true'
# The entitlements a bundle must carry: its file's, plus the G-36 exception when the signature has no Team ID.
expected_json() {
  python3 -I -c '
import json, plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
if sys.argv[2] == "yes": d["com.apple.security.cs.disable-library-validation"] = True
print(json.dumps(d, sort_keys=True, separators=(",", ":")))' "$1" "$NO_TEAM"
}
for obj in "${objects[@]}"; do
  rel="${obj#"$APP"}"; rel="Vitrine.app${rel}"
  info="$(codesign -dvv "$obj" 2>&1 || true)"
  id="$(printf '%s\n' "$info" | awk -F= '/^Identifier=/{ print $2; exit }')"
  if printf '%s\n' "$info" | grep -q '^Signature=adhoc'; then signer="adhoc"
  elif printf '%s\n' "$info" | grep -q '^Authority='; then signer="cert"
  else signer="NONE"; fi
  if printf '%s\n' "$info" | grep -E '^CodeDirectory' | grep -q 'runtime'; then runtime="yes"; else runtime="no"; fi
  if codesign --verify --strict "$obj" 2>/dev/null; then verify="ok"; else verify="FAIL"; fi
  actual="$(codesign -d --entitlements - --xml "$obj" 2>/dev/null | plist_json)"
  expected_file="$(entitlements_for "$id")"
  if [ "$obj" != "$APP" ] && [ "$id" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" ]; then
    expected_file=""   # only the app itself carries the app's entitlements
  fi
  if [ -n "$expected_file" ]; then
    expected="$(expected_json "$APPDIR/$expected_file")"
    if [ "$actual" = "$expected" ]; then ent="= $(basename "$expected_file")"; else ent="MISMATCH $(basename "$expected_file")"; fi
  else
    if [ "$actual" = "{}" ]; then ent="none (as expected)"; else ent="UNEXPECTED"; fi
  fi
  sbox="$(ent_field "$actual" com.apple.security.app-sandbox)"
  group="$(ent_field "$actual" com.apple.security.application-groups)"
  mach="$(ent_field "$actual" com.apple.security.temporary-exception.mach-lookup.global-name)"
  net="$(ent_field "$actual" com.apple.security.network.client)"
  [ "$group" = "-" ] || group="yes"
  machcol="-"; [ "$mach" = "-" ] || { [ "$mach" = "$HELPER_MACH" ] && machcol="=hlp" || machcol="DIFF"; }
  printf '%-58s %-44s %-8s %-7s %-6s %-30s %-5s %-5s %-5s %-4s\n' \
    "$rel" "${id:--}" "$signer" "$runtime" "$verify" "$ent" "$sbox" "$group" "$machcol" "$net"

  [ "$signer" != "NONE" ] || bad "$rel is not signed"
  [ "$verify" = "ok" ] || bad "$rel does not verify on its own"
  [ "$runtime" = "yes" ] || bad "$rel lacks the hardened runtime"
  case "$ent" in MISMATCH*|UNEXPECTED) bad "$rel entitlements: $actual (expected ${expected_file:-none})" ;; esac
  case "$actual" in *get-task-allow*) bad "$rel carries get-task-allow" ;; esac
  others="$actual"; [ -n "$NO_TEAM" ] && [ -n "$expected_file" ] && others="${actual//$LV_KEY/}"
  case "$others" in *'"com.apple.security.cs.'*) bad "$rel carries a hardened-runtime exception (com.apple.security.cs.*)" ;; esac
  [ "$machcol" != "DIFF" ] || bad "$rel may look up $mach, but the helper's launchd plist advertises ${HELPER_MACH:-nothing}"
done
echo

# Every Mach-O file: signed (covered above for code objects; here also main executables inside bundles), universal.
machos=0; thin=""
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  machos=$((machos + 1))
  archs="$(lipo -archs "$file" 2>/dev/null || true)"
  case " $archs " in *" arm64 "*) ;; *) thin="$thin ${file#"$APP"/}($archs)" ;; esac
  case " $archs " in *" x86_64 "*) ;; *) thin="$thin ${file#"$APP"/}($archs)" ;; esac
done < <(find "$APP" -type f -perm -u+x -print0; find "$APP" -type f -name '*.dylib' -print0)
if [ -z "$thin" ]; then ok "all $machos Mach-O files are universal (arm64 + x86_64)"; else bad "not universal:$thin"; fi
ok "${#objects[@]} code objects listed; $(printf '%s\n' "$ENTMAP" | wc -l | tr -d ' ') entitlement pairings read from $(basename "$SPEC")"

# Every target project.yml pairs with entitlements is present in the bundle.
while IFS=$'\t' read -r id file; do
  found=0
  for obj in "${objects[@]}"; do
    [ "$(codesign -dvv "$obj" 2>&1 | awk -F= '/^Identifier=/{ print $2; exit }')" = "$id" ] && { found=1; break; }
  done
  [ "$found" = 1 ] || bad "project.yml signs $id with $file, but the bundle has no code object with that identifier"
done <<< "$ENTMAP"

if [ -n "$HELPER_MACH" ]; then ok "the helper's launchd plist advertises $HELPER_MACH"; else bad "no helper launchd plist with MachServices in Contents/Library/LaunchAgents"; fi

stray=""
for obj in "${objects[@]}"; do
  exe="$obj"
  if [ -d "$obj" ]; then
    plist="$obj/Contents/Info.plist"; [ -f "$plist" ] || plist="$obj/Resources/Info.plist"
    name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
    if [ -f "$obj/Contents/MacOS/$name" ]; then exe="$obj/Contents/MacOS/$name"; else exe="$obj/$name"; fi
  fi
  while IFS= read -r rpath; do
    case "$rpath" in ''|@executable_path/*|@loader_path/*|/usr/lib/swift) ;; *) stray="$stray ${exe#"$APP"/}:$rpath" ;; esac
  done < <(otool -l "$exe" 2>/dev/null | awk '/cmd LC_RPATH/{ getline; getline; print $2 }' | sort -u)
done
if [ -z "$stray" ]; then ok "rpaths stay in the bundle or /usr/lib/swift"; else bad "rpaths outside the bundle:$stray"; fi

PLIST="$APP/Contents/Info.plist"
if /usr/libexec/PlistBuddy -c Print "$PLIST" 2>/dev/null | grep -qE '^ *SU[A-Za-z]+ = '; then bad "Info.plist holds Sparkle (SU*) keys"
else ok "no Sparkle keys in Info.plist"; fi
# The app icon (S-17): Info.plist names it and the compiled asset catalog holds it, or Finder shows a blank app.
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$ICON_NAME" ] && [ -f "$APP/Contents/Resources/Assets.car" ] \
   && xcrun assetutil --info "$APP/Contents/Resources/Assets.car" 2>/dev/null | grep -q "\"Name\" : \"$ICON_NAME\""; then
  ok "the app icon $ICON_NAME is in the asset catalog"
else bad "the app has no icon (CFBundleIconName ${ICON_NAME:-missing}, or not in Assets.car)"; fi

FEED="$(/usr/libexec/PlistBuddy -c 'Print :VitrineUpdateFeedURL' "$PLIST" 2>/dev/null || true)"
KEY="$(/usr/libexec/PlistBuddy -c 'Print :VitrineUpdatePublicKey' "$PLIST" 2>/dev/null || true)"
if [ "$MODE" = "--release" ]; then
  expected="${VITRINE_UPDATE_PUBLIC_KEY:-}"
  if ! printf '%s' "$expected" | grep -qE '^[A-Za-z0-9+/]{43}=$'; then
    bad "set VITRINE_UPDATE_PUBLIC_KEY to the release key's public half (vitrine-release public-key)"
  elif [ "$KEY" = "$expected" ]; then ok "Info.plist holds the release update public key"
  else bad "Info.plist does not hold the release update public key (built with the placeholder or another key)"; fi
  if grep -q REPLACE_WITH "$PLIST"; then bad "Info.plist still holds a REPLACE_WITH placeholder (set VITRINE_UPDATE_FEED_URL and VITRINE_UPDATE_PUBLIC_KEY)"
  else ok "no placeholders in Info.plist"; fi
  case "$FEED" in https://*) ok "VitrineUpdateFeedURL is https" ;; *) bad "VitrineUpdateFeedURL is not https: ${FEED:-missing}" ;; esac
  # A public build names no build Mac's home folder (Obscura G-38): in any file, or in a debug map left unstripped.
  homes="$(LC_ALL=C grep -rlaE '/Users/[^/[:space:]]+/' "$APP" 2>/dev/null | sed "s#^$APP/##" | head -20 || true)"
  if [ -z "$homes" ]; then ok "no home-folder path in the bundle"
  else bad "the bundle names a build Mac's folder in: $(printf '%s' "$homes" | tr '\n' ' ')— strip the Release build"; fi
  if codesign -dvv "$APP" 2>&1 | grep -q '^Signature=adhoc'; then
    bad "ad-hoc signature: an ad-hoc release can never verify its own updates (sign with the release identity)"
  else ok "signed with a certificate identity"; fi
else
  if grep -q REPLACE_WITH "$PLIST"; then note "Info.plist holds the update placeholders (the updater is inert; refused with --release)"; fi
  if codesign -dvv "$APP" 2>&1 | grep -q '^Signature=adhoc'; then note "ad-hoc signature (a local build; refused with --release)"; fi
fi

if [ "$fail" -ne 0 ]; then echo "signature gate: FAILED"; exit 1; fi
echo "signature gate: passed"
