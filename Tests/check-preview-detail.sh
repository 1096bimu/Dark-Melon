#!/bin/zsh
# Run from the repository root. Uses a separate unsigned Debug build.
set -eu
build_dir="${TMPDIR:-/tmp}/DarkMelonPreviewChecks"
xcodebuild -project 'Dark Melon.xcodeproj' -scheme 'Dark Melon' \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$build_dir" \
  CODE_SIGNING_ALLOWED=NO build > "$build_dir.log" 2>&1
products="$build_dir/Build/Products/Debug"
binary_dir="$products/Dark Melon.app/Contents/MacOS"
xcrun swiftc -parse-as-library -target arm64-apple-macos27.0 \
  -I "$products" Tests/PreviewDetailChecks.swift "$binary_dir/Dark Melon.debug.dylib" \
  -Xlinker -rpath -Xlinker "$binary_dir" -o "$build_dir/check-preview-detail"
"$build_dir/check-preview-detail"
