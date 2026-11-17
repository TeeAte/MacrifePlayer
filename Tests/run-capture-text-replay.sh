#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-capture-text-replay.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -O -module-cache-path "$test_dir/modules" \
    Playback/VideoDecoder.swift Playback/LiveCapturePipeline.swift Playback/Packed422GPUConverter.swift \
    Playback/CaptureTextStabilizer.swift Playback/AppleLowLatencyInterpolator.swift \
    Tests/CaptureTextRecordedReplay.swift -o "$test_dir/replay"
"$test_dir/replay" "${1:-output/capture-text-20261117/recorded-source}" "${2:-}"
