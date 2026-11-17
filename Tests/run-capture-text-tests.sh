#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-capture-text-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -module-cache-path "$test_dir/modules" \
    Playback/VideoDecoder.swift Playback/LiveCapturePipeline.swift Playback/Packed422GPUConverter.swift \
    Playback/CaptureTextStabilizer.swift Playback/AppleLowLatencyInterpolator.swift Playback/MetalFXCaptureInterpolator.swift \
    Tests/CaptureTextStabilityTests.swift -o "$test_dir/capture-text-tests"
"$test_dir/capture-text-tests"
