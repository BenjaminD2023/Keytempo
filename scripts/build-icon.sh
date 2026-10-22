#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
icon_dir="$PWD/.build/AppIcon.iconset"
mkdir -p "$icon_dir"
for icon_size in 16 32 128 256 512; do
    sips -z "$icon_size" "$icon_size" Resources/AppIcon.png --out "$icon_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
    retina_size=$((icon_size * 2))
    sips -z "$retina_size" "$retina_size" Resources/AppIcon.png --out "$icon_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir" -o Resources/AppIcon.icns
