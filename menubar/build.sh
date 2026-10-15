#!/bin/bash
# Compila la app de barra de menú y deja ClaudeUsage.app en la carpeta del repo.
set -euo pipefail
cd "$(dirname "$0")"
APP=../ClaudeUsage.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/ClaudeUsage" main.swift
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>ClaudeUsage</string>
<key>CFBundleIdentifier</key><string>com.local.claude-usage</string>
<key>CFBundleExecutable</key><string>ClaudeUsage</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP"
echo "OK -> $APP"
