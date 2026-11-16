#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-capture-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" \
    Playback/BoundedQueue.swift Playback/LiveCapturePipeline.swift \
    Playback/PlayerOptions.swift Playback/UI/L10n.swift Playback/App/DevFlag.swift \
    Tests/CaptureLatencyTests.swift -o "$test_dir/capture-latency-tests"
"$test_dir/capture-latency-tests"
