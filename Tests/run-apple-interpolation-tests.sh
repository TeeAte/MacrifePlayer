#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-apple-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -module-cache-path "$test_dir/modules" \
    Playback/VideoDecoder.swift Playback/AppleLowLatencyInterpolator.swift Playback/CaptureTextStabilizer.swift Playback/Packed422GPUConverter.swift Playback/LiveCapturePipeline.swift \
    Tests/AppleInterpolationSmokeTests.swift -o "$test_dir/apple-interpolation-tests"
"$test_dir/apple-interpolation-tests"
