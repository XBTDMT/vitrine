#!/bin/sh
# Vendors the web-side libraries the Markdown renderer loads, at pinned versions, from the npm registry
# (npm pack checks each tarball against the registry's integrity hash). Reproducible: run from app/, commits
# nothing, writes only VitrinePreviewKit/Resources/web/vendor/ (and web/code/ for the code view). Usage:
# tools/vendor_web.sh [katex|mermaid|code] (no argument vendors all of them). For `code`, VENDOR_NODE_MODULES may
# point at a node_modules folder already holding the pinned packages (then nothing is downloaded).
# roadmap: S-4
set -eu
KATEX_VERSION="0.16.22"
MERMAID_VERSION="12.2.0"
# The code view (G-14): CodeMirror 6 + Shiki, bundled with esbuild (a build tool only, never shipped).
SHIKI_VERSION="4.5.0"
ESBUILD_VERSION="0.28.2"
CM_VIEW="6.43.15"; CM_STATE="6.7.6"; CM_LANGUAGE="6.13.1"; CM_SEARCH="6.7.2"
ONLY="${1:-all}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/VitrinePreviewKit/Resources/web/vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

if [ "$ONLY" = all ] || [ "$ONLY" = katex ]; then
  npm pack "katex@$KATEX_VERSION" --silent >/dev/null
  mkdir katex-pkg && tar xzf "katex-$KATEX_VERSION.tgz" -C katex-pkg
  rm -rf "$OUT/katex"; mkdir -p "$OUT/katex/fonts"
  cp katex-pkg/package/dist/katex.min.js katex-pkg/package/dist/katex.min.css katex-pkg/package/LICENSE "$OUT/katex/"
  cp katex-pkg/package/dist/contrib/auto-render.min.js "$OUT/katex/"
  cp katex-pkg/package/dist/fonts/*.woff2 "$OUT/katex/fonts/"
  printf 'katex %s (MIT) vendored by tools/vendor_web.sh on %s\n' "$KATEX_VERSION" "$(date -u +%F)" > "$OUT/katex/VERSION"
  echo "vendored katex $KATEX_VERSION -> $OUT/katex"
fi

if [ "$ONLY" = all ] || [ "$ONLY" = mermaid ]; then
  # Only the self-contained browser bundle is kept; the package's sources and dependencies are not.
  npm pack "mermaid@$MERMAID_VERSION" --silent >/dev/null
  mkdir mermaid-pkg && tar xzf "mermaid-$MERMAID_VERSION.tgz" -C mermaid-pkg
  rm -rf "$OUT/mermaid"; mkdir -p "$OUT/mermaid"
  cp mermaid-pkg/package/dist/mermaid.min.js "$OUT/mermaid/"
  cp mermaid-pkg/package/LICENSE "$OUT/mermaid/"
  # The licences of the packages Mermaid bundles into mermaid.min.js (S-17; sources in THIRD_PARTY_NOTICES.md).
  mkdir -p "$OUT/mermaid/licenses"; cp "$HERE/tools/licenses/mermaid/"* "$OUT/mermaid/licenses/"
  printf 'mermaid %s (MIT) vendored by tools/vendor_web.sh on %s; sha256 %s\n' "$MERMAID_VERSION" "$(date -u +%F)" \
    "$(shasum -a 256 "$OUT/mermaid/mermaid.min.js" | cut -d' ' -f1)" > "$OUT/mermaid/VERSION"
  echo "vendored mermaid $MERMAID_VERSION -> $OUT/mermaid"
fi

if [ "$ONLY" = all ] || [ "$ONLY" = code ]; then
  if [ -n "${VENDOR_NODE_MODULES:-}" ]; then
    NM="$VENDOR_NODE_MODULES"
  else
    npm install --prefix "$WORK/code" --ignore-scripts --no-audit --no-fund --no-save "shiki@$SHIKI_VERSION" \
      "esbuild@$ESBUILD_VERSION" "@codemirror/view@$CM_VIEW" "@codemirror/state@$CM_STATE" \
      "@codemirror/language@$CM_LANGUAGE" "@codemirror/search@$CM_SEARCH" >/dev/null
    NM="$WORK/code/node_modules"
  fi
  CODE_OUT="$HERE/VitrinePreviewKit/Resources/web/code"
  rm -rf "$CODE_OUT"; mkdir -p "$CODE_OUT/licenses"
  # ES modules with splitting: the code page loads code.js, the Markdown page fences.js (its code blocks coloured by
  # the same Shiki), the diff page diff.js (G-16); each loads only the grammar chunks its file needs, and they share
  # every common chunk.
  NODE_PATH="$NM" "$NM/@esbuild/darwin-arm64/bin/esbuild" "code=$HERE/web-src/code/code-entry.js" \
    "fences=$HERE/web-src/code/fences-entry.js" "diff=$HERE/web-src/code/diff-entry.js" --bundle --splitting \
    --format=esm --minify --legal-comments=none --entry-names='[name]' --chunk-names='chunks/[name]-[hash]' \
    --outdir="$CODE_OUT" --log-level=warning
  for pkg in shiki @shikijs/core @shikijs/langs @shikijs/themes @shikijs/engine-oniguruma @shikijs/vscode-textmate \
             @codemirror/view @codemirror/state @codemirror/language @codemirror/search; do
    lic="$(ls "$NM/$pkg"/LICENSE* 2>/dev/null | head -1)"
    [ -n "$lic" ] && cp "$lic" "$CODE_OUT/licenses/$(echo "$pkg" | tr '/@' '__')-LICENSE"
  done
  # The licences of the other packages esbuild bundles into the code view, and of each grammar and theme (S-17).
  cp "$HERE/tools/licenses/code/"* "$CODE_OUT/licenses/"
  printf 'code view: shiki %s, codemirror view %s state %s language %s search %s; bundled with esbuild %s on %s; sha256 code.js %s fences.js %s diff.js %s\n' \
    "$SHIKI_VERSION" "$CM_VIEW" "$CM_STATE" "$CM_LANGUAGE" "$CM_SEARCH" "$ESBUILD_VERSION" "$(date -u +%F)" \
    "$(shasum -a 256 "$CODE_OUT/code.js" | cut -d' ' -f1)" "$(shasum -a 256 "$CODE_OUT/fences.js" | cut -d' ' -f1)" "$(shasum -a 256 "$CODE_OUT/diff.js" | cut -d' ' -f1)" > "$CODE_OUT/VERSION"
  echo "bundled the code view -> $CODE_OUT"
fi

# The native libraries' licences (cmark, gemoji, zstd, lz4) ship beside the web ones, whatever was vendored (S-17).
mkdir -p "$HERE/VitrinePreviewKit/Resources/web/licenses"
cp "$HERE/tools/licenses/native/"* "$HERE/VitrinePreviewKit/Resources/web/licenses/"
cp "$HERE/Packages/Sources/CZstd/LICENSE" "$HERE/VitrinePreviewKit/Resources/web/licenses/zstd-LICENSE"
cp "$HERE/Packages/Sources/CLZ4/LICENSE" "$HERE/VitrinePreviewKit/Resources/web/licenses/lz4-LICENSE"
