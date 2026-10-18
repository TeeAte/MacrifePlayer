//  PlaybackSettings.swift
//  MetalPlayer 重建工程 —— 可持久化设置（Phase 2）
//
//  原版把这些开关与档位存在 `UserDefaults` 里：菜单项带勾选状态、控制条按钮显示当前档位，
//  重启后全部保留。重建工程沿用同一套做法，key 前缀统一 `recon.`，
//  **刻意不与原版共用 key** —— 两个 app 的 bundle ID 不同（见 RECON-REPORT.md 第 6 节），
//  UserDefaults 本来就按 bundle ID 隔离，加前缀只是让日志里一眼能认出是我们的写入。
//
//  为什么要有「变更通知」而不是各自读写：
//    同一个档位在**两个地方**显示 —— 菜单栏的勾选、控制条按钮的文字。
//    比如「补帧 2X」：模型菜单里要勾上 RIFE 4.25，控制条要显示「补帧 ON」，
//    状态胶囊要显示「RIFE 2X」。任一处改动都必须让另两处立刻跟上，
//    所以统一走一条通知，由各视图自己重读 —— 而不是让改动方去挨个通知。

import Foundation

// MARK: - 变更通知

extension Notification.Name {
    /// 任一项设置发生变化。`userInfo["key"]` 是变化的 `PlaybackSettings.Key`。
    ///
    /// 监听方一般不需要看 key（重读一遍很便宜），但日志与调试需要。
    static let playbackSettingsDidChange = Notification.Name("MPPlaybackSettingsDidChange")
}

// MARK: - 补帧模式（控制条按钮上的那条）

/// RIFE 模型的四个可选变体。
///
/// 注意：这是 **Phase 2 新增的类型**，不是从二进制恢复的。
/// 原版这里用的是 `RIFEModelVariant.allDirectoryNames`（一个目录名字符串数组，
/// 观测到的成员只有 `allDirectoryNames`），实际条目名未能恢复。
/// 下面四个名字直接来自文案表 `rife_model_425_lite` / `rife_model_425_high_quality` /
/// `rife_model_426_high_quality` / `rife_model_426_heavy` —— 是**观测**，不是编的。
/// 补帧模型大类
enum ModelFamily: String, CaseIterable {
    case rife
    case flavr
    case drba

    var title: String {
        switch self {
        case .rife:  return "RIFE (光流残差金字塔 · 通用影视)"
        case .flavr: return "FLAVR (3D时空卷积 · 纯ANE无光流)"
        case .drba:  return "DistilDRBA (距离比例 · 动漫二次元专属)"
        }
    }
}

/// FLAVR 时空卷积核类型
enum FLAVRKernelMode: String, CaseIterable {
    case hermite
    case catmullRom
    case bSpline

    var title: String {
        switch self {
        case .hermite:    return "Hermite-Lagrange 三次核 (推荐 · 最佳平滑)"
        case .catmullRom: return "Catmull-Rom 锐化核 (发丝与边缘增强)"
        case .bSpline:    return "B-Spline 柔和核 (抑制噪点与胶片颗粒)"
        }
    }
}

/// FLAVR 硬件后端偏好
enum FLAVRBackend: String, CaseIterable {
    case anePreferred
    case metalGPU

    var title: String {
        switch self {
        case .anePreferred: return "Apple Neural Engine (ANE 低功耗 · 静音)"
        case .metalGPU:     return "Metal GPU (极限吞吐 · 满血渲染)"
        }
    }
}

/// DistilDRBA 动漫抽帧灵敏度
enum DRBACadence: String, CaseIterable {
    case low
    case medium
    case high

    var title: String {
        switch self {
        case .low:    return "保守识别 (仅处理标准一拍二 · 12fps)"
        case .medium: return "标准中等 (推荐 · 自动识别 8fps/12fps)"
        case .high:   return "激进识别 (处理复杂混合抽帧动作)"
        }
    }
}

/// 反交错模式（解决 1080 50i/60i 隔行扫描拉丝，倍帧输出至 50/60 fps）
enum DeinterlaceMode: String, CaseIterable {
    case auto    // 智能自动（识别 MTS/M2TS/TS 或隔行编码视频，自动倍帧至 50/60 FPS）
    case on      // 强制 2X 反交错输出 50/60 帧
    case off     // 关闭反交错

