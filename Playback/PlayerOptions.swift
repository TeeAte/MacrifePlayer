//  PlayerOptions.swift
//  MetalPlayer 重建工程 —— 各档位枚举（Phase 2）
//
//  这些类型原先只有骨架：`MetalPlayer/{RIFE,Upscaler,Anime4K}/` 下的
//  `enum X { }` —— 一个 case 都没有。RECON-REPORT.md 第 5 节把它们列在
//  「19 个 enum 的 case 列表 —— 未知」里，因为它们不是符号、也不是字段名。
//
//  Phase 2 把 case 列表**从反射段恢复了**。方法如下，每一步都可复核：
//
//  1. `__swift5_reflstr` 是 Swift 反射字符串池。它同时装属性名**和 enum 的 case 名**
//     （后者由 `__swift5_fieldmd` 的字段描述符引用）。
//  2. 这个池是**全局去重 + 字典序**的，不是按类型分块的
//     （实测：索引 0..883，`AllCases` 打头，`av1LengthDelimited`、`backButton` … 严格递增）。
//     所以拿不到「某个 enum 的连续 block」，只能反着做：
//     **用文案表推出候选名，再回池里核对**。
//  3. 文案表（`zh-Hans.lproj/Localizable.strings`）给出显示名，池里正好有对应的 case 名。
//
//  核对结果（每一项都一一对上，无剩余、无缺漏）：
//
//     rife_mode_off/2x/3x/4x/5x/60   →  off / x2 / x3 / x4 / x5 / fps60
//     rife_quality_low_latency/…     →  lowLatency / stable / highQuality
//     rife_resolution_sweet/…/top    →  sweet / normal / quality / top
//     DRBA 两代模型                   →  v1 / v2Lite
//
//  另外反射池还独立佐证了这几个类型的**方法面**（这些名字在符号表里也出现过）：
//     RIFERateMode     : title / statusTitle / next / allCases /
//                        userSelectableCases / userSelectableFallback / needsTimelineResample
//     RIFEModelResolution / DistilDRBAModelResolution : userSelectableFallback / title / descriptor
//     DistilDRBAModelVersion : availableResolutions / userSelectableResolutions
//     Anime4KPresetID  : allCases / rawValue
//  下面按这个面实现 —— 名字是读出来的，不是编的。
//
//  仍未确定的（别当成结论）：
//   · `needsTimelineResample` 的具体语义。池里有这个名字，但取值无从得知。
//     按命名与 `fps60` 的特殊性推断为「输出帧率不是源帧率的整数倍，需重采样时间轴」。
//   · `userSelectableCases` 与 `allCases` 的区别。当前 6 个 case 全部可选，
//     保留这个入口只为将来加内部档位时不必改调用点。
//   · MetalFX 的档位枚举（`MetalFXTargetMode` / `MetalFXSpatialTargetMode`）**没找到 case 名**，
//     见 `Playback/UI/PlaybackSettings.swift` 里的说明。

import Foundation

// MARK: - 补帧档位

/// 补帧档位。控制条上的「补帧」按钮与它的弹出菜单都吃这个。
enum RIFERateMode: String, CaseIterable {
    case off
    case x2
    case x3
    case x4
    case x5
    case fps60
    case fps120
    case customFps

    /// 弹出菜单里的短标签，对应 `rife_mode_*`。
    var title: String {
        switch self {
        case .off:       return L10n.t("rife_mode_off")
        case .x2:        return L10n.t("rife_mode_2x")
        case .x3:        return L10n.t("rife_mode_3x")
        case .x4:        return L10n.t("rife_mode_4x")
        case .x5:        return L10n.t("rife_mode_5x")
        case .fps60:     return L10n.t("rife_mode_60")
        case .fps120:    return "120 FPS (高刷)"
        case .customFps: return "自定义 FPS"
        }
    }

    /// 状态胶囊上的文案，对应 `rife_status_*`（"RIFE 已关闭" / "RIFE 2X" …）。
    var statusTitle: String {
        switch self {
        case .off:       return L10n.t("rife_status_off")
        case .x2:        return L10n.t("rife_status_2x")
        case .x3:        return L10n.t("rife_status_3x")
        case .x4:        return L10n.t("rife_status_4x")
        case .x5:        return L10n.t("rife_status_5x")
        case .fps60:     return L10n.t("rife_status_60")
        case .fps120:    return "RIFE 120 FPS"
        case .customFps: return "RIFE 自定义"
        }
    }

    /// 控制条按钮上的文案，对应 `rife_off` / `rife_on`（"补帧 OFF" / "补帧 ON"）。
    var barTitle: String { self == .off ? L10n.t("rife_off") : L10n.t("rife_on") }

    /// 循环到下一个档位（`PlayerController.handleCycleRIFERateMode` 用它）。
    var next: RIFERateMode {
        let all = RIFERateMode.userSelectableCases
        guard let i = all.firstIndex(of: self) else { return .off }
        return all[(i + 1) % all.count]
    }

    /// 输出帧率倍数。`.fps60`, `.fps120`, `.customFps` 是目标帧率，不是固定倍数。
    var multiplier: Int? {
        switch self {
        case .off, .fps60, .fps120, .customFps: return nil
        case .x2: return 2
        case .x3: return 3
        case .x4: return 4
        case .x5: return 5
        }
    }

