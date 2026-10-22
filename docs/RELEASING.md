# Releasing Keytempo

Build and publish from a reviewed commit on the maintainer Mac. Never publish local typing data, diagnostics, credentials or private signing material.

## Signing and permission continuity

The former ad-hoc signature used a per-binary code hash as its designated requirement. A changed binary therefore looked like a different application to macOS privacy authorization. Keytempo now supports a stable local certificate identity while preserving `local.benjamin.TypingSpeed` and the installed application path.

A local build selects an available Apple Development identity, or the identity explicitly configured through `KEYTEMPO_SIGNING_IDENTITY`. The build records the source commit, clean-tree state and signing channel in the final app metadata. Verify the selected identity rather than assuming that a successful build is certificate signed. CI machines without that identity may build ad-hoc test artifacts; those artifacts **must not be published to the stable update feed**.

The current maintainer release channel uses a local Apple Development certificate. It is **not Developer ID distribution and is not notarized**. It does not eliminate Gatekeeper first-launch approval. Migrating from the old ad-hoc app requires one new authorization. The maintainer Mac completed a real production Sparkle upgrade from original `1.2.0` build 9 to original `1.2.1` build 10: after relaunch and an in-app permission recheck, both Input Monitoring and Accessibility remained authorized, the keyboard tap received events, and the designated requirement was unchanged. No permission settings or TCC records were modified. This establishes that local update path, not a guarantee for every Mac or proof of every app's editable-control coverage. Continue testing actual grants when signing identity, path or update packaging changes; signature checks alone do not prove the TCC result.

Do not export the existing certificate/private key to GitHub. Do not weaken code requirements to an identifier-only expression, modify the TCC database, install system trust overrides or remove quarantine attributes as a workaround.

For future Developer ID distribution, use a Developer ID Application certificate, sign nested components inside-out, notarize and staple the final app, and verify that artifact. Changing signing channels is an explicit migration: the publisher refuses to silently replace the feed's signing team, channel, designated-requirement digest or Sparkle public key.

Apple's explanation: [TN3127: Code signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements), [Developer ID distribution](https://developer.apple.com/developer-id/).

## One-time update key setup

Sparkle 2.10.0 is pinned in the package dependency. After resolving/building it, its tools are in `.build/artifacts/sparkle/Sparkle/bin/`. The project-specific Ed25519 key lives in the local macOS Keychain under account `local.benjamin.Keytempo.updates`.

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account local.benjamin.Keytempo.updates
```

The first command creates a key only when one does not exist, otherwise reuses it. Put the **public** `SUPublicEDKey` value in `Resources/Info.plist`. Never put a private key in source, environment examples, app resources, archives or CI secrets. Do not generate a new key for every release. If Keychain asks to allow the signing tool, the maintainer must approve that local key use. Keep an independent secure recovery plan for the signing keys; losing either identity requires a separately planned migration.

The feed is `https://raw.githubusercontent.com/BenjaminD2023/Keytempo/main/appcast.xml`. Both archives and appcast XML are signed with Sparkle's official signing tool. The app requires a signed feed, and the publisher compares the Keychain public key with the key embedded in the app.

## Versioning and changelog

Keytempo uses `0.x` app versions and tags. The historical changelog names were normalized before `0.3.0`: `1.1.0 → 0.1.0`, `1.1.1 → 0.1.1`, `1.2.0 → 0.2.0` and `1.2.1 → 0.2.1`. Original signed archives, tags, embedded historical versions and feed URLs stay intact so old downloads and update references remain valid. Do not create new binary names that imply those historical archives were rebuilt as `0.x`.

`CFBundleShortVersionString` is the displayed version and determines the new GitHub tag/asset name. `CFBundleVersion` is a strictly increasing positive integer used by Sparkle for ordering. The first normalized release is `0.3.0` **build 11**, newer than original `1.2.1` **build 10**, despite the lower displayed major number. Never reset the internal build to `1`, compare releases only by their displayed version, or edit signed historical feed items to hide the transition. Test discovery and installation from an actual old `1.x` app.

