# Releasing Keytempo

Release from a reviewed commit on the default branch. Do not publish local typing data, diagnostics, credentials or signing material.

## Prepare a version

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Resources/Info.plist`.
2. Add the concrete user-facing changes to `CHANGELOG.md`.
3. Run `./scripts/test.sh` on a Mac and review the resulting app. The script checks core/store tests, Release compilation, signing and isolated integration checks; it does not replace physical-input validation in other applications.
4. Check current language switching, WPM/CPM availability, KPM selection, permissions and preservation of existing data. Label remaining unsupported cases in release notes.

## Publish through GitHub Actions

The [release workflow](../.github/workflows/release.yml) runs for pushed `v*` tags or a manual workflow dispatch with a tag. It checks that the tag exactly matches `v` plus the app's short version, runs the tests/build, packages an allowlisted source archive and publishes a GitHub Release.

After committing and pushing the reviewed source, publish a version tag:

```sh
git tag v1.1.1
git push origin v1.1.1
```

Review the resulting [Actions run](https://github.com/BenjaminD2023/Keytempo/actions) and [Release](https://github.com/BenjaminD2023/Keytempo/releases). Do not manually create a competing release while the tag workflow is publishing.

For version 1.1.1 on the arm64 runner, the release assets are:

- `Keytempo-1.1.1-macos-arm64.zip`
- `Keytempo-1.1.1-source.zip`
- `SHA256SUMS`

Asset versions are derived from the app metadata; architecture is derived from the actual binary, rather than inferred from a runner label. A locally built Intel binary gets an Intel architecture label. This does not imply that Intel execution has been tested.

## Reproduce packaging locally

From a clean repository checkout:

```sh
./scripts/test.sh
./scripts/package-source.sh
```

The app, versioned archives and compatibility archives `Keytempo-macOS.zip` / `Keytempo-source.zip` appear in `dist/`. Before publishing, verify app metadata and signing:

```sh
plutil -lint dist/Keytempo.app/Contents/Info.plist
codesign --verify --strict dist/Keytempo.app
```

Include the source license and required notices in redistributed source or binaries. Keep generated files outside the tracked source tree. Never package a developer's whole working directory: use the source-packaging script's explicit source-file allowlist.

## Release notes and signing

State the version/build, supported deployment target and asset architectures. Describe actual checks and their limits. In particular:

- Current app signing is ad hoc, without Developer ID signing or notarization.
- A replacement binary may need Input Monitoring and Accessibility permissions to be granted again.
- Global input is an estimate; global Chinese character CPM is unavailable.
- Successful unit tests do not prove complete input coverage in WeChat, ChatGPT, games, Vim or custom editors.
- CPU-attributed energy measurements do not establish whole-device incremental battery power below 1 W.

If Developer ID signing is added later, store credentials in restricted CI secrets, sign the final bundle, notarize it, staple the ticket and verify that final artifact. Do not describe this as implemented until the published artifact has passed those steps.