    var title: String {
        switch self {
        case .auto: return "智能自动 (推荐 · MTS/隔行 50i/60i 自动转 50/60 帧)"
        case .on:   return "强制开启 (双场倍频 2X 反交错至 60 帧)"
        case .off:  return "关闭反交错"
        }
    }
}

/// 假 60 帧智能识别与重构模式（针对主机 30 FPS 质量模式接入采集卡）
enum Fake60OptimizationMode: String, CaseIterable {
    case auto    // 智能自动（识别 2:2 重复帧，自动将重复帧替换为真实 AI 补帧至真 60 帧）
    case on      // 强制去重重构
    case off     // 关闭识别与修复

    var title: String {
        switch self {
        case .auto: return "智能自动 (推荐 · 检测 2:2 假60帧重构为真60帧)"
        case .on:   return "强制重构 (对 60Hz 信号去重插帧)"
        case .off:  return "关闭识别 (直通输出)"
        }
    }
}

/// 采集卡/实时输入超低延迟模式
enum CaptureLowLatencyMode: String, CaseIterable {
    case extreme   // 极限电竞（1 帧极小缓冲 · 零拷贝直出 · 最低延迟）
    case balanced  // 平衡抗抖动（2 帧缓冲 · 兼顾低延迟与平稳）
    case off       // 标准缓冲（普通回放模式）

    var title: String {
        switch self {
        case .extreme:  return "极限电竞 (1 帧缓冲 · 零拷贝直出 · 最低延迟)"
        case .balanced: return "平衡抗抖动 (2 帧缓冲 · 兼顾低延迟与抗抖动)"
        case .off:      return "标准缓冲 (普通回放模式)"
        }
    }
}

/// 采集输入的色彩范围。
///
/// 为什么需要手动档：UVC 采集卡上报的像素格式与实际数据范围经常对不上 ——
/// 驱动声明 420v（限制范围）却直接透传 HDMI 的全范围数据，或反之。
/// 用错方向的表现是黑位压死 + 高光裁切（当成限制范围去展开全范围数据），
/// 或者画面发灰（当成全范围去用限制范围数据）。自动档读设备上报值，
/// 手动档给驱动说谎时留一条出路。OBS 同样提供这一档。
enum CaptureColorRange: String, CaseIterable {
    case auto
    case limited   // 限制范围 16–235（video range）
    case full      // 全范围 0–255（full range）

    var title: String {
        switch self {
        case .auto:    return "自动 (读采集卡上报)"
        case .limited: return "限制 16–235 (Video Range)"
        case .full:    return "全范围 0–255 (Full Range)"
        }
    }

    /// nil = 自动（用实测值）；否则强制该范围。
    var forcedFullRange: Bool? {
        switch self {
        case .auto:    return nil
        case .limited: return false
        case .full:    return true
        }
    }
}

/// 采集输入的色度矩阵。BT.601 与 BT.709 系数不同，用错就是偏色（肤色最明显）。
enum CaptureColorMatrix: String, CaseIterable {
    case auto
    case bt709
    case bt601
    case bt2020

    var title: String {
        switch self {
        case .auto:   return "自动 (读采集卡上报)"
        case .bt709:  return "BT.709 (高清标准)"
        case .bt601:  return "BT.601 (标清/DVD)"
        case .bt2020: return "BT.2020 (HDR 广色域)"
        }
    }

    /// 传给着色器的代号：0 = BT.601，1 = BT.709，2 = BT.2020。
    var shaderCode: Int32? {
        switch self {
        case .auto:   return nil
        case .bt601:  return 0
        case .bt709:  return 1
        case .bt2020: return 2
        }
    }
}

enum RIFEModelChoice: String, CaseIterable {
    case lite425
    case full425
    case v426
    case heavy426
    case flavr2x
    case flavrFast
    case distilDRBA

    var title: String {
        switch self {
        case .lite425:   return L10n.t("rife_model_425_lite")
        case .full425:   return L10n.t("rife_model_425_high_quality")
        case .v426:      return L10n.t("rife_model_426_high_quality")
        case .heavy426:  return L10n.t("rife_model_426_heavy")
        case .flavr2x:   return "FLAVR 2X (3D时空卷积 · 无光流)"
        case .flavrFast: return "FLAVR-Fast (极速纯ANE · 低能耗)"
        case .distilDRBA: return "DistilDRBA (动漫二次元专属 · 距离比例调整)"
        }
    }

