// Anime4KPreset.swift
// Macrife Player · Phase 5 Anime4K 增强预设参数配置

import Foundation

/// Anime4K 运行时配置预设结构体
struct Anime4KPreset: Hashable, Equatable {
    var id: Anime4KPresetID
    var lineSharpness: Float
    var denoiseStrength: Float
    var isEnabled: Bool

    init(
        id: Anime4KPresetID = .p1080,
        lineSharpness: Float = 1.0,
        denoiseStrength: Float = 0.5,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.lineSharpness = lineSharpness
        self.denoiseStrength = denoiseStrength
        self.isEnabled = isEnabled
    }

    static let `default` = Anime4KPreset(id: .p1080, lineSharpness: 1.0, denoiseStrength: 0.5, isEnabled: true)

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(lineSharpness)
        hasher.combine(denoiseStrength)
        hasher.combine(isEnabled)
    }
}