    /// 是否走「目标帧率」分支而不是整数倍插帧。
    /// 逆向对齐原版 `$s11MetalPlayer12RIFERateModeO21needsTimelineResample9sourceFPSSbSd_tF`:
    /// 当且仅当 sourceFPS < 29.0 且处于 .fps60 / .fps120 / .customFps 时才需要时间轴重采样；
    /// 若输入本身 >= 29.0 (如 30fps/60fps)，30fps 转 60fps 自然对齐 2X 整倍，无需小数时间轴重采样。
    func needsTimelineResample(sourceFPS: Double) -> Bool {
        guard sourceFPS < 29.0 else { return false }
        switch self {
        case .fps60, .fps120, .customFps: return true
        default: return false
        }
    }

    var needsTimelineResample: Bool {
        return needsTimelineResample(sourceFPS: 24.0)
    }

    /// 菜单里可选的预设档位。
    static var userSelectableCases: [RIFERateMode] {
        [.off, .x2, .x3, .x4, .x5, .fps60, .fps120]
    }

    /// 非法值回落。
    static var userSelectableFallback: RIFERateMode { .off }
}

/// RIFE 计算精度
enum RIFEComputePrecision: String, CaseIterable {
    case fp16 = "fp16"
    case fp32 = "fp32"

    var title: String {
        switch self {
        case .fp16: return "FP16 半精度 (推荐，神经网络与 Metal 加速)"
        case .fp32: return "FP32 单精度 (完整浮点精度)"
        }
    }

    var shortTitle: String {
        switch self {
        case .fp16: return "FP16"
        case .fp32: return "FP32"
        }
    }
}

// MARK: - 补帧质量档位

/// 补帧质量档位，对应 `rife_quality_*`。
/// 观测到 `PlayerController.handleCycleRIFEQualityMode()`，所以也是可循环的。
enum RIFEQualityMode: String, CaseIterable {
    case lowLatency
    case stable
    case highQuality

    var title: String {
        switch self {
        case .lowLatency:  return L10n.t("rife_quality_low_latency")
        case .stable:      return L10n.t("rife_quality_stable")
        case .highQuality: return L10n.t("rife_quality_high_quality")
        }
    }

    var next: RIFEQualityMode {
        let all = RIFEQualityMode.allCases
        guard let i = all.firstIndex(of: self) else { return .stable }
        return all[(i + 1) % all.count]
    }
}

// MARK: - RIFE 模型档位

/// RIFE 推理分辨率档位，对应 `rife_resolution_*`。
/// 观测到的成员：`userSelectableFallback`（+ 从文案表拿到的 4 个档位名）。
enum RIFEModelResolution: String, CaseIterable {
    case sweet
    case normal
    case quality
    case top

    var title: String {
        switch self {
        case .sweet:   return L10n.t("rife_resolution_sweet")
        case .normal:  return L10n.t("rife_resolution_normal")
        case .quality: return L10n.t("rife_resolution_quality")
        case .top:     return L10n.t("rife_resolution_top")
        }
    }

    /// ⚠️ 这里原本有一个 `restartNotice`（拼 `rife_resolution_selected_restart`：
    /// 「已选择 RIFE 模型配置：%@。\n下次重启播放器后生效。」）。
    /// Phase 2 把设置改成**热切换**之后它没有调用点了 —— 管线就地重建，
    /// 不再提示重启 —— 所以连同 `L10n.Placeholders` 里那三个拼装函数一起删掉。
    /// 文案 key 本身仍在原版 `Localizable.strings` 里（我们只是不再显示它）。
    /// 见 `L10n.retiredKeys`。

    static var userSelectableCases: [RIFEModelResolution] { allCases }
    static var userSelectableFallback: RIFEModelResolution { .normal }
}

// MARK: - DRBA（超分）模型版本与档位

/// DistilDRBA 的两代模型。观测到成员：`availableResolutions` / `userSelectableResolutions`。
enum DistilDRBAModelVersion: String, CaseIterable {
    case v1
    case v2Lite

    /// 显示名。文案表里没有 DRBA 版本名的条目（原版大概率直接显示目录名），
    /// 所以这里用推断的短名 —— `v2Lite` 这个名字本身是从反射池读到的。
    var title: String {
        switch self {
        case .v1:     return "V1"
        case .v2Lite: return "V2-Lite"
        }
    }

    /// 该版本支持的档位。
    /// 未知：`availableResolutions` 在各版本下到底返回哪几个 —— 反射池只给了方法名。
    /// 这里先两个版本都返回全部档位（**推断**），接后端时按模型目录实际情况收窄。
    var availableResolutions: [DistilDRBAModelResolution] {
        DistilDRBAModelResolution.allCases
    }

    static var userSelectableResolutions: [DistilDRBAModelVersion] { allCases }
}

/// DistilDRBA 的档位。观测到成员：`title` / `descriptor`。
/// 档位名与 RIFE 共用同一批文案（`rife_resolution_*`）。
enum DistilDRBAModelResolution: String, CaseIterable {
    case sweet
    case normal
    case quality
    case top

    var title: String {
        switch self {
        case .sweet:   return L10n.t("rife_resolution_sweet")
        case .normal:  return L10n.t("rife_resolution_normal")
        case .quality: return L10n.t("rife_resolution_quality")
        case .top:     return L10n.t("rife_resolution_top")
        }
    }

    /// 同上：原版这里有一个 `restartNotice`（`drba_resolution_selected_restart`），
    /// 热切换之后没有调用点了，已删。
}