    var groupTitle: String {
        switch self {
        case .lite425:            return L10n.t("rife_lite_mode")
        case .full425, .v426:     return L10n.t("rife_full_mode")
        case .heavy426:           return L10n.t("rife_heavy_model")
        case .flavr2x, .flavrFast: return "FLAVR 无光流时空模型"
        case .distilDRBA:         return "动漫专攻模型"
        }
    }

    var family: ModelFamily {
        switch self {
        case .lite425, .full425, .v426, .heavy426:
            return .rife
        case .flavr2x, .flavrFast:
            return .flavr
        case .distilDRBA:
            return .drba
        }
    }

    var isFLAVR: Bool {
        return family == .flavr
    }

    var isDRBA: Bool {
        return family == .drba
    }

    var modelFamilyName: String {
        switch family {
        case .rife:  return "RIFE"
        case .flavr: return "FLAVR"
        case .drba:  return "DRBA"
        }
    }
}

// MARK: - MetalFX

/// MetalFX 档位。
///
/// ⚠️ 这一组 case 是**推断**，而且证据比别处弱，理由写清楚：
///   · 文案表里只有 `metalfx_off` = "MetalFX 关闭" 一条；
///   · 符号表里有 `MetalFXSpatialUpscaler`（32 次）、`MetalFXTargetMode`（3 次）、
///     `MetalFXSpatialTargetMode`（54 次）、`currentMetalFXTargetMode` / `onSelectMetalFXTargetMode`，
///     但**反射池里找不到 `MetalFXTargetMode` 的 case 名**（池按字典序去重，
///     我把 `metalFX*` 开头的条目全列了：`metalFXAAFast / AFast / AHQ / BBFast / BFast / BHQ /
///     Button / Upscaler / VerboseLog` —— 那 6 个带 A/B 的是 Anime4K 模式名的 MetalFX 侧镜像，
///     不是 MetalFX 自己的档位）。
///   · 所以这里只保留「关」与「开（空间上采样）」两档。
///     `MetalFXSpatialUpscaler` 是唯一被大量使用的具体后端类型，
///     而 MetalFX 没有 temporal 相关符号（`temporal` 在整个符号表里 0 次命中）——
///     所以**不开时间上采样**这一档。真正的档位语义等 Phase 5 接后端时再定。
enum MetalFXOption: String, CaseIterable {
    case off
    case spatial

    /// 按钮与菜单项上的文案。
    var title: String {
        switch self {
        case .off:     return L10n.t("metalfx_off")   // 观测
        case .spatial: return "MetalFX 空间上采样"      // 推断（文案表缺条目）
        }
    }

    /// 控制条按钮上的短文案。
    var barTitle: String { self == .off ? L10n.t("metalfx_off") : title }
}

// MARK: - Anime4K

/// Anime4K 开关。
///
/// 真正的 Anime4K 界面是一个**面板**（`Anime4KPanelController`，观测），里面有
/// 预设（`anime4k_preset` = "预设"）与分辨率档（`Anime4KPresetID` 的
/// `p576 / p720 / p1080 / p2k / p4k`，从反射池读到）。那属于 Phase 5。
/// Phase 2 只做开关与回显，所以这里就是一个 Bool 加一条文案。
enum Anime4KOption: String, CaseIterable {
    case off
    case on

    var title: String {
        switch self {
        case .off: return L10n.t("anime4k_off")      // Anime4K 关闭
        case .on:  return L10n.t("anime4k_panel_title") // Anime4K 滤镜（推断）
        }
    }

    var barTitle: String { self == .off ? L10n.t("anime4k_off") : title }
}

// MARK: - 解码方式

/// 解码方式，对应 `decode_hw` / `decode_sw`。
///
/// ⚠️ Phase 2 的真实状态：**开关与回显是真的，后端还没接**。
/// Phase 1 只实现了软解（`Playback/VideoDecoder.swift`，libavcodec）。
/// 解码模式：硬解走 VideoToolbox GPU 硬件解码，软解走 FFmpeg 多线程软解。
enum DecodeMode: String, CaseIterable {
    case hardware
    case software

    var title: String {
        switch self {
        case .hardware: return L10n.t("decode_hw")   // 硬解
        case .software: return L10n.t("decode_sw")   // 软解
        }
    }
}

// MARK: - 设置本体

final class PlaybackSettings {

    static let shared = PlaybackSettings()

