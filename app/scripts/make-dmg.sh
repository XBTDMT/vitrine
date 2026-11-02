#!/bin/bash
# Builds a release Vitrine.app (Release, universal arm64 + x86_64), signs it inside-out, gates it with
# check-app-signature.sh and wraps it in Vitrine-<version>_<build>.dmg with an Applications link. Ported from Obscura's
# Scripts/make-dmg.sh and Scripts/sign-and-notarize.sh for Vitrine's bundle layout (ARCHITECTURE §2). roadmap: S-13
#
#   app/scripts/make-dmg.sh [output folder]          default output: <repo>/build/dist
#
# Signing (G-3, as Obscura signs): the identity is SIGNING_IDENTITY when set, else the local "Vitrine Self-Signed"
# certificate identity when this Mac's keychain holds one (a stable self-signed identity, so updates can verify
# against the running copy's designated requirement), else ad hoc ("-", a local build only: an ad-hoc copy can never
# verify an update, and check-app-signature.sh --release refuses it). No Developer ID and no notarization until the
# maintainer has a developer account; that is a SIGNING_IDENTITY change, not a code change.
#
# Order, innermost first: loose Mach-O code (the `vitrine` command and VitrineHelper in Contents/Helpers), then every
# nested bundle deepest first (the PreviewKit framework, the six Quick Look and four Quick Action extensions, the
# Spotlight importer), then the app. Each bundle gets the entitlements file its target names in project.yml
# (entitlements-map.sh); every code object gets the hardened runtime. The library resource bundles
# (VitrineKit_*.bundle) hold no code and are sealed as resources of the bundle they sit in.
#
# Environment:
#   SIGNING_IDENTITY             a codesigning identity name, or "-" for ad hoc (see above for the default)
#   VITRINE_BUILD_DIR            the work folder (default <repo>/build): DerivedData/, SourcePackages/, release/, dist/
#                                (the Xcode project itself is generated at app/Vitrine.xcodeproj, as for every build)
#   VITRINE_SOURCE_PACKAGES_SEED a SourcePackages folder (checkouts/ + repositories/) copied into the work folder when
#                                it has none yet, so a clean build resolves swift-cmark offline from Package.resolved
#   KEEP_DERIVED_DATA=1          reuse the DerivedData folder instead of starting clean
#   TIMESTAMP=none               skip the secure timestamp for a certificate identity (ad hoc never takes one)
#   VITRINE_PROBE_COMPILATION_MODE=incremental
#                                a MEASUREMENT build, never a release: overrides Release's whole-module Swift compilation
#                                and names the image Vitrine-<version>_<build>-probe.dmg. It exists because the
#                                2026-11-01 tree does not compile in Release (ScrollMemory.swift:43, a strict-concurrency
#                                error whole-module compilation reports and Debug does not); fix the source, not this.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$APPDIR/.." && pwd)"
WORK="${VITRINE_BUILD_DIR:-$ROOT/build}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
OUT="${1:-$WORK/dist}"
DD="$WORK/DerivedData"
SP="$WORK/SourcePackages"
# Generated beside project.yml: its build settings (INFOPLIST_FILE, CODE_SIGN_ENTITLEMENTS …) are relative to app/, and
# xcodegen does not rewrite them for another project folder.
PROJECT="$APPDIR/Vitrine.xcodeproj"
LOG="$WORK/build.log"

# The two command-line products in Contents/Helpers and their signing identifiers (project.yml PRODUCT_NAME →
# PRODUCT_BUNDLE_IDENTIFIER): the identifier is part of each one's designated requirement.
helper_identifier() {
  case "$1" in
    vitrine) echo "io.github.xbtdmt.vitrine.command" ;;
    VitrineHelper) echo "io.github.xbtdmt.vitrine.helper" ;;
    *) return 1 ;;
  esac
}

DEFAULT_IDENTITY="-"
if security find-identity -p codesigning 2>/dev/null | grep -q '"Vitrine Self-Signed"'; then
  DEFAULT_IDENTITY="Vitrine Self-Signed"
