#!/bin/bash
# Builds whisper.cpp and installs the offline transcription engine.
#
# Everything lands in ~/Library/Application Support/Timbre/whisper: the binary,
# its libraries and the language model. Nothing is committed to this repository
# and nothing is sent anywhere — transcription runs entirely on this machine.
set -euo pipefail
cd "$(dirname "$0")"

MODEL="${1:-large-v3-turbo}"
# The turbo models transcribe beautifully but cannot translate, so a second,
# smaller model is installed alongside for English translation.
TRANSLATION_MODEL="small"
DEST="$HOME/Library/Application Support/Timbre/whisper"
CMAKE_VERSION="4.4.3"

if [[ -x "$DEST/whisper-cli" && -f "$DEST/models/ggml-$MODEL.bin" ]]; then
    echo "Transcription engine already installed: $DEST"
    exit 0
fi

# CMake: use the system one when present, otherwise fetch a local copy so this
# script works on a machine with nothing but the developer tools installed.
CMAKE="$(command -v cmake || true)"
if [[ -z "$CMAKE" ]]; then
    if [[ ! -x "cmake-$CMAKE_VERSION-macos-universal/CMake.app/Contents/bin/cmake" ]]; then
        echo "Downloading CMake $CMAKE_VERSION…"
        curl -sL --max-time 600 -o cmake.tar.gz \
            "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
        tar xzf cmake.tar.gz
        rm -f cmake.tar.gz
    fi
    CMAKE="$PWD/cmake-$CMAKE_VERSION-macos-universal/CMake.app/Contents/bin/cmake"
fi

if [[ ! -d whisper.cpp ]]; then
    echo "Fetching whisper.cpp…"
    git clone -q --depth 1 https://github.com/ggml-org/whisper.cpp.git
fi

echo "Building (Metal enabled — this takes a couple of minutes)…"
cd whisper.cpp
"$CMAKE" -B build -DCMAKE_BUILD_TYPE=Release -DWHISPER_BUILD_TESTS=OFF -DGGML_METAL=ON >/dev/null
"$CMAKE" --build build --config Release --parallel "$(sysctl -n hw.ncpu)" >/dev/null 2>&1

if [[ ! -f "models/ggml-$MODEL.bin" ]]; then
    echo "Downloading the $MODEL model (this is the big one, ~1.5 GB)…"
    bash models/download-ggml-model.sh "$MODEL" >/dev/null
fi

if [[ "$MODEL" == *turbo* && ! -f "models/ggml-$TRANSLATION_MODEL.bin" ]]; then
    echo "Downloading the $TRANSLATION_MODEL model for translation (~470 MB)…"
    bash models/download-ggml-model.sh "$TRANSLATION_MODEL" >/dev/null
fi

echo "Installing…"
mkdir -p "$DEST/models"
cp build/bin/whisper-cli "$DEST/"
cp build/bin/*.dylib "$DEST/"
cp "models/ggml-$MODEL.bin" "$DEST/models/"
[[ -f "models/ggml-$TRANSLATION_MODEL.bin" ]] && cp "models/ggml-$TRANSLATION_MODEL.bin" "$DEST/models/"

cd ..
echo "Transcription ready: $DEST"
echo "Turn it on in Timbre's menu: \"Transcribe after recording\"."
