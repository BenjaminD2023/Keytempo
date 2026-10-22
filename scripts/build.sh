#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
./scripts/build-icon.sh
app_path="$PWD/dist/Keytempo.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/Keytempo "$app_path/Contents/MacOS/Keytempo"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp LICENSE "$app_path/Contents/Resources/LICENSE"
if [[ -f NOTICE ]]; then cp NOTICE "$app_path/Contents/Resources/NOTICE"; fi
codesign --force --sign - --identifier local.benjamin.TypingSpeed "$app_path"
codesign --verify --strict "$app_path"
app_version="$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)"
binary_architectures="$(lipo -archs "$app_path/Contents/MacOS/Keytempo")"
case "$binary_architectures" in
    arm64|x86_64) release_architecture="$binary_architectures" ;;
    "x86_64 arm64"|"arm64 x86_64") release_architecture="universal" ;;
    *) print -u2 "Unsupported release architectures: $binary_architectures"; exit 1 ;;
esac
release_archive="$PWD/dist/Keytempo-${app_version}-macos-${release_architecture}.zip"
# Exclude Finder resource-fork sidecars; the signed app itself remains intact.
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "$app_path" "$release_archive"
cp "$release_archive" "$PWD/dist/Keytempo-macOS.zip"
print "Built: $app_path"
print "Release archive: $release_archive"
