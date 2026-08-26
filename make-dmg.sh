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

# Timbre is ad-hoc signed rather than notarised, so macOS quarantines it on
# download and refuses to open it. These are the two ways past that.
cat > "$STAGING/READ ME FIRST.txt" <<'NOTE'
Installing Timbre
=================

1. Drag Timbre onto the Applications folder in this window.

2. Open it from Launchpad. macOS will say the app cannot be opened.
   This is expected: Timbre is not signed with a paid Apple developer
   certificate, so the system blocks anything downloaded from the internet.

3. Get past it in one of these two ways.

   The easy way
   ------------
   Open System Settings, go to Privacy & Security, scroll to the bottom.
   There should be a line saying Timbre was blocked, with a button that
   says Open Anyway. Click it, then open Timbre again and confirm.

   If that button is not there
   ---------------------------
   Open Terminal (Command + Space, type Terminal), paste this line and
   press Return:

   xattr -dr com.apple.quarantine /Applications/Timbre.app

   Nothing will appear to happen. That is fine. Open Timbre again.

4. The first time it records, macOS asks for permission. Approve Timbre
   under System Settings > Privacy & Security > Screen & System Audio
   Recording.

Questions: igor.patrick@scmp.com
NOTE

rm -f Timbre.dmg
hdiutil create -volname "Timbre" -srcfolder "$STAGING" -ov -format UDZO -quiet Timbre.dmg

echo "built: $(pwd)/Timbre.dmg ($(du -h Timbre.dmg | cut -f1))"
