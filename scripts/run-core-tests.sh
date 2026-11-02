#!/bin/bash
set -euo pipefail

# Run the same Swift Testing suite without Xcode, XCTest, or the app/UI target.
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
build_dir="$project_dir/.build/core-tests"
swift_compiler="$(/usr/bin/xcrun --find swiftc)"
sdk_path="$(/usr/bin/xcrun --show-sdk-path)"
target="$(/usr/bin/uname -m)-apple-macosx14.0"
developer_dir="$(/usr/bin/xcode-select -p)"
framework_dir="$developer_dir/Library/Developer/Frameworks"
if [[ ! -d "$framework_dir/Testing.framework" ]]; then
    framework_dir="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
fi
if [[ ! -d "$framework_dir/Testing.framework" ]]; then
    echo "Swift Testing.framework is not bundled with the selected developer tools." >&2
    exit 1
fi
plugin_dir="$(dirname -- "$swift_compiler")/../lib/swift/host/plugins/testing"
mkdir -p "$build_dir/module-cache"

"$swift_compiler" \
    -swift-version 5 -sdk "$sdk_path" -target "$target" \
    -emit-library -static -enable-testing -emit-module \
    -module-name DisplayCore -module-cache-path "$build_dir/module-cache" \
    -emit-module-path "$build_dir/DisplayCore.swiftmodule" \
    "$project_dir"/Sources/DisplayCore/*.swift \
    -o "$build_dir/libDisplayCore.a"

"$swift_compiler" \
    -swift-version 5 -sdk "$sdk_path" -target "$target" \
    -parse-as-library -module-name DisplayCoreTests \
    -module-cache-path "$build_dir/module-cache" \
    -I "$build_dir" -L "$build_dir" -lDisplayCore \
    -F "$framework_dir" -plugin-path "$plugin_dir" \
    -Xlinker -rpath -Xlinker "$framework_dir" \
    -Xlinker -rpath -Xlinker "$framework_dir/../usr/lib" \
    "$project_dir"/Tests/DisplayCoreTests/*.swift \
    "$script_dir/CoreTestRunner.swift" \
    -o "$build_dir/DisplayCoreTests"

exec "$build_dir/DisplayCoreTests" "$@"
