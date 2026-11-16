# Macrife Player embedding

Source: https://github.com/cinemore/rife-metal

Pinned revision: `f18852ddb72f5706ddbeb3333b80643a63634222`.
Archive and bundled weight SHA-256 are recorded in `UPSTREAM.json`.

The original package manifest is preserved in `Package.upstream.swift`.
The embedding manifest builds only the two library targets and the upstream
Metal shader plugin. The CLI, test targets and swift-argument-parser dependency
are omitted. Upstream inference code and the RIFE 4.25 weights are unchanged.
License and weight attribution are also copied into the app resource bundle.

`Playback/RifeMetalFastInterpolator.swift` owns a persistent `.fast` `RifeStream`.
The application converts incoming SDR frames to BGRA, caches encoder features
through the stream API, converts generated midframes back to source-sized NV12,
and passes original frames through unchanged. Only 2X is enabled in this adapter;
unsupported formats, ratios or runtime failures return to Core ML RIFE.

The independent profile `macrife.interpolation.rifemetal.fast.flowResolution`
stores the input size cap, defaulting to 1080p. The UI explicitly labels this as
an input cap. Fast pads input to multiples of 256 then estimates flow on a
quarter-sized grid; diagnostics show the actual padded internal dimensions.
Numeric precision is fixed to FP16 and no ineffective precision control is shown.

Seek, stop, capture cadence changes, long input gaps, backend switches and
interpolation off/on transitions clear cached frame history. Failures are cached
per source/configuration until the playback session resets to avoid repeatedly
attempting a broken model on each capture frame.

Validation on 2026-11-16: Release arm64 Xcode build succeeded; embedded weight
hash, Metal library, notices and deep/strict code signature checks passed.
Nine settings groups and sixteen capture timing/queue regressions passed.
These are not model inference or capture-performance tests. Sustained frame
rate, image quality, conversion overhead and end-to-end latency remain unmeasured.
