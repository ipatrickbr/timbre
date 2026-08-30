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

STEP 1, AND DO NOT SKIP IT
--------------------------
Drag the Timbre icon onto the Applications folder in this window.

Do not double-click Timbre here. Opening it from this window cannot work:
this disk image is read-only, so macOS blocks the app and cannot even offer
you the option to allow it. That is why it looks like nothing can be done.

STEP 2
------
Open Timbre from Launchpad, not from this window. macOS will say the app
cannot be opened, because Timbre is not signed with a paid Apple developer
certificate. Click "Done", NOT "Move to Trash" (the blue button deletes it).

STEP 3
------
Open System Settings > Privacy & Security and scroll to the bottom. There
should be a line about Timbre with an "Open Anyway" button. Click it, then
open Timbre again and confirm.

IF THAT BUTTON IS NOT THERE
---------------------------
This always works. Open Terminal (Command + Space, type Terminal), paste
this line and press Return:

xattr -dr com.apple.quarantine /Applications/Timbre.app

Nothing appears to happen, which is fine. Open Timbre from Launchpad again.

STEP 4
------
The first time it records, macOS asks for permission. Approve Timbre under
System Settings > Privacy & Security > Screen & System Audio Recording.

Questions: igor.patrick@scmp.com
NOTE

rm -f Timbre.dmg
hdiutil create -volname "Timbre" -srcfolder "$STAGING" -ov -format UDZO -quiet Timbre.dmg

echo "built: $(pwd)/Timbre.dmg ($(du -h Timbre.dmg | cut -f1))"
