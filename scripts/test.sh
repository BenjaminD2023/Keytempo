#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# CLT 27's SwiftBuild drops TestingMacros for per-file test compilation.
# The native engine correctly loads the bundled Swift Testing plugin.
developer_path="$(xcode-select -p)"
framework_path="$developer_path/Library/Developer/Frameworks"
if [[ -d "$framework_path/Testing.framework" ]]; then
    swift test --build-system native --disable-xctest -Xswiftc -F -Xswiftc "$framework_path" -Xlinker -rpath -Xlinker "$framework_path"
else
    swift test --disable-xctest
fi
./scripts/build.sh
dist/Keytempo.app/Contents/MacOS/Keytempo --self-test-editor
