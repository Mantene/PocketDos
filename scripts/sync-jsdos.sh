#!/usr/bin/env bash
#
# Copies built js-dos assets into Web/ so the app can serve them offline.
#
# Build js-dos first (in the js-dos checkout):
#     npx vite build        # produces dist/js-dos.js, dist/js-dos.css, dist/emulators/*
#   (use `npx vite build` rather than `yarn build` to skip the tsc type-check,
#    which currently fails on a types mismatch with the pinned `emulators` pkg.)
#
# Usage:
#     scripts/sync-jsdos.sh [path-to-js-dos/dist]
# Default source: ../js-dos/dist (sibling checkout)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$REPO_ROOT/../js-dos/dist}"
WEB="$REPO_ROOT/Web"

if [[ ! -f "$SRC/js-dos.js" ]]; then
  echo "ERROR: $SRC/js-dos.js not found. Build js-dos first (npx vite build)." >&2
  exit 1
fi

echo "Syncing js-dos assets:"
echo "  from: $SRC"
echo "  to:   $WEB"

cp "$SRC/js-dos.js"  "$WEB/js-dos.js"
cp "$SRC/js-dos.css" "$WEB/js-dos.css"
rm -rf "$WEB/emulators"
cp -R "$SRC/emulators" "$WEB/emulators"

# Drop sourcemaps + TS typings to keep the bundle lean (not needed at runtime).
find "$WEB/emulators" -name '*.map' -delete 2>/dev/null || true
rm -rf "$WEB/emulators/types" 2>/dev/null || true
rm -f "$WEB/js-dos.js.map" "$WEB/js-dos.css.map" 2>/dev/null || true

echo "Done. Web/ now contains:"
ls -lah "$WEB"
echo "Web/emulators wasm:"
find "$WEB/emulators" -name '*.wasm' -exec ls -lah {} \;