fi
IDENTITY="${SIGNING_IDENTITY:-$DEFAULT_IDENTITY}"
if [ "$IDENTITY" = "-" ] || [ "${TIMESTAMP:-}" = "none" ]; then TS="--timestamp=none"; else TS="--timestamp"; fi

# G-36: library validation lets a hardened process load only Apple's code or code with its own Team ID, and an
# ad-hoc or self-signed identity has no Team ID, so the app and its extensions could not load VitrinePreviewKit.
# With such an identity, the bundles that carry an entitlements file (the app and the ten extensions, the only code
# that links the framework) are signed with com.apple.security.cs.disable-library-validation added; with a Team ID
# (Developer ID later) nothing is added. check-app-signature.sh applies the same rule.
identity_team() {
  [ "$IDENTITY" = "-" ] && return 0
  local probe; probe="$(mktemp -t vitrine-team-probe)"; cp /usr/bin/true "$probe"
  codesign --force --timestamp=none --sign "$IDENTITY" "$probe" >/dev/null 2>&1 || { rm -f "$probe"; echo "cannot sign with $IDENTITY" >&2; exit 1; }
  codesign -dvv "$probe" 2>&1 | sed -n 's/^TeamIdentifier=//p' | grep -v '^not set$' || true
  rm -f "$probe"
}
TEAM="$(identity_team)"
if [ -z "$TEAM" ]; then echo "== $IDENTITY has no Team ID: library validation is turned off for the app and its extensions (G-36)"; fi

echo "== project (xcodegen → $PROJECT)"
xcodegen generate --spec "$APPDIR/project.yml" --quiet
# The project builds only from the pinned dependency revisions (app/Packages/Package.resolved), never a newer one.
mkdir -p "$PROJECT/project.xcworkspace/xcshareddata/swiftpm"
cp "$APPDIR/Packages/Package.resolved" "$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

if [ ! -d "$SP/checkouts" ] && [ -n "${VITRINE_SOURCE_PACKAGES_SEED:-}" ]; then
  echo "== seeding $SP from $VITRINE_SOURCE_PACKAGES_SEED"
  mkdir -p "$SP"
  cp -R "$VITRINE_SOURCE_PACKAGES_SEED/checkouts" "$VITRINE_SOURCE_PACKAGES_SEED/repositories" "$SP/"
fi

if [ "${KEEP_DERIVED_DATA:-0}" != "1" ] && [ -d "$DD" ]; then
  case "$DD" in "$WORK"/DerivedData) rm -rf "$DD" ;; *) echo "refusing to clean $DD" >&2; exit 1 ;; esac
fi

PROBE_SETTINGS=(); SUFFIX=""
case "${VITRINE_PROBE_COMPILATION_MODE:-}" in
  "") ;;
  incremental|wholemodule)
    PROBE_SETTINGS=(SWIFT_COMPILATION_MODE="$VITRINE_PROBE_COMPILATION_MODE"); SUFFIX="-probe"
    echo "WARNING: measurement build (SWIFT_COMPILATION_MODE=$VITRINE_PROBE_COMPILATION_MODE); never publish it" ;;
  *) echo "VITRINE_PROBE_COMPILATION_MODE must be incremental or wholemodule" >&2; exit 2 ;;
esac

echo "== xcodebuild Release, arm64 + x86_64 (log: $LOG)"
if ! xcodebuild -project "$PROJECT" -scheme Vitrine -configuration Release ${PROBE_SETTINGS[@]+"${PROBE_SETTINGS[@]}"} \
     -destination 'generic/platform=macOS' -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SP" \
     -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
     ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
     CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
     build > "$LOG" 2>&1; then
  grep -nE 'error:|\*\* BUILD' "$LOG" | head -60 || true   # display only; xcodebuild's status decides
  tail -40 "$LOG"
  exit 1
fi
grep -E '\*\* BUILD' "$LOG"