    /// UserDefaults 的 key，前缀统一 `macrife.`。
    enum Key: String, CaseIterable {
        case rifeRateMode = "macrife.rifeRateMode"
        case rifeQualityMode = "macrife.rifeQualityMode"
        case rifeModel = "macrife.rifeModel"
        case rifeResolution = "macrife.rifeResolution"
        case rifeWorkerCount = "macrife.rifeWorkerCount"
        case rifeTransitionDetection = "macrife.rifeTransitionDetection"
        case rifeSceneThreshold = "macrife.rifeSceneThreshold"
        case rifeStaticFrameSkip = "macrife.rifeStaticFrameSkip"
        case rifeStaticThreshold = "macrife.rifeStaticThreshold"
        case rifeScaleFactor = "macrife.rifeScaleFactor"
        case rifeCustomTargetFps = "macrife.rifeCustomTargetFps"
        case rifePrecision = "macrife.rifePrecision"
        case rifeQueueDepth = "macrife.rifeQueueDepth"
        case metalFX = "macrife.metalFX"
        case anime4k = "macrife.anime4k"
        case anime4kPresetID = "macrife.anime4kPresetID"
        case anime4kSharpness = "macrife.anime4kSharpness"
        case anime4kDenoise = "macrife.anime4kDenoise"
        case decodeMode = "macrife.decodeMode"
        case volume = "macrife.volume"
        case recentFiles = "macrife.recentFiles"

        // RIFE 专属定制
        case rifeFlowSmoothness = "macrife.rifeFlowSmoothness"
        case rifeLargeMotionAssist = "macrife.rifeLargeMotionAssist"
        case rifePyramidStages = "macrife.rifePyramidStages"

        // FLAVR 专属定制
        case flavrKernelMode = "macrife.flavrKernelMode"
        case flavrBackend = "macrife.flavrBackend"

        // DistilDRBA 专属定制
        case drbaCadence = "macrife.drbaCadence"
        case drbaLineArtPreservation = "macrife.drbaLineArtPreservation"
        case drbaExaggeratedMotionGuard = "macrife.drbaExaggeratedMotionGuard"

        // 反交错设置 (MTS / 1080 50i/60i 隔行视频双场转 60 帧)
        case deinterlaceMode = "macrife.deinterlaceMode"

        // 采集卡输入延迟与假 60 帧识别重构
        case fake60FPSOptimization = "macrife.fake60FPSOptimization"
        case captureLowLatencyMode = "macrife.captureLowLatencyMode"

        // 采集色彩（对标 OBS 的 Color Range / Color Space）
        case captureColorRange = "macrife.captureColorRange"
        case captureColorMatrix = "macrife.captureColorMatrix"

        /// 这项设置是否影响**管线本身**（解码器 / 推理链 / 渲染链）。
        var affectsPipeline: Bool {
            switch self {
            case .rifeQualityMode, .rifeModel, .rifeResolution,
                 .rifeWorkerCount, .rifeTransitionDetection, .rifeSceneThreshold,
                 .rifeStaticFrameSkip, .rifeStaticThreshold, .rifeScaleFactor,
                 .rifeCustomTargetFps, .rifePrecision, .rifeQueueDepth,
                 .rifeFlowSmoothness, .rifeLargeMotionAssist, .rifePyramidStages,
                 .flavrKernelMode, .flavrBackend,
                 .drbaCadence, .drbaLineArtPreservation, .drbaExaggeratedMotionGuard,
                 .deinterlaceMode, .fake60FPSOptimization, .captureLowLatencyMode,
                 .metalFX, .anime4k, .anime4kPresetID, .anime4kSharpness, .anime4kDenoise, .decodeMode:
                return true
            case .rifeRateMode, .volume, .recentFiles,
                 // 色彩范围 / 矩阵每帧在渲染前读取即可生效，不需要重建管线
                 .captureColorRange, .captureColorMatrix:
                return false
            }
        }

