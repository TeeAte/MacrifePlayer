#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /private/tmp/macrife-settings-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -module-cache-path "$test_dir/modules" \
    Playback/PlayerOptions.swift Playback/UI/L10n.swift Playback/UI/PlaybackSettings.swift Playback/App/DevFlag.swift \
    MacrifePlayer/Anime4K/Anime4KPresetID.swift Playback/LiveCapturePipeline.swift \
    Tests/InterpolationSettingsTests.swift -o "$test_dir/settings-tests"
"$test_dir/settings-tests"
