import Foundation

@main
enum InterpolationSettingsTests {
    static func main() {
        withDefaults { defaults in
            defaults.set("appleLowLatency", forKey: PlaybackSettings.Key.rifeModel.rawValue)
            defaults.set("extreme", forKey: PlaybackSettings.Key.captureLowLatencyMode.rawValue)
            let settings = PlaybackSettings(defaults: defaults)
            precondition(settings.interpolationBackend == .appleVideoToolbox)
            precondition(settings.rifeModel == .v426)
            precondition(settings.interpolationFlowResolution == .p720)
            precondition(settings.captureLowLatencyMode == .extreme)
            precondition(settings.availableComputePrecisions.isEmpty)
        }
        withDefaults { defaults in
            defaults.set("heavy426", forKey: PlaybackSettings.Key.rifeModel.rawValue)
            defaults.set("fp32", forKey: PlaybackSettings.Key.rifePrecision.rawValue)
            let settings = PlaybackSettings(defaults: defaults)
            precondition(settings.interpolationBackend == .rifeCoreML && settings.rifeModel == .heavy426)
            precondition(settings.interpolationFlowResolution == .p576)
            precondition(settings.rifePrecision == .fp16, "Do not claim that an old, ineffective FP32 toggle selected FP32 weights")
        }
        withDefaults { defaults in
            let settings = PlaybackSettings(defaults: defaults)
            settings.interpolationFlowResolution = .p1080
            settings.rifeModel = .heavy426
            precondition(settings.interpolationFlowResolution == .p576)
            settings.interpolationFlowResolution = .p720
            settings.interpolationBackend = .appleVideoToolbox
            precondition(settings.interpolationFlowResolution == .p720)
            settings.interpolationFlowResolution = .p1440
            settings.interpolationBackend = .rifeCoreML
            precondition(settings.interpolationFlowResolution == .p720)
            settings.rifeModel = .v426
            precondition(settings.interpolationFlowResolution == .p1080)
            let reopened = PlaybackSettings(defaults: defaults)
            precondition(reopened.interpolationFlowResolution == .p1080)
            reopened.interpolationBackend = .appleVideoToolbox
            precondition(reopened.interpolationFlowResolution == .p1440)
        }
        withDefaults { defaults in
            let settings = PlaybackSettings(defaults: defaults)
            settings.interpolationBackend = .appleVideoToolbox
            settings.interpolationFlowResolution = .p1080
            settings.captureLowLatencyMode = .extreme
            settings.rifeModel = .heavy426
            precondition(settings.interpolationBackend == .appleVideoToolbox)
            precondition(settings.interpolationFlowResolution == .p1080)
            settings.interpolationBackend = .rifeCoreML
            precondition(settings.captureLowLatencyMode == .extreme && settings.rifeModel == .heavy426)
            settings.captureLowLatencyMode = .off
            precondition(settings.rifeModel == .heavy426 && settings.interpolationFlowResolution == .p576)
        }
        withDefaults { defaults in
            let settings = PlaybackSettings(defaults: defaults)
            precondition(settings.availableComputePrecisions == [.fp16])
            precondition(settings.availableComputePrecisions.count <= 1, "Hide a numeric-precision selector that cannot change anything")
            settings.rifePrecision = .fp32
            precondition(settings.rifePrecision == .fp16)
            settings.rifeModel = .heavy426
            settings.interpolationFlowResolution = .p720
            settings.interpolationFlowResolution = .p1440
            precondition(settings.interpolationFlowResolution == .p720)
            precondition(!settings.availableFlowResolutions.contains(.p1440))
            settings.resetRIFEToDefaults()
            precondition(settings.interpolationBackend == .rifeCoreML && settings.rifeModel == .v426)
            precondition(settings.interpolationFlowResolution == .p576 && settings.captureLowLatencyMode == .balanced)
            settings.rifeModel = .heavy426
            precondition(settings.interpolationFlowResolution == .p576)
        }
        withDefaults { defaults in
            let settings = PlaybackSettings(defaults: defaults)
            settings.interpolationBackend = .metalFX
            precondition(settings.interpolationFlowResolution == .p720)
            settings.interpolationFlowResolution = .p1080
            precondition(settings.availableComputePrecisions.isEmpty)
            precondition(settings.computePrecisionDescription.contains("系统管理"))
            settings.interpolationBackend = .appleVideoToolbox
            settings.interpolationFlowResolution = .p576
            settings.interpolationBackend = .rifeCoreML
            settings.interpolationFlowResolution = .p1440
            let reopened = PlaybackSettings(defaults: defaults)
            reopened.interpolationBackend = .metalFX
            precondition(reopened.interpolationFlowResolution == .p1080)
            reopened.resetRIFEToDefaults()
            reopened.interpolationBackend = .metalFX
            precondition(reopened.interpolationFlowResolution == .p720)
        }
        withDefaults { defaults in
            let settings = PlaybackSettings(defaults: defaults)
            settings.interpolationFlowResolution = .p576
            settings.interpolationBackend = .rifeMetalFast
            precondition(settings.interpolationFlowResolution == .p1080)
            precondition(settings.availableComputePrecisions.isEmpty)
            precondition(settings.computePrecisionDescription.contains("FP16"))
            settings.interpolationFlowResolution = .p720
            settings.captureLowLatencyMode = .extreme
            settings.interpolationBackend = .appleVideoToolbox
            precondition(settings.interpolationFlowResolution == .p720)
            settings.interpolationFlowResolution = .p1440
            let reopened = PlaybackSettings(defaults: defaults)
            reopened.interpolationBackend = .rifeMetalFast
            precondition(reopened.interpolationFlowResolution == .p720)
            precondition(reopened.captureLowLatencyMode == .extreme)
            reopened.interpolationBackend = .rifeCoreML
            precondition(reopened.interpolationFlowResolution == .p576)
            reopened.resetRIFEToDefaults()
            reopened.interpolationBackend = .rifeMetalFast
            precondition(reopened.interpolationFlowResolution == .p1080)
        }
        precondition(RIFEModelChoice.v426.compiledVariant(resolution: .p576) == "rife_426_fp16_576p_blocks")
        precondition(RIFEModelChoice.v426.compiledVariant(resolution: .p720) == "rife_426_fp16_blocks_extended")
        precondition(RIFEModelChoice.v426.compiledVariant(resolution: .p1080) == "rife_426_fp16_1080p_blocks")
        precondition(RIFEModelChoice.heavy426.compiledVariant(resolution: .p1440) == nil)
        let hd = InferenceGeometry.fit(sourceWidth: 1920, sourceHeight: 1080, maxHeight: 720)
        precondition(hd.width == 1280 && hd.height == 720)
        let full = InferenceGeometry.fit(sourceWidth: 1920, sourceHeight: 1080, maxHeight: 1440)
        precondition(full.width == 1920 && full.height == 1080, "Inference quality must not upscale the source")
        let smaller = InferenceGeometry.fit(sourceWidth: 1920, sourceHeight: 1080, maxHeight: 576)
        precondition(smaller.width == 1024 && smaller.height == 576)
        print("PASS: 9 configuration checks (migration, profiles, persistence, latency independence, precision capabilities, MetalFX/RifeMetal profiles, model variants, inference geometry); no GPU/model execution")
    }

    private static func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "macrife.settings.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
