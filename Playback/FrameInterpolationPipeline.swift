import Foundation

/// Each source owns its model sessions, pair history, format converter and
/// settings. Only backend implementations are shared between the two routes.
final class FrameInterpolationPipeline {
    let inputKind: PlaybackInputKind
    let settings: PlaybackSettings
    let fallback = RIFEInterpolationEngine()
    let apple = AppleLowLatencyInterpolator()
    let metalFX = MetalFXCaptureInterpolator()
    let rifeMetal = RifeMetalFastInterpolator()
    let packed422 = Packed422GPUConverter()
    private(set) var coreML = CoreMLRIFEEngine()
    var selectionKey: String?
    let textStabilizer: CaptureTextStabilizer?
    var textPrevious: DecodedVideoFrame?

    init(inputKind: PlaybackInputKind) {
        self.inputKind = inputKind
        settings = PlaybackSettings.forInput(inputKind)
        textStabilizer = inputKind == .captureCard ? CaptureTextStabilizer() : nil
    }

    func discardPairHistory() {
        fallback.reset()
        apple.discardPreviousFrame()
        metalFX.discardPreviousFrame()
        rifeMetal.discardPreviousFrame()
        coreML.reset()
        selectionKey = nil
        textPrevious = nil; textStabilizer?.reset()
    }

    /// Called only after this source's processing/worker queues have stopped.
    func close() {
        fallback.reset(); apple.reset(); metalFX.reset(); rifeMetal.reset()
        packed422.reset(); coreML = CoreMLRIFEEngine(); selectionKey = nil
        textPrevious = nil; textStabilizer?.reset()
    }

    func snapshot(for backend: InterpolationBackend)
        -> (frames: Int, status: String, processingSeconds: Double, active: Bool) {
        switch backend {
        case .rifeMetalFast:
            var value = rifeMetal.snapshot
            if settings.captureTextStability { value.processingSeconds += textStabilizer?.postprocessSeconds ?? 0 }
            return value
        case .metalFX: return metalFX.snapshot
        case .appleVideoToolbox, .rifeCoreML: return apple.snapshot
        }
    }
}
