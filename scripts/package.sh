#!/bin/zsh
set -eu
cd "${0:A:h:h}"
app="$PWD/build/Codex Usage Float.app"
codesign --verify --deep --strict "$app"
version="$(<VERSION)"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" == "$bundle_version" ]] || { print -u2 -- '构建版本与 VERSION 不一致，请重新构建。'; exit 1; }
mkdir -p dist
name="codex-usage-float-${version}-macos-arm64.zip"
ditto -c -k --keepParent --norsrc "$app" "dist/$name"
cd dist
shasum -a 256 "$name" > SHA256SUMS
print -r -- "$PWD/$name"
