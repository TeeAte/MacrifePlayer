#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-yuvs-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -module-cache-path "$test_dir/modules" \
    Playback/Packed422GPUConverter.swift Tests/Packed422GPUConverterTests.swift \
    -o "$test_dir/yuvs-tests"
"$test_dir/yuvs-tests"
