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

STEP 1
------
Drag the Timbre icon onto the Applications folder in this window.

STEP 2
------
macOS will refuse to open Timbre, because it is not signed with a paid Apple
developer certificate. On recent versions of macOS there is often no button
anywhere to allow it, so this one line is the reliable way through.

Open Terminal (press Command + Space, type Terminal, press Return), then
paste the line below and press Return:

xattr -dr com.apple.quarantine /Applications/Timbre.app

Nothing appears to happen. That is what success looks like.

STEP 3
------
Open Timbre from Launchpad. It should open normally now.

If you get a warning with a blue "Move to Trash" button, click "Done"
instead, then run the line from step 2 again.

STEP 4
------
The first time it records, macOS asks for permission. Approve Timbre under
System Settings > Privacy & Security > Screen & System Audio Recording.

WHY THIS IS NEEDED
------------------
Signing an app so macOS trusts it on sight costs money every year. Until
that is sorted out, this line tells your Mac that you know where the app
came from. It changes nothing else on your machine.

Questions: igor.patrick@scmp.com
NOTE

rm -f Timbre.dmg
hdiutil create -volname "Timbre" -srcfolder "$STAGING" -ov -format UDZO -quiet Timbre.dmg

echo "built: $(pwd)/Timbre.dmg ($(du -h Timbre.dmg | cut -f1))"