        var humanTitle: String {
            switch self {
            case .rifeRateMode:
                return MPText.t("补帧档位", "Frame interpolation")
            case .rifeQualityMode:
                return MPText.t("补帧质量", "Interpolation quality")
            case .rifeModel:
                return MPText.t("RIFE 模型", "RIFE model")
            case .rifeResolution:
                return MPText.t("模型分辨率", "Model resolution")
            case .rifeWorkerCount:
                return MPText.t("RIFE 核心数", "RIFE workers")
            case .rifeTransitionDetection:
                return MPText.t("转场检测", "Transition detection")
            case .rifeSceneThreshold:
                return MPText.t("转场灵敏度", "Transition threshold")
            case .rifeStaticFrameSkip:
                return MPText.t("静止帧跳过", "Static frame skip")
            case .rifeStaticThreshold:
                return MPText.t("静止判定阈值", "Static threshold")
            case .rifeScaleFactor:
                return MPText.t("推理缩放", "Inference scale")
            case .rifeCustomTargetFps:
                return MPText.t("自定义帧率", "Custom target FPS")
            case .rifePrecision:
                return MPText.t("计算精度", "Compute precision")
            case .rifeQueueDepth:
                return MPText.t("队列深度", "Queue depth")
            case .metalFX:
                return MPText.t("MetalFX", "MetalFX")
            case .anime4k:
                return MPText.t("Anime4K", "Anime4K")
            case .anime4kPresetID:
                return MPText.t("Anime4K 预设", "Anime4K preset")
            case .anime4kSharpness:
                return MPText.t("Anime4K 锐化", "Anime4K sharpness")
            case .anime4kDenoise:
                return MPText.t("Anime4K 降噪", "Anime4K denoise")
            case .decodeMode:
                return MPText.t("解码方式", "Decoder")
            case .volume:
                return MPText.t("音量", "Volume")
            case .recentFiles:
                return MPText.t("最近打开", "Recent files")
            case .rifeFlowSmoothness:
                return MPText.t("光流平滑度", "Flow smoothness")
            case .rifeLargeMotionAssist:
                return MPText.t("大运动补偿", "Large motion assist")
            case .rifePyramidStages:
                return MPText.t("金字塔阶段", "Pyramid stages")
            case .flavrKernelMode:
                return MPText.t("FLAVR 卷积核", "FLAVR kernel")
            case .flavrBackend:
                return MPText.t("FLAVR 硬件后端", "FLAVR backend")
            case .drbaCadence:
                return MPText.t("DRBA 抽帧检测", "DRBA cadence")
            case .drbaLineArtPreservation:
                return MPText.t("线稿保真度", "Line-art preservation")
            case .drbaExaggeratedMotionGuard:
                return MPText.t("夸张动作保护", "Exaggerated motion guard")
            case .deinterlaceMode:
                return MPText.t("反交错模式", "Deinterlace mode")
            case .fake60FPSOptimization:
                return MPText.t("假 60 帧识别重构", "Fake 60 FPS optimization")
            case .captureLowLatencyMode:
                return MPText.t("采集卡低延迟", "Capture low latency")
            case .captureColorRange:
                return MPText.t("采集色彩范围", "Capture color range")
            case .captureColorMatrix:
                return MPText.t("采集色彩矩阵", "Capture color matrix")
            }
        }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: 补帧

    /// 补帧档位。默认关闭。
    var rifeRateMode: RIFERateMode {
        get { enumValue(Key.rifeRateMode, default: .off) }
        set { setEnum(Key.rifeRateMode, newValue) }
    }

    var rifeQualityMode: RIFEQualityMode {
        get { enumValue(Key.rifeQualityMode, default: .stable) }
        set { setEnum(Key.rifeQualityMode, newValue) }
    }

    var rifeModel: RIFEModelChoice {
        get { enumValue(Key.rifeModel, default: .v426) }
        set { setEnum(Key.rifeModel, newValue) }
    }

    var rifeResolution: RIFEModelResolution {
        get { enumValue(Key.rifeResolution, default: RIFEModelResolution.userSelectableFallback) }
        set { setEnum(Key.rifeResolution, newValue) }
    }

    /// RIFE 核心数。可选值 4 / 6 / 8 / 10 / 12。默认 8。
    var rifeWorkerCount: Int {
        get {
            let v = defaults.integer(forKey: Key.rifeWorkerCount.rawValue)
            return Self.rifeWorkerChoices.contains(v) ? v : 8
        }
        set {
            let v = Self.rifeWorkerChoices.contains(newValue) ? newValue : 8
            defaults.set(v, forKey: Key.rifeWorkerCount.rawValue)
            notify(.rifeWorkerCount)
        }
    }

    static let rifeWorkerChoices = [4, 6, 8, 10, 12]