Maintain the complete [CHANGELOG.md](../CHANGELOG.md) on every release. Use ISO dates and concrete `Added`, `Changed`, `Fixed`, `Removed`, `Deprecated` or `Security` entries when relevant, with release/compare links and explicit statistical or coverage changes. Preserve prior release facts under their normalized labels and original artifact aliases. Move completed unreleased entries into the new version and keep the next unreleased comparison pointed at that tag.

## Prepare a version

1. Update `CFBundleShortVersionString` (for example, `0.3.0`) and increment integer `CFBundleVersion` in `Resources/Info.plist`; the build must exceed every previously published build, including old `1.x` versions.
2. Update the complete `CHANGELOG.md` with the release date, categorized changes, limitations and working compare links.
3. Run `./scripts/test.sh` on a Mac. This checks core/store tests, update-feed fixtures, Release compilation, signing and isolated native integration checks. It does not replace physical-input or TCC validation.
4. Review the app: current WPM/CPM, the ten-minute average and its coverage, today's average, KPM, suspected-input controls/diagnostics, language settings, history, permissions, update controls and data preservation.
5. Commit and push the reviewed source. Tag that exact commit as `v` plus the short version, then push the tag.
6. Wait for the [CI and release-validation workflows](https://github.com/BenjaminD2023/Keytempo/actions) to pass. The tag workflow validates and packages but does not publish its ad-hoc app.
7. Build again from the committed, clean source so the app's recorded commit matches the tag:

```sh
./scripts/build.sh
./scripts/publish-release.sh --prepare
```

`--prepare` is the default. It performs no GitHub mutation, exports no private key and does not modify the tracked feed. It requires a certificate-signed arm64 app, matching version/build/tag/source commit, a clean source tree (including nonignored untracked files), a stable designated requirement and the correct local Sparkle key. Existing feed entries are validated, their signed XML is verified, and publisher identity changes are rejected. An already installed certificate-signed Keytempo must recognize the new app's code identity too.

The script repackages the final signed app, creates the allowlisted source archive, signs and verifies the app archive, creates a feed preview retaining at most 20 releases, signs/verifies the XML, and writes `SHA256SUMS` into `dist/`.

For a nonstandard local Sparkle-tool location, set `KEYTEMPO_SPARKLE_BIN` to the verified 2.10.0 `bin` directory. Do not use an unverified signing executable with the project key.

## Publish reviewed assets

After reviewing the prepared assets and successful checks:

```sh
./scripts/publish-release.sh --publish
```

This explicitly creates a draft GitHub Release containing the versioned arm64 app ZIP, source ZIP and `SHA256SUMS`, then publishes it. It refuses an existing release and never overwrites published binaries. A failure before publication may leave a draft to inspect rather than silently retrying a conflicting release.

After publication, the script copies the signed feed preview to the tracked `appcast.xml`. Review that change, commit it and push to `main`:

```sh
git add appcast.xml
git commit -m 'Publish signed update feed'
git push origin main
```

Publishing the feed last prevents updaters from discovering an asset that has not been uploaded. Do not modify signed XML by hand; regenerate and re-sign it. Verify the public release downloads against `SHA256SUMS`, then check for updates from the installed app. Test installation/relaunch using a newer signed build while preserving the same code identity and user database; record the actual result and any remaining manual checks.

## Distribution boundaries

Current automatic-update assets are Apple Silicon (`arm64`), macOS 13 or later. Intel execution has not been validated and is not included in this feed. App and framework notices are included in the bundle; the source archive uses an explicit file allowlist and excludes local databases, diagnostics and signing files.

Release notes must distinguish estimated global WPM from confirmed editor CPM and report the real validation scope. Global Chinese and English both use the same operation-based WPM estimate; global Chinese CPM remains unavailable without actual commit coverage. Describe suspected-repeat/burst filtering as a configurable metadata heuristic, not recognition of arbitrary random text or every macro, and disclose partial daily or session-window coverage. CPU-attributed energy measurements do not establish a whole-device incremental battery target below 1 W. Changes to statistics rules or unsupported input paths must not be hidden by update packaging.
