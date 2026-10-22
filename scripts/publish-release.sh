#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Local publication deliberately keeps both signing private keys off GitHub.
# No credentials are exported, no system permissions or trust settings change.
mode="${1:---prepare}"
if (( $# > 1 )) || [[ "$mode" != --prepare && "$mode" != --publish ]]; then
    print -u2 "Usage: ./scripts/publish-release.sh [--prepare|--publish]"
    exit 2
fi
fail() { print -u2 -- "$1"; exit 1; }
repository="BenjaminD2023/Keytempo"
app_path="$PWD/dist/Keytempo.app"
info_path="$app_path/Contents/Info.plist"
account="local.benjamin.Keytempo.updates"
sparkle_bin="${KEYTEMPO_SPARKLE_BIN:-$PWD/.build/artifacts/sparkle/Sparkle/bin}"
[[ -x "$sparkle_bin/sign_update" && -x "$sparkle_bin/generate_keys" ]] || fail "Build the pinned Sparkle dependency first, or set KEYTEMPO_SPARKLE_BIN."
[[ -f "$info_path" ]] || fail "Build dist/Keytempo.app before preparing a release."
git diff --quiet && git diff --cached --quiet || fail "Commit or preserve tracked changes before preparing a release."
[[ -z "$(git ls-files --others --exclude-standard)" ]] || fail "Commit or move nonignored untracked files before preparing a release; source archives must match the reviewed tag."
git ls-files --error-unmatch appcast.xml >/dev/null || fail "The update feed must be tracked."

app_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_path")"
app_build="$(plutil -extract CFBundleVersion raw -o - "$info_path")"
bundle_identifier="$(plutil -extract CFBundleIdentifier raw -o - "$info_path")"
signing_channel="$(plutil -extract KeytempoSigningChannel raw -o - "$info_path")"
source_commit="$(plutil -extract KeytempoSourceCommit raw -o - "$info_path")"
source_clean="$(plutil -extract KeytempoSourceTreeClean raw -o - "$info_path")"
public_key="$(plutil -extract SUPublicEDKey raw -o - "$info_path")"
minimum_os="$(plutil -extract LSMinimumSystemVersion raw -o - "$info_path")"
feed_url="$(plutil -extract SUFeedURL raw -o - "$info_path")"
release_tag="v$app_version"
head_commit="$(git rev-parse HEAD)"
[[ "$bundle_identifier" == local.benjamin.TypingSpeed ]] || fail "Unexpected app bundle identifier."
[[ "$signing_channel" == local-development || "$signing_channel" == developer-id ]] || fail "Ad-hoc apps cannot enter the stable update channel."
[[ "$source_commit" == "$head_commit" && "$source_clean" == true ]] || fail "Rebuild from the current committed, clean source before publishing."
[[ "$(git rev-parse "refs/tags/$release_tag^{commit}")" == "$head_commit" ]] || fail "The version tag must identify the built source commit."
[[ "$feed_url" == "https://raw.githubusercontent.com/$repository/main/appcast.xml" ]] || fail "Unexpected update feed URL."
[[ "$(plutil -extract CFBundleShortVersionString raw -o - Resources/Info.plist)" == "$app_version" && "$(plutil -extract CFBundleVersion raw -o - Resources/Info.plist)" == "$app_build" ]] || fail "The built app metadata does not match the source."

codesign --verify --strict --deep "$app_path"
codesign --verify --strict -R='anchor apple generic' "$app_path"
signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
signing_team="$(print -r -- "$signature_details" | sed -n 's/^TeamIdentifier=//p')"
[[ "$signing_team" != 'not set' && -n "$signing_team" ]] || fail "The app has no signing team identity."
if [[ "$signing_channel" == local-development ]]; then
    print -r -- "$signature_details" | rg -q '^Authority=Apple Development:' || fail "The signing channel does not match the certificate."
else
    print -r -- "$signature_details" | rg -q '^Authority=Developer ID Application:' || fail "The signing channel does not match the certificate."
    xcrun stapler validate "$app_path"
fi
designated_requirement="$(codesign --display -r- "$app_path" 2>&1 | sed -n 's/^designated => //p')"
[[ -n "$designated_requirement" && "$designated_requirement" != *cdhash* ]] || fail "A stable designated requirement is required."
requirement_hash="$(print -rn -- "$designated_requirement" | shasum -a 256 | cut -d ' ' -f 1)"

# If an installed certificate-signed Keytempo exists, do not silently change
# its trusted publisher identity when preparing an update on this Mac.
installed_app=/Applications/Keytempo.app
if [[ -d "$installed_app" ]]; then
    installed_requirement="$(codesign --display -r- "$installed_app" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -n "$installed_requirement" && "$installed_requirement" != *cdhash* ]]; then
        codesign --verify --strict -R="$installed_requirement" "$app_path"
    fi
fi

binary_architecture="$(lipo -archs "$app_path/Contents/MacOS/Keytempo")"
[[ "$binary_architecture" == arm64 ]] || fail "This update channel currently distributes arm64 only."
keychain_public_key="$("$sparkle_bin/generate_keys" --account "$account" -p)"
[[ "$keychain_public_key" == "$public_key" ]] || fail "The Keychain signing key does not match the public key embedded in the app."
previous_count="$(python3 scripts/update-feed.py --count-items appcast.xml)"
if (( previous_count > 0 )); then
    "$sparkle_bin/sign_update" --account "$account" --verify "$PWD/appcast.xml"
fi

archive_name="Keytempo-${app_version}-macos-arm64.zip"
archive_path="$PWD/dist/$archive_name"
COPYFILE_DISABLE=1 ditto -c -k --keepParent --norsrc "$app_path" "$archive_path"
./scripts/package-source.sh
archive_signature="$("$sparkle_bin/sign_update" --account "$account" -p "$archive_path")"
"$sparkle_bin/sign_update" --account "$account" --verify "$archive_path" "$archive_signature"
archive_length="$(stat -f %z "$archive_path")"
python3 scripts/update-feed.py --previous appcast.xml --output dist/appcast.xml \
    --version "$app_version" --build "$app_build" --signature "$archive_signature" \
    --length "$archive_length" --public-key "$public_key" --team "$signing_team" \
    --minimum-os "$minimum_os" --signing-channel "$signing_channel" --requirement-hash "$requirement_hash"
"$sparkle_bin/sign_update" --account "$account" "$PWD/dist/appcast.xml"
"$sparkle_bin/sign_update" --account "$account" --verify "$PWD/dist/appcast.xml"
(
    cd dist
    shasum -a 256 "$archive_name" "Keytempo-${app_version}-source.zip" > SHA256SUMS
    shasum -a 256 -c SHA256SUMS
)
print -- "Prepared signed archive and feed in dist/; no private signing material was exported."
[[ "$mode" == --publish ]] || exit 0

# Publishing is explicit. Verify that GitHub's tag matches the exact local
# source before creating a release; never replace an existing public asset.
remote_tag_lines="$(git ls-remote --exit-code origin "refs/tags/$release_tag" "refs/tags/$release_tag^{}")"
remote_commit="$(print -r -- "$remote_tag_lines" | awk '$2 ~ /\^\{\}$/ {print $1}')"
if [[ -z "$remote_commit" ]]; then remote_commit="$(print -r -- "$remote_tag_lines" | awk 'NR==1 {print $1}')"; fi
[[ "$remote_commit" == "$head_commit" ]] || fail "Push the matching version tag before publishing."
[[ "$(gh repo view --json nameWithOwner --jq .nameWithOwner)" == "$repository" ]] || fail "The GitHub repository does not match the update channel."
if gh release view "$release_tag" --repo "$repository" >/dev/null 2>&1; then
    fail "This release already exists; published assets are never overwritten."
fi
notes_path="$PWD/dist/release-notes.md"
{
    print -- "Apple Silicon (arm64), macOS $minimum_os or later."
    print -- ""
    if [[ "$signing_channel" == local-development ]]; then
        print -- "Signed locally with an Apple Development certificate. This is not Developer ID distribution and is not notarized; first launch may require macOS approval."
    else
        print -- "Developer ID signed and notarized; the stapled ticket was validated during publication."
    fi
    print -- ""
    print -- "Updates use Sparkle Ed25519 archive and feed signatures. Signing private keys remain in the maintainer's local Keychain. Migrating from the former ad-hoc release requires one new permission grant; stable signing avoids changing the app identity on each build, but actual TCC retention still needs user verification."
    print -- ""
    print -- "Global typing statistics are estimates. Global Chinese CPM is unavailable without a commit adapter. Verify downloads against SHA256SUMS."
    print -- ""
    cat CHANGELOG.md
} > "$notes_path"
gh release create "$release_tag" "$archive_path" "$PWD/dist/Keytempo-${app_version}-source.zip" "$PWD/dist/SHA256SUMS" \
    --repo "$repository" --verify-tag --draft --title "Keytempo $app_version" --notes-file "$notes_path"
gh release edit "$release_tag" --repo "$repository" --draft=false --latest
cp dist/appcast.xml appcast.xml
print -- "Published $release_tag. Review, commit and push appcast.xml to main to enable update discovery."
