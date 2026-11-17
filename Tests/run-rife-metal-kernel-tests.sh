#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-rife-kernels.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -module-cache-path "$test_dir/modules" Playback/RIFEMetalKernels.swift \
    Tests/RIFEMetalKernelTests.swift -o "$test_dir/rife-kernel-tests"
"$test_dir/rife-kernel-tests"
