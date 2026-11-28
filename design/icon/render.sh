#!/bin/bash
# Renders the app icon PNGs from the SVGs here into Sources/Assets.xcassets/AppIcon.appiconset.
# Needs uv (runs cairosvg) and ImageMagick. Light and dark come out opaque, tinted keeps its clear background.
set -euo pipefail
cd "$(dirname "$0")"
out=../../Sources/Assets.xcassets/AppIcon.appiconset
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export DYLD_FALLBACK_LIBRARY_PATH=/opt/homebrew/lib # cairosvg finds Homebrew cairo here
for name in light dark tinted; do
    uvx --quiet --from cairosvg cairosvg "$name.svg" -W 1024 -H 1024 -o "$tmp/$name.png"
done
magick "$tmp/light.png" -alpha off -define png:color-type=2 -strip "$out/icon-1024.png"
magick "$tmp/dark.png" -alpha off -define png:color-type=2 -strip "$out/icon-1024-dark.png"
magick "$tmp/tinted.png" -define png:color-type=6 -strip "$out/icon-1024-tinted.png"
