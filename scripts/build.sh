#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
configuration="${1:-debug}"
options=(-c "$configuration" --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security)
if [[ "${2:-native}" == universal ]]; then options+=(--arch arm64 --arch x86_64); fi
swift build "${options[@]}"
bin_dir="$(swift build "${options[@]}" --show-bin-path)"
app="$PWD/dist/Leaf.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Leaf" "$app/Contents/MacOS/Leaf"
# Replace generated resources instead of merging old signatures or removed assets.
rm -rf "$app/Contents/Resources/Leaf_LeafApp.bundle" "$app/Contents/MacOS/Leaf_LeafApp.bundle"
cp -R "$bin_dir/Leaf_LeafApp.bundle" "$app/Contents/Resources/"
cp -R ThirdParty "$app/Contents/Resources/"
cp scripts/Info.plist "$app/Contents/Info.plist"
if [[ ! -f dist/Leaf.icns ]]; then
    swift scripts/make-icon.swift "$PWD/dist/icon.png"
    mkdir -p dist/Leaf.iconset
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" dist/icon.png --out "dist/Leaf.iconset/icon_${size}x${size}.png" >/dev/null
        double=$((size*2))
        sips -z "$double" "$double" dist/icon.png --out "dist/Leaf.iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns dist/Leaf.iconset -o dist/Leaf.icns
fi
cp dist/Leaf.icns "$app/Contents/Resources/Leaf.icns"
codesign --force --sign - "$app/Contents/Resources/Leaf_LeafApp.bundle"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "$app"