    /// 转场检测。
    var rifeTransitionDetection: Bool {
        get {
            if defaults.object(forKey: Key.rifeTransitionDetection.rawValue) == nil { return true }
            return defaults.bool(forKey: Key.rifeTransitionDetection.rawValue)
        }
        set {
            defaults.set(newValue, forKey: Key.rifeTransitionDetection.rawValue)
            notify(.rifeTransitionDetection)
        }
    }

    /// 转场灵敏度阈值 (0.05 ~ 0.80, 默认 0.30)。差异大于该值判定为场景切换，不融合插帧。
    var rifeSceneThreshold: Double {
        get {
            if defaults.object(forKey: Key.rifeSceneThreshold.rawValue) == nil { return 0.30 }
            let v = defaults.double(forKey: Key.rifeSceneThreshold.rawValue)
            return max(0.05, min(0.80, v))
        }
        set {
            let v = max(0.05, min(0.80, newValue))
            defaults.set(v, forKey: Key.rifeSceneThreshold.rawValue)
            notify(.rifeSceneThreshold)
        }
    }

    /// 静止画面跳过（节能与防发热）。
    var rifeStaticFrameSkip: Bool {
        get {
            if defaults.object(forKey: Key.rifeStaticFrameSkip.rawValue) == nil { return true }
            return defaults.bool(forKey: Key.rifeStaticFrameSkip.rawValue)
        }
        set {
            defaults.set(newValue, forKey: Key.rifeStaticFrameSkip.rawValue)
            notify(.rifeStaticFrameSkip)
        }
    }

    /// 静止画面判定阈值 (0.005 ~ 0.10, 默认 0.02)。
    var rifeStaticThreshold: Double {
        get {
            if defaults.object(forKey: Key.rifeStaticThreshold.rawValue) == nil { return 0.02 }
            let v = defaults.double(forKey: Key.rifeStaticThreshold.rawValue)
            return max(0.005, min(0.10, v))
        }
        set {
            let v = max(0.005, min(0.10, newValue))
            defaults.set(v, forKey: Key.rifeStaticThreshold.rawValue)
            notify(.rifeStaticThreshold)
        }
    }

    /// 细粒度推理分辨率缩放因数 (0.25 ~ 2.00, 默认 1.0)。
    var rifeScaleFactor: Double {
        get {
            if defaults.object(forKey: Key.rifeScaleFactor.rawValue) == nil { return 1.0 }
            let v = defaults.double(forKey: Key.rifeScaleFactor.rawValue)
            return max(0.25, min(2.0, v))
        }
        set {
            let v = max(0.25, min(2.0, newValue))
            defaults.set(v, forKey: Key.rifeScaleFactor.rawValue)
            notify(.rifeScaleFactor)
        }
    }

    /// 自定义目标帧率 (24.0 ~ 240.0, 默认 60.0)。
    var rifeCustomTargetFps: Double {
        get {
            let v = defaults.double(forKey: Key.rifeCustomTargetFps.rawValue)
            return v > 0 ? max(24.0, min(240.0, v)) : 60.0
        }
        set {
            let v = max(24.0, min(240.0, newValue))
            defaults.set(v, forKey: Key.rifeCustomTargetFps.rawValue)
            notify(.rifeCustomTargetFps)
        }
    }

    /// 计算精度 (FP16 / FP32)。
    var rifePrecision: RIFEComputePrecision {
        get { enumValue(Key.rifePrecision, default: .fp16) }
        set { setEnum(Key.rifePrecision, newValue) }
    }

    /// 预缓冲队列深度 (2 / 4 / 8 / 12, 默认 4)。
    var rifeQueueDepth: Int {
        get {
            let v = defaults.integer(forKey: Key.rifeQueueDepth.rawValue)
            return [2, 4, 8, 12].contains(v) ? v : 4
        }
        set {
            let v = [2, 4, 8, 12].contains(newValue) ? newValue : 4
            defaults.set(v, forKey: Key.rifeQueueDepth.rawValue)
            notify(.rifeQueueDepth)
        }
    }

    // MARK: - 模型专属定制参数

    // 1. RIFE 专属
    var rifeFlowSmoothness: Double {
        get {
            if defaults.object(forKey: Key.rifeFlowSmoothness.rawValue) == nil { return 1.0 }
            return max(0.5, min(2.0, defaults.double(forKey: Key.rifeFlowSmoothness.rawValue)))
        }
        set {
            defaults.set(max(0.5, min(2.0, newValue)), forKey: Key.rifeFlowSmoothness.rawValue)
            notify(.rifeFlowSmoothness)
        }
    }

