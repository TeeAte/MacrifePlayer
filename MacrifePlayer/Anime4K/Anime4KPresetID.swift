// Anime4KPresetID.swift
// Macrife Player · Phase 5 Anime4K 动漫增强预设 ID

import Foundation

/// Anime4K 预设档位 ID，从二进制反射池恢复的真实 case 名 (p576 / p720 / p1080 / p2k / p4k)
enum Anime4KPresetID: String, CaseIterable, Identifiable, Codable {
    case p576 = "p576"
    case p720 = "p720"
    case p1080 = "p1080"
    case p2k = "p2k"
    case p4k = "p4k"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .p576:  return "576p (DVD / 老旧番剧)"
        case .p720:  return "720p (标清动漫)"
        case .p1080: return "1080p (高清动漫 · 推荐)"
        case .p2k:   return "2K (1440p 高精)"
        case .p4k:   return "4K (超高清视网膜)"
        }
    }

    var shortTitle: String {
        switch self {
        case .p576:  return "576p"
        case .p720:  return "720p"
        case .p1080: return "1080p"
        case .p2k:   return "2K"
        case .p4k:   return "4K"
        }
    }

    /// 对应权重模型文件前缀
    var modelName: String {
        switch self {
        case .p576:  return "Anime4K_Restore_CNN_S"
        case .p720:  return "Anime4K_Restore_CNN_M"
        case .p1080: return "Anime4K_Restore_CNN_VL"
        case .p2k:   return "Anime4K_Restore_CNN_Soft_M"
        case .p4k:   return "Anime4K_Restore_CNN_Soft_VL"
        }
    }
}
