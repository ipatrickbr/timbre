#!/bin/bash
# Builds Timbre.app and installs it into ~/Applications.
# The signed bundle is what macOS grants the audio recording permission to.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Timbre.app"
mkdir -p "$HOME/Applications"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>timbre</string>
    <key>CFBundleIdentifier</key><string>local.timbre</string>
    <key>CFBundleName</key><string>Timbre</string>
    <key>CFBundleDisplayName</key><string>Timbre</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>pt-BR</string></array>
    <key>NSAudioCaptureUsageDescription</key>
    <string>O Timbre precisa deste acesso para capturar o áudio que está tocando no Mac.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>O Timbre precisa deste acesso para capturar o áudio que está tocando no Mac.</string>
</dict>
</plist>
PLIST

# The log is filtered only to hide warnings; an error must fail the build,
# otherwise the app stays installed with the old binary and nobody notices.
BUILD_LOG=$(mktemp)
if ! swiftc -O -o "$APP/Contents/MacOS/timbre" main.swift tap.swift sck.swift menubar.swift \
    -framework CoreAudio -framework AudioToolbox -framework AVFoundation \
    -framework ScreenCaptureKit -framework AppKit 2> "$BUILD_LOG"; then
    grep -vE "warning:|note:" "$BUILD_LOG" >&2
    rm -f "$BUILD_LOG"
    echo "ERROR: build failed — the app was NOT updated." >&2
    exit 1
fi
rm -f "$BUILD_LOG"

# Resources: the MP3 encoder, the icon and both translations ride inside.
if [[ -x vendor/bin/lame ]]; then
    cp vendor/bin/lame "$APP/Contents/Resources/lame"
else
    echo "note: MP3 encoder missing — run ./vendor/build-lame.sh to enable MP3 output." >&2
fi
[[ -f icon/AppIcon.icns ]] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp sounds/start.wav sounds/stop.wav "$APP/Contents/Resources/" 2>/dev/null || true
cp -R lang/en.lproj lang/pt-BR.lproj "$APP/Contents/Resources/"

codesign --force --sign - --identifier local.timbre "$APP"

# Finder caches icons; touching the bundle forces a re-read.
touch "$APP"
echo "installed: $APP"
