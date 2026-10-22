# Security policy

## Supported version

Security fixes are developed for the latest release and the default branch. Older versions do not have a separate maintenance guarantee.

## Report a vulnerability

If this repository's [Security tab](https://github.com/BenjaminD2023/Keytempo/security) offers **Report a vulnerability**, use that private reporting channel. Otherwise, open an issue containing only a request for a private reporting channel, with no exploit details or sensitive attachments, and wait for the maintainer to arrange one. Do not publish credentials, personal input or a working sensitive exploit in a public issue.

A useful private report includes the affected version, platform, impact, and minimal reproduction using invented data. There is no guaranteed response time or bug-bounty program.

Never send typed text, chat history, clipboard contents, typing databases, system permission databases, signing keys or access tokens. Redact unrelated identifiers from diagnostic material.

## Boundaries

Keytempo passively observes keyboard metadata and queries focused-control metadata through public macOS APIs. It does not provide a complete provenance guarantee for arbitrary macros, custom shortcuts or applications that intercept keys. It must respect Secure Input and denied or revoked permissions.

Confirmed character coverage currently applies only to the built-in validation editor. Global estimates must not be presented as confirmed input or used as proof of a person's activity or inactivity.

Published apps are currently ad hoc signed and are not notarized. A checksum detects a mismatched download but is not a substitute for publisher identity verification. Never grant permissions to an unrelated app solely because its display name is Keytempo.
