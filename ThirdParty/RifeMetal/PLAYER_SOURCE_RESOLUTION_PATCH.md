# Player source-resolution synthesis integration

The Player keeps full-resolution source BGRA frames in RifeStream. A local optional RifeConfiguration.inferenceDivisor (integer 1...16) changes only the IFNet resolution and matching padding multiple (64 × divisor). Nil retains upstream hq/balanced/fast behavior exactly. Flow and mask are upsampled before warping/blending the original source pixels.

The existing cropped final-blend kernel is enabled for every scaled non-empty-stage graph, using padded tensor/mask indexing and source-sized output bounds. No weights or model mathematics were replaced. No source-pixel replacement is applied after the model output. Native model/static-detail tests are in Tests/run-rifemetal-detail-tests.sh at the application root.
