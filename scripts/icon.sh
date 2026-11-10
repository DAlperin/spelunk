#!/bin/sh
# Renders assets/AppIcon.svg into assets/AppIcon.icns. Needs rsvg-convert (brew install librsvg).
set -eu
cd "$(dirname "$0")/.."
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w "$s" -h "$s" assets/AppIcon.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s * 2)) -h $((s * 2)) assets/AppIcon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
rm -rf "$(dirname "$SET")"
echo assets/AppIcon.icns