    var rifeLargeMotionAssist: Bool {
        get {
            if defaults.object(forKey: Key.rifeLargeMotionAssist.rawValue) == nil { return true }
            return defaults.bool(forKey: Key.rifeLargeMotionAssist.rawValue)
        }
        set {
            defaults.set(newValue, forKey: Key.rifeLargeMotionAssist.rawValue)
            notify(.rifeLargeMotionAssist)
        }
    }

    var rifePyramidStages: Int {
        get {
            let v = defaults.integer(forKey: Key.rifePyramidStages.rawValue)
            return [1, 2, 3].contains(v) ? v : 3
        }
        set {
            defaults.set([1, 2, 3].contains(newValue) ? newValue : 3, forKey: Key.rifePyramidStages.rawValue)
            notify(.rifePyramidStages)
        }
    }

    // 2. FLAVR 专属
    var flavrKernelMode: FLAVRKernelMode {
        get { enumValue(Key.flavrKernelMode, default: .hermite) }
        set { setEnum(Key.flavrKernelMode, newValue) }
    }

    var flavrBackend: FLAVRBackend {
        get { enumValue(Key.flavrBackend, default: .anePreferred) }
        set { setEnum(Key.flavrBackend, newValue) }
    }

    // 3. DistilDRBA 专属
    var drbaCadence: DRBACadence {
        get { enumValue(Key.drbaCadence, default: .medium) }
        set { setEnum(Key.drbaCadence, newValue) }
    }

    var drbaLineArtPreservation: Double {
        get {
            if defaults.object(forKey: Key.drbaLineArtPreservation.rawValue) == nil { return 0.85 }
            return max(0.0, min(1.0, defaults.double(forKey: Key.drbaLineArtPreservation.rawValue)))
        }
        set {
            defaults.set(max(0.0, min(1.0, newValue)), forKey: Key.drbaLineArtPreservation.rawValue)
            notify(.drbaLineArtPreservation)
        }
    }

    var drbaExaggeratedMotionGuard: Bool {
        get {
            if defaults.object(forKey: Key.drbaExaggeratedMotionGuard.rawValue) == nil { return true }
            return defaults.bool(forKey: Key.drbaExaggeratedMotionGuard.rawValue)
        }
        set {
            defaults.set(newValue, forKey: Key.drbaExaggeratedMotionGuard.rawValue)
            notify(.drbaExaggeratedMotionGuard)
        }
    }

    /// 反交错模式（解决 1080 50i/60i 隔行扫描拉丝，倍帧输出至 50/60 fps）。
    var deinterlaceMode: DeinterlaceMode {
        get { enumValue(Key.deinterlaceMode, default: .auto) }
        set { setEnum(Key.deinterlaceMode, newValue) }
    }

    var fake60FPSOptimization: Fake60OptimizationMode {
        get { enumValue(Key.fake60FPSOptimization, default: .auto) }
        set { setEnum(Key.fake60FPSOptimization, newValue) }
    }

    var captureLowLatencyMode: CaptureLowLatencyMode {
        get { enumValue(Key.captureLowLatencyMode, default: .balanced) }
        set { setEnum(Key.captureLowLatencyMode, newValue) }
    }

    /// 采集输入色彩范围。默认「自动」= 读采集卡上报。
    var captureColorRange: CaptureColorRange {
        get { enumValue(Key.captureColorRange, default: .auto) }
        set { setEnum(Key.captureColorRange, newValue) }
    }

    /// 采集输入色度矩阵。默认「自动」= 读采集卡上报。
    var captureColorMatrix: CaptureColorMatrix {
        get { enumValue(Key.captureColorMatrix, default: .auto) }
        set { setEnum(Key.captureColorMatrix, newValue) }
    }

    /// 重置所有 RIFE 补帧参数为推荐默认值
    func resetRIFEToDefaults() {
        rifeRateMode = .off
        rifeQualityMode = .stable
        rifeModel = .v426
        rifeResolution = .normal
        rifeWorkerCount = 8
        rifeTransitionDetection = true
        rifeSceneThreshold = 0.30
        rifeStaticFrameSkip = true
        rifeStaticThreshold = 0.02
        rifeScaleFactor = 1.0
        rifeCustomTargetFps = 60.0
        rifePrecision = .fp16
        rifeQueueDepth = 4

        // 专属参数重置
        rifeFlowSmoothness = 1.0
        rifeLargeMotionAssist = true
        rifePyramidStages = 3
        flavrKernelMode = .hermite
        flavrBackend = .anePreferred
        drbaCadence = .medium
        drbaLineArtPreservation = 0.85
        drbaExaggeratedMotionGuard = true
        deinterlaceMode = .auto
        fake60FPSOptimization = .auto
        captureLowLatencyMode = .balanced
    }

