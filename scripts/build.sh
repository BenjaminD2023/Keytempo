#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Keep a stable certificate for local updates. Ad-hoc signing remains available
# explicitly (KEYTEMPO_SIGNING_IDENTITY=-) and on certificate-free CI runners.
# Never export a signing certificate or private key from the login keychain.
signing_selection=("${(@f)$(python3 - <<'PY'
import os, re, subprocess

def output(arguments):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return result.stdout if result.returncode == 0 else ''

identities = re.findall(r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"([^"]+)"',
                        output(['security', 'find-identity', '-v', '-p', 'codesigning']), re.M)
selected = os.environ.get('KEYTEMPO_SIGNING_IDENTITY')
if selected is None:
    for installed in ['/Applications/Keytempo.app', os.path.expanduser('~/Applications/Keytempo.app')]:
        authorities = re.findall(r'^Authority=(.+)$', output(['codesign', '-dvv', installed]), re.M)
        if authorities:
            matching = [(fingerprint, name) for fingerprint, name in identities if name == authorities[0]]
            if len(matching) == 1:
                selected = matching[0][0]
                break
            raise SystemExit('The installed Keytempo signing identity is unavailable or ambiguous. Restore its certificate, or explicitly choose KEYTEMPO_SIGNING_IDENTITY for an intentional identity migration.')
    if selected is None:
        for prefix in ['Developer ID Application:', 'Apple Development:']:
            matching = [(fingerprint, name) for fingerprint, name in identities if name.startswith(prefix)]
            if len(matching) == 1:
                selected = matching[0][0]
                break
selected = selected or '-'
name = next((name for fingerprint, name in identities if selected in (fingerprint, name)), selected)
channel = ('adhoc' if selected == '-' else 'developer-id' if name.startswith('Developer ID Application:')
           else 'local-development' if name.startswith('Apple Development:') else 'certificate')
print(selected)
print(channel)
PY
)}")
signing_identity="${signing_selection[1]}"
signing_channel="${signing_selection[2]}"
source_commit="$(git rev-parse HEAD 2>/dev/null || print unknown)"
source_tree_clean=false
if [[ -z "$(git status --porcelain --untracked-files=normal 2>/dev/null)" ]]; then source_tree_clean=true; fi
swift build -c release
./scripts/build-icon.sh
app_path="$PWD/dist/Keytempo.app"
sparkle_path="$PWD/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$sparkle_path" ]]; then
    print -u2 "Sparkle framework is missing from SwiftPM artifacts: $sparkle_path"
    exit 1
fi
python3 - "$app_path" <<'PY'
import pathlib, shutil, sys
app = pathlib.Path(sys.argv[1])
if app.exists(): shutil.rmtree(app)
PY
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
mkdir -p "$app_path/Contents/Frameworks"
cp .build/release/Keytempo "$app_path/Contents/MacOS/Keytempo"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp LICENSE "$app_path/Contents/Resources/LICENSE"
if [[ -f NOTICE ]]; then cp NOTICE "$app_path/Contents/Resources/NOTICE"; fi
cp .build/artifacts/sparkle/Sparkle/LICENSE "$app_path/Contents/Resources/Sparkle-LICENSE"
# ditto preserves framework symlinks, resource bundles and executable modes.
ditto "$sparkle_path" "$app_path/Contents/Frameworks/Sparkle.framework"
/usr/libexec/PlistBuddy -c "Add :KeytempoSigningChannel string $signing_channel" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :KeytempoSourceCommit string $source_commit" "$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :KeytempoSourceTreeClean bool $source_tree_clean" "$app_path/Contents/Info.plist"
sparkle_bundle="$app_path/Contents/Frameworks/Sparkle.framework/Versions/B"
for nested_code in "$sparkle_bundle/Autoupdate" "$sparkle_bundle/Updater.app" \
                   "$sparkle_bundle/XPCServices/Downloader.xpc" "$sparkle_bundle/XPCServices/Installer.xpc"; do
    codesign --force --sign "$signing_identity" --preserve-metadata=entitlements "$nested_code"
done
codesign --force --sign "$signing_identity" "$app_path/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$signing_identity" --identifier local.benjamin.TypingSpeed "$app_path"
codesign --verify --deep --strict "$app_path"
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
print "Signing channel: $signing_channel"
print "Release archive: $release_archive"
