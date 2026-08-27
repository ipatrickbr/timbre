#!/bin/bash
# Downloads and builds LAME, the MP3 encoder, into vendor/.
# LAME is LGPL and is deliberately not committed to this repository: each
# machine builds its own copy, which keeps the licensing clean.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="3.100"
SHA256="ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"
TARBALL="lame-$VERSION.tar.gz"
URL="https://downloads.sourceforge.net/project/lame/lame/$VERSION/$TARBALL"

if [[ -x bin/lame ]]; then
    echo "LAME already built: $(pwd)/bin/lame"
    exit 0
fi

echo "Downloading LAME $VERSION..."
curl -sL --max-time 180 -o "$TARBALL" "$URL"

echo "Verifying checksum..."
ACTUAL="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [[ "$ACTUAL" != "$SHA256" ]]; then
    echo "ERROR: checksum mismatch." >&2
    echo "  expected: $SHA256" >&2
    echo "  got:      $ACTUAL" >&2
    rm -f "$TARBALL"
    exit 1
fi

# Without this the compiler stamps this machine's macOS as the minimum, and the
# binary refuses to run on anything older.
export MACOSX_DEPLOYMENT_TARGET=14.4

echo "Building..."
rm -rf "lame-$VERSION"
tar xzf "$TARBALL"
cd "lame-$VERSION"
./configure --prefix="$(cd .. && pwd)" --disable-shared --disable-dependency-tracking >/dev/null
make -j"$(sysctl -n hw.ncpu)" >/dev/null
make install >/dev/null
cd ..
rm -rf "lame-$VERSION" "$TARBALL"

echo "LAME ready: $(pwd)/bin/lame"
