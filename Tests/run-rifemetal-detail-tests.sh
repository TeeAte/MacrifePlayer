#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-rifedetail-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
products=${MP_RELEASE_PRODUCTS:-/tmp/macrife-player-release-derived/Build/Products/Release}
app="$test_dir/DetailTests.app"
mkdir -p "$app/Contents/MacOS"
ln -s "$PWD/Macrife Player.app/Contents/Resources" "$app/Contents/Resources"
xcrun swiftc -O -module-cache-path "$test_dir/modules" -I "$products" \
    "$products/RifeMetal.o" "$products/RifeMetalCore.o" \
    Playback/VideoDecoder.swift Playback/AppleLowLatencyInterpolator.swift Playback/CaptureTextStabilizer.swift \
    Playback/Packed422GPUConverter.swift Playback/LiveCapturePipeline.swift Playback/RifeMetalFastInterpolator.swift \
    Tests/RifeMetalSourceDetailTests.swift \
    -o "$app/Contents/MacOS/DetailTests"
"$app/Contents/MacOS/DetailTests"
