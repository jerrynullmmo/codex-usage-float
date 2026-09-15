#!/bin/zsh
set -eu
cd "${0:A:h}"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  print -u2 -- '构建需要 Apple Silicon Mac（arm64）；暂不支持 Intel 或其他系统。'
  exit 1
fi
xcrun --find swiftc >/dev/null
version="$(<VERSION)"
app="$PWD/build/Codex Usage Float.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 Sources/UsageCore.swift Sources/FamilyUsage.swift Sources/OpenCodeUsage.swift Sources/UsageSources.swift Sources/ActiveConversation.swift Sources/FloatingUI.swift Sources/main.swift -o "$app/Contents/MacOS/CodexUsageFloat"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CodexUsageFloat</string>
<key>CFBundleIdentifier</key><string>com.yonshore.codex-usage-float</string>
<key>CFBundleName</key><string>Codex Usage Float</string>
<key>CFBundleDisplayName</key><string>Codex 用量浮窗</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>${version}</string>
<key>CFBundleVersion</key><string>${version}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
cp README.md "$app/Contents/Resources/README.md"
cp LICENSE "$app/Contents/Resources/LICENSE"
mkdir -p "$app/Contents/Resources/docs"
cp docs/ADAPTERS.md "$app/Contents/Resources/docs/ADAPTERS.md"
mkdir -p "$app/Contents/Resources/windows"
cp windows/README.md "$app/Contents/Resources/windows/README.md"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
print -r -- "$app"
