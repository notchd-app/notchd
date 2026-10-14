#!/bin/sh
# Builds ungive/mediaremote-adapter (BSD-3) into .build/mediaremote/ — the macOS 15.4+ Now Playing workaround.
set -e
cd "$(dirname "$0")/.."
REV=797729d9b16316dc313844476c153d7a107ca0df
SRC=.build/mediaremote-src
OUT=.build/mediaremote
[ -f "$OUT/MediaRemoteAdapter.framework/MediaRemoteAdapter" ] && exit 0
command -v cmake >/dev/null || { echo "error: cmake is required to build the media helper. Install it with: brew install cmake" >&2; exit 1; }
rm -rf "$SRC"
git clone -q https://github.com/ungive/mediaremote-adapter "$SRC"
git -C "$SRC" checkout -q "$REV"
cmake -S "$SRC" -B "$SRC/build" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$SRC/build" --config Release >/dev/null
mkdir -p "$OUT"
cp -R "$SRC/build/MediaRemoteAdapter.framework" "$OUT/"
cp "$SRC/bin/mediaremote-adapter.pl" "$SRC/LICENSE" "$OUT/"
