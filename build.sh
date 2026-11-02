#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/swift-cache"
/usr/bin/swift build --disable-sandbox --build-system native -c release
bundle="$PWD/dist/DisplayKeeper.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp .build/release/DisplayKeeper "$bundle/Contents/MacOS/DisplayKeeper"
cp packaging/Info.plist "$bundle/Contents/Info.plist"
# Remove the obsolete notice from bundles built before DDC was removed.
rm -f "$bundle/Contents/Resources/ThirdPartyNotices.txt"
cp packaging/Resources/AppIcon.icns packaging/Resources/MenuBarTemplate.pdf "$bundle/Contents/Resources/"
/usr/bin/codesign --force --deep --sign - "$bundle"
echo "Built $bundle"
