#!/bin/bash
# Builds Timbre.app and installs it into ~/Applications.
# The signed bundle is what macOS grants the audio recording permission to.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Timbre.app"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
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
    <string>Timbre needs this access to record the audio playing on your Mac.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Timbre needs this access to include your own voice when you turn on "Include microphone" for an interview.</string>
</dict>
</plist>
PLIST

# The log is filtered only to hide warnings; an error must fail the build,
# otherwise the app stays installed with the old binary and nobody notices.
# Built for both architectures and pinned to the oldest macOS we support.
# Without an explicit target, swiftc stamps the machine's own OS version as the
# minimum, and the app then refuses to launch on anything older.
DEPLOYMENT_TARGET="14.4"
SOURCES="main.swift tap.swift sck.swift mic.swift menubar.swift transcribe.swift download.swift"
FRAMEWORKS="-framework CoreAudio -framework AudioToolbox -framework AVFoundation
            -framework ScreenCaptureKit -framework AppKit"

BUILD_LOG=$(mktemp)
SLICES=()
for arch in arm64 x86_64; do
    if ! swiftc -O -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
        -o "$STAGE/timbre-$arch" $SOURCES $FRAMEWORKS 2> "$BUILD_LOG"; then
        grep -vE "warning:|note:" "$BUILD_LOG" >&2
        rm -f "$BUILD_LOG"
        echo "ERROR: build failed for $arch - the app was NOT updated." >&2
        exit 1
    fi
    SLICES+=("$STAGE/timbre-$arch")
done
rm -f "$BUILD_LOG"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/timbre"

# Resources: the MP3 encoder, the icon and both translations ride inside.
if [[ -x vendor/bin/lame ]]; then
    cp vendor/bin/lame "$APP/Contents/Resources/lame"
else
    echo "note: MP3 encoder missing - run ./vendor/build-lame.sh to enable MP3 output." >&2
fi
[[ -f icon/AppIcon.icns ]] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp sounds/start.wav sounds/stop.wav "$APP/Contents/Resources/" 2>/dev/null || true
cp -R lang/en.lproj lang/pt-BR.lproj "$APP/Contents/Resources/"

# The transcription engine travels inside the app, so a downloaded copy needs
# no compiler. Only the language models are fetched later, at runtime.
ENGINE_SRC=""
for candidate in "vendor/whisper.cpp/build/bin" "$HOME/Library/Application Support/Timbre/whisper"; do
    [[ -x "$candidate/whisper-cli" ]] && ENGINE_SRC="$candidate" && break
done
if [[ -n "$ENGINE_SRC" ]]; then
    mkdir -p "$APP/Contents/Resources/whisper"
    cp "$ENGINE_SRC/whisper-cli" "$APP/Contents/Resources/whisper/"
    cp "$ENGINE_SRC"/*.dylib "$APP/Contents/Resources/whisper/"
    # whisper-cli is linked with an rpath pointing at the build directory on
    # this machine, which does not exist anywhere else. Point it at its own
    # folder instead, where the libraries travel.
    WHISPER_DIR="$APP/Contents/Resources/whisper"
    for binary in "$WHISPER_DIR/whisper-cli" "$WHISPER_DIR"/*.dylib; do
        while read -r stale; do
            [[ -n "$stale" ]] && install_name_tool -delete_rpath "$stale" "$binary" 2>/dev/null
        done < <(otool -l "$binary" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')
        install_name_tool -add_rpath "@executable_path" "$binary" 2>/dev/null || true
        install_name_tool -add_rpath "@loader_path" "$binary" 2>/dev/null || true
    done

    # Nested binaries must be signed after patching and before the bundle.
    codesign --force --sign - "$WHISPER_DIR"/*.dylib
    codesign --force --sign - "$WHISPER_DIR/whisper-cli"
else
    echo "note: transcription engine not found; run ./vendor/build-whisper.sh to include it." >&2
fi

codesign --force --sign - --identifier local.timbre "$APP"

# Finder caches icons; touching the bundle forces a re-read.
touch "$APP"
echo "installed: $APP"