    // MARK: 其它档位

    var metalFX: MetalFXOption {
        get { enumValue(Key.metalFX, default: .off) }
        set { setEnum(Key.metalFX, newValue) }
    }

    var anime4k: Anime4KOption {
        get { enumValue(Key.anime4k, default: .off) }
        set { setEnum(Key.anime4k, newValue) }
    }

    var anime4kPresetID: Anime4KPresetID {
        get { enumValue(Key.anime4kPresetID, default: .p1080) }
        set { setEnum(Key.anime4kPresetID, newValue) }
    }

    var anime4kSharpness: Float {
        get {
            if defaults.object(forKey: Key.anime4kSharpness.rawValue) == nil { return 1.0 }
            return max(0.0, min(2.0, defaults.float(forKey: Key.anime4kSharpness.rawValue)))
        }
        set {
            let v = max(0.0, min(2.0, newValue))
            defaults.set(v, forKey: Key.anime4kSharpness.rawValue)
            notify(.anime4kSharpness)
        }
    }

    var anime4kDenoise: Float {
        get {
            if defaults.object(forKey: Key.anime4kDenoise.rawValue) == nil { return 0.5 }
            return max(0.0, min(1.0, defaults.float(forKey: Key.anime4kDenoise.rawValue)))
        }
        set {
            let v = max(0.0, min(1.0, newValue))
            defaults.set(v, forKey: Key.anime4kDenoise.rawValue)
            notify(.anime4kDenoise)
        }
    }

    var decodeMode: DecodeMode {
        get { enumValue(Key.decodeMode, default: .hardware) }
        set { setEnum(Key.decodeMode, newValue) }
    }

    /// 音量。`volumeValue` 在反射池里（原版把音量也持久化了），沿用。
    var volume: Float {
        get {
            if defaults.object(forKey: Key.volume.rawValue) == nil { return 1 }
            return max(0, min(1, defaults.float(forKey: Key.volume.rawValue)))
        }
        set {
            let v = max(0, min(1, newValue))
            defaults.set(v, forKey: Key.volume.rawValue)
            notify(.volume)
        }
    }

    // MARK: 最近打开

    /// 最近打开的文件路径（最新的在前）。
    ///
    /// 上限 10 是**推断**：文案表只有 `recent_open` / `no_recent_open` / `clear_recent_open`，
    /// 没给长度；反射池里也没有相关常量。取一个不会把菜单撑爆的值。
    static let recentLimit = 10

    var recentFiles: [URL] {
        get {
            let paths = defaults.stringArray(forKey: Key.recentFiles.rawValue) ?? []
            return paths.map { URL(fileURLWithPath: $0) }
        }
        set {
            let paths = newValue.map(\.path)
            defaults.set(Array(paths.prefix(Self.recentLimit)), forKey: Key.recentFiles.rawValue)
            notify(.recentFiles)
        }
    }

    /// 把一个文件提到「最近打开」最前面。重复的会先删掉再加，所以不会出现两条。
    /// 不存在的文件直接不记 —— 菜单里挂一条点不动的死链比不记更糟。
    func noteRecent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var list = recentFiles.filter { $0.path != url.path }
        list.insert(url, at: 0)
        recentFiles = list
    }

    func clearRecent() { recentFiles = [] }

    // MARK: - 内部

    private func enumValue<T: RawRepresentable>(_ key: Key, default fallback: T) -> T
    where T.RawValue == String {
        guard let raw = defaults.string(forKey: key.rawValue),
              let v = T(rawValue: raw) else { return fallback }
        return v
    }

    private func setEnum<T: RawRepresentable>(_ key: Key, _ value: T) where T.RawValue == String {
        defaults.set(value.rawValue, forKey: key.rawValue)
        notify(key)
    }

    private func notify(_ key: Key) {
        NotificationCenter.default.post(name: .playbackSettingsDidChange,
                                        object: self,
                                        userInfo: ["key": key])
    }
}
