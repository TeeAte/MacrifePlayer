#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-file-buffer-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" \
    Playback/FilePlaybackBuffer.swift Playback/BoundedQueue.swift Tests/FilePlaybackBufferTests.swift \
    -o "$test_dir/file-buffer-tests"
"$test_dir/file-buffer-tests"
