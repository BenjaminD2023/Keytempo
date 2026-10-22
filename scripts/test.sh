#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
python3 scripts/test-update-feed.py
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
python3 - <<'PY'
from pathlib import Path
import subprocess

app = Path('dist/Keytempo.app/Contents')
framework = app / 'Frameworks/Sparkle.framework'
assert (framework / 'Versions/Current').is_symlink(), 'Sparkle framework symlinks must be preserved'
assert (framework / 'Sparkle').is_file(), 'Sparkle framework executable is missing'
assert (app / 'Resources/Sparkle-LICENSE').read_bytes() == Path('.build/artifacts/sparkle/Sparkle/LICENSE').read_bytes()
linked = subprocess.check_output(['otool', '-L', str(app / 'MacOS/Keytempo')], text=True)
assert '@rpath/Sparkle.framework/Versions/B/Sparkle' in linked, 'Updater must load its bundled framework'
print('PASS: bundled updater framework, symlinks, license and linkage')
PY
dist/Keytempo.app/Contents/MacOS/Keytempo --self-test-editor
