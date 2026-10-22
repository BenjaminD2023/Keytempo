# Contributing to Keytempo

Bug reports, reproducible test cases, translations and focused pull requests are welcome. Contributions are licensed under the project's [MIT license](LICENSE).

## Report a bug

[Open an issue](https://github.com/BenjaminD2023/Keytempo/issues) with the Keytempo version/build, macOS version and architecture, input source, affected application, selected metric, and permission/context status. Describe the expected and observed counts or behavior with a small artificial example.

Do not attach personal typing content, chat screenshots, clipboard contents, statistics databases or macOS permission databases. The app's diagnostic view contains metadata only; review any report before sharing it. Report security issues using [SECURITY.md](SECURITY.md).

## Development

Use a Mac with a Swift 6+ toolchain supplied by Xcode or Command Line Tools. From the repository root, run:

```sh
./scripts/test.sh
```

This runs core/store tests, builds the Release app, checks its signature and runs isolated application integration checks. Tests must use temporary data directories and must not change the developer's saved settings, type into unrelated applications or request global permissions.

The app's deployment target is macOS 13. When using new APIs, keep availability explicit. Swift Testing may require a newer host OS than the application itself.

## Changes worth reviewing

- Keep the keyboard callback lightweight. Query Accessibility, update models, write to disk and publish UI changes outside it.
- Keep queues, buffers, diagnostics and retry work bounded. Stop periodic work when idle.
- Separate confirmed evidence from estimates. Missing coverage is unknown, not zero.
- Preserve actual interval timing, language boundaries and shortcut interruptions. Do not infer Chinese characters from Pinyin keys.
- Add meaningful regression coverage for changes to classification, timing, storage or source/language switching.
- Preserve the legacy bundle/data identifiers unless a reviewed migration accompanies the change.

Describe the concrete behavior change, why it is needed, and the checks performed. Distinguish deterministic tests and adapter callbacks from physical-input validation in third-party applications. Never commit local databases, logs, signing credentials or generated build folders.

Release preparation is documented in [docs/RELEASING.md](docs/RELEASING.md). Current distribution uses ad hoc signing; do not describe an asset as notarized or Developer ID signed unless that process was actually completed.