BUILT="$DD/Build/Products/Release/Vitrine.app"
APP="$WORK/release/Vitrine.app"
rm -rf "$WORK/release"; mkdir -p "$WORK/release"
ditto "$BUILT" "$APP"

sign() { codesign --force "$TS" --options runtime --sign "$IDENTITY" "$@"; }

echo "== signing inside-out (identity: $IDENTITY)"
# 1. Loose Mach-O code that is not a bundle's main executable: the command-line products and any dylib.
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q 'Mach-O' || continue
  case "$file" in
    "$APP"/Contents/Helpers/*)
      name="$(basename "$file")"
      id="$(helper_identifier "$name")" || { echo "unknown helper $name: add it to helper_identifier" >&2; exit 1; }
      sign --identifier "$id" "$file"; echo "signed $(printf '%s' "${file#"$APP"/}") ($id)" ;;
    *.dylib) sign "$file"; echo "signed ${file#"$APP"/}" ;;
  esac
done < <(find "$APP/Contents" -type f \( -path "$APP/Contents/Helpers/*" -o -name '*.dylib' \) -print0)

# 2. Nested bundles that carry code, deepest first, each with its target's entitlements.
ENTMAP="$("$HERE/entitlements-map.sh" "$APPDIR/project.yml")"
entitlements_for() { printf '%s\n' "$ENTMAP" | awk -F '\t' -v id="$1" '$1 == id { print $2; exit }'; }
# The entitlements a bundle is signed with: its file, plus the G-36 exception when the identity has no Team ID.
signing_entitlements() {
  local file="$APPDIR/$1"
  if [ -n "$TEAM" ]; then printf '%s\n' "$file"; return; fi
  local merged="$WORK/entitlements-$(basename "$1")"
  cp "$file" "$merged"   # made fresh on every run, so an edited entitlements file is never signed stale
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$merged" >/dev/null
  printf '%s\n' "$merged"
}
find "$APP/Contents" -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.mdimporter' -o -name '*.xpc' \
     -o -name '*.app' -o -name '*.bundle' -o -name '*.plugin' \) -print \
  | awk '{ print gsub("/", "/") "\t" $0 }' | sort -rn | cut -f2- \
  | while IFS= read -r bundle; do
      if [ -f "$bundle/Contents/Info.plist" ]; then plist="$bundle/Contents/Info.plist"
      elif [ -f "$bundle/Resources/Info.plist" ]; then plist="$bundle/Resources/Info.plist"
      else plist=""; fi
      exe=""; id=""
      if [ -n "$plist" ]; then
        exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
        id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
      fi
      [ -n "$exe" ] || continue   # a resource bundle: no code, sealed by its parent
      ent="$(entitlements_for "$id")"
      if [ -n "$ent" ]; then sign --entitlements "$(signing_entitlements "$ent")" "$bundle"; echo "signed ${bundle#"$APP"/} ($id, $ent)"
      else sign "$bundle"; echo "signed ${bundle#"$APP"/} ($id)"; fi
    done

# 3. The app itself.
APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
APP_ENT="$(entitlements_for "$APP_ID")"
[ -n "$APP_ENT" ] || { echo "project.yml names no entitlements for $APP_ID" >&2; exit 1; }
sign --entitlements "$(signing_entitlements "$APP_ENT")" "$APP"
echo "signed Vitrine.app ($APP_ID, $APP_ENT)"

codesign --verify --deep --strict --verbose=2 "$APP"
"$HERE/check-app-signature.sh" "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
DMG="$OUT/Vitrine-${VERSION}_${BUILD}${SUFFIX}.dmg"
STAGE="$(mktemp -d "$WORK/dmg-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Vitrine.app"
ln -s /Applications "$STAGE/Applications"
# An installed Vitrine's updater opens the disk image read-only and copies the one app at its top level (G-21), so
# the image holds exactly one .app.
hdiutil create -volname "Vitrine" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [ "$IDENTITY" != "-" ]; then codesign "$TS" --sign "$IDENTITY" "$DMG"; fi
echo "$DMG"
