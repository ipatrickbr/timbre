#!/bin/bash
# Builds Timbre.dmg: drag the app to Applications and that is the whole install.
# The transcription engine rides inside the app; the language models are fetched
# by the app itself the first time someone asks for a transcript.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Timbre.app"
[[ -d "$APP" ]] || { echo "Build the app first: ./build.sh" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f Timbre.dmg
hdiutil create -volname "Timbre" -srcfolder "$STAGING" -ov -format UDZO -quiet Timbre.dmg

echo "built: $(pwd)/Timbre.dmg ($(du -h Timbre.dmg | cut -f1))"
