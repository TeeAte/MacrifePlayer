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
//    比如「补帧 2X」：模型菜单里要勾上 RIFE 4.26，控制条要显示「补帧 ON」，
//    状态胶囊要显示「RIFE 2X」。任一处改动都必须让另两处立刻跟上，
//    所以统一走一条通知，由各视图自己重读 —— 而不是让改动方去挨个通知。

import Foundation

// MARK: - 变更通知

extension Notification.Name {
    /// 任一项设置发生变化。`userInfo["key"]` 是变化的 `PlaybackSettings.Key`。
    ///
    /// 监听方一般不需要看 key（重读一遍很便宜），但日志与调试需要。
    static let playbackSettingsDidChange = Notification.Name("MPPlaybackSettingsDidChange")
    static let playbackInputProfileDidChange = Notification.Name("MPPlaybackInputProfileDidChange")
}

// MARK: - 补帧模式（控制条按钮上的那条）

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

/// 手动指定主机实际帧率；沿用旧设置键以保留已有偏好。
enum Fake60OptimizationMode: String, CaseIterable {
    case off
    case on

    var title: String {
        switch self {
        case .on:   return "主机 30FPS（60FPS 采集 · AI 补到 60FPS）"
        case .off:  return "原始输入（不抽帧）"
        }
    }
}

/// 采集卡/实时输入超低延迟模式
enum CaptureLowLatencyMode: String, CaseIterable {
    case extreme   // 极限电竞：最新输入，最多 2 对在途，保留 AI 补帧
    case balanced  // 平衡抗抖动：2 帧输入，最多 3 对在途
    case off       // 兼容旧偏好，实时采集统一使用平衡策略

    static let allCases: [CaptureLowLatencyMode] = [.extreme, .balanced]

    var title: String {
        switch self {
        case .extreme:  return "极限电竞 (优先跟手 · 保留 AI 补帧)"
        case .balanced: return "平衡抗抖动 (少量缓冲 · 保留 AI 补帧)"
        case .off:      return "平衡抗抖动 (兼容旧设置)"
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

/// HDR 转 SDR 色调映射模式（对标 mpv / libplacebo / ITU-R BT.2446）
enum HDRToneMappingMode: String, CaseIterable {
    case auto
    case aces
    case hable
    case bt2446a
    case reinhard
    case off

    var title: String {
        switch self {
        case .auto:     return "自动 (推荐 · ACES 电影胶片)"
        case .aces:     return "ACES Filmic (胶片色彩 · 高动态范围)"
        case .hable:    return "Hable (神秘海域2 · 柔和高光压缩)"
        case .bt2446a:  return "ITU-R BT.2446a (广电标准 · 亮度保真)"
        case .reinhard: return "Reinhard (经典全局摄影)"
        case .off:      return "关闭 (原生 HDR 直通)"
        }
    }

    var operatorCode: UInt32 {
        switch self {
        case .auto, .aces: return 0
        case .hable:       return 1
        case .bt2446a:     return 2
        case .reinhard:    return 3
        case .off:         return 0
        }
    }
}

/// 补帧后端与延迟策略独立。Apple管理其系统模型，RIFE可选择权重版本。
enum InterpolationBackend: String, CaseIterable {
    case rifeCoreML
    case appleVideoToolbox
    case metalFX
    case rifeMetalFast

    var title: String {
        switch self {
        case .rifeCoreML: return "RIFE（Core ML）"
        case .appleVideoToolbox: return "Apple 系统补帧（VideoToolbox）"
        case .metalFX: return "MetalFX 补帧（实验性）"
        case .rifeMetalFast: return "RifeMetal Fast（Metal · RIFE 4.25）"
        }
    }
    var shortTitle: String {
        switch self {
        case .rifeCoreML: return "RIFE"
        case .appleVideoToolbox: return "Apple"
        case .metalFX: return "MetalFX"
        case .rifeMetalFast: return "RifeMetal Fast"
        }
    }
}

enum FlowInferenceResolution: String, CaseIterable {
    case p576, p720, p1080, p1440
    var height: Int {
        switch self {
        case .p576: return 576
        case .p720: return 720
        case .p1080: return 1080
        case .p1440: return 1440
        }
    }
    var title: String { "\(height)p" }
}

/// 当前支持的RIFE权重；后端不出现在模型列表中。
enum RIFEModelChoice: String, CaseIterable {
    case v426
    case heavy426

    var title: String {
        switch self {
        case .v426: return L10n.t("rife_model_426_high_quality")
        case .heavy426: return L10n.t("rife_model_426_heavy")
        }
    }

    var menuTitle: String {
        switch self {
        case .v426: return "RIFE v4.26 (新一代高画质 · 通用物理光流)"
        case .heavy426: return "RIFE v4.26 Heavy (大位移重度光流 · 动作大片)"
        }
    }

    var groupTitle: String {
        switch self {
        case .v426: return L10n.t("rife_full_mode")
        case .heavy426: return L10n.t("rife_heavy_model")
        }
    }

    var modelFamilyName: String {
        "RIFE"
    }

    var availableComputePrecisions: [RIFEComputePrecision] { [.fp16] }

    func compiledVariant(resolution: FlowInferenceResolution) -> String? {
        switch (self, resolution) {
        case (.v426, .p720): return "rife_426_fp16_blocks_extended"
        case (.v426, _): return "rife_426_fp16_\(resolution.height)p_blocks"
        case (.heavy426, .p1440): return nil
        case (.heavy426, _): return "rife_426_heavy_fp16_\(resolution.height)p_blocks"
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

/// Video-file preferences retain the existing keys. Capture gets a one-time
/// copy and its own namespace; subsequent edits cannot bleed between sources.
private final class ProfiledPlaybackDefaults {
    private let store: UserDefaults
    private let lock = NSLock()
    private var kind: PlaybackInputKind
    var inputKind: PlaybackInputKind { lock.lock(); defer { lock.unlock() }; return kind }

    init(_ store: UserDefaults, inputKind: PlaybackInputKind) {
        self.store = store; self.kind = inputKind
        if inputKind == .captureCard { initializeCaptureProfile() }
    }

    static func isInterpolationKey(_ key: String) -> Bool {
        key.hasPrefix("macrife.rife") || key.hasPrefix("macrife.interpolation")
            || key == "macrife.hdrToneMapping" || key == "macrife.deinterlaceMode"
    }

    private func captureKey(_ key: String) -> String { "macrife.capture." + key.dropFirst("macrife.".count) }
    private static let migrationLock = NSLock()
    private func initializeCaptureProfile() {
        Self.migrationLock.lock(); defer { Self.migrationLock.unlock() }
        let marker = "macrife.capture.interpolationProfileInitialized.v2"
        guard !store.bool(forKey: marker) else { return }
        let keys = Set(PlaybackSettings.Key.allCases.map(\.rawValue)
            + store.dictionaryRepresentation().keys.filter { Self.isInterpolationKey($0) })
        for key in keys where Self.isInterpolationKey(key) {
            if let value = store.object(forKey: key), store.object(forKey: captureKey(key)) == nil {
                store.set(value, forKey: captureKey(key))
            }
        }
        store.set(true, forKey: marker)
    }

    func selectInput(_ kind: PlaybackInputKind) {
        if kind == .captureCard { initializeCaptureProfile() }
        lock.lock(); self.kind = kind; lock.unlock()
    }
    private func key(_ key: String) -> String {
        inputKind == .captureCard && Self.isInterpolationKey(key) ? captureKey(key) : key
    }
    func object(forKey k: String) -> Any? { store.object(forKey: key(k)) }
    func string(forKey k: String) -> String? { store.string(forKey: key(k)) }
    func stringArray(forKey k: String) -> [String]? { store.stringArray(forKey: key(k)) }
    func bool(forKey k: String) -> Bool { store.bool(forKey: key(k)) }
    func integer(forKey k: String) -> Int { store.integer(forKey: key(k)) }
    func double(forKey k: String) -> Double { store.double(forKey: key(k)) }
    func float(forKey k: String) -> Float { store.float(forKey: key(k)) }
    func set(_ value: Any?, forKey k: String) { store.set(value, forKey: key(k)) }
    func removeObject(forKey k: String) { store.removeObject(forKey: key(k)) }
}

final class PlaybackSettings {

    static let shared = PlaybackSettings()
    private static let fileSettings = PlaybackSettings(inputKind: .videoFile)
    private static let captureSettings = PlaybackSettings(inputKind: .captureCard)

    static func forInput(_ kind: PlaybackInputKind) -> PlaybackSettings {
        kind == .videoFile ? fileSettings : captureSettings
    }

    var inputKind: PlaybackInputKind { defaults.inputKind }
    private let fixedInputKind: PlaybackInputKind?

    /// UI follows the opened source; processing instances remain bound to
    /// their own profile, including asynchronous model initialization.
    func selectInput(_ kind: PlaybackInputKind) {
        guard fixedInputKind == nil, inputKind != kind else { return }
        defaults.selectInput(kind)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .playbackInputProfileDidChange, object: self)
        }
    }

    /// UserDefaults 的 key，前缀统一 `macrife.`。
    enum Key: String, CaseIterable {
        case rifeRateMode = "macrife.rifeRateMode"
        case rifeQualityMode = "macrife.rifeQualityMode"
        case rifeModel = "macrife.rifeModel"
        case interpolationBackend = "macrife.interpolationBackend"
        case interpolationFlowResolution = "macrife.interpolationFlowResolution"
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
        case playbackProgress = "macrife.playbackProgress"

        // RIFE 专属定制
        case rifeFlowSmoothness = "macrife.rifeFlowSmoothness"
        case rifeLargeMotionAssist = "macrife.rifeLargeMotionAssist"
        case rifePyramidStages = "macrife.rifePyramidStages"

        // 反交错设置 (MTS / 1080 50i/60i 隔行视频双场转 60 帧)
        case deinterlaceMode = "macrife.deinterlaceMode"

        // 采集卡输入延迟与手动主机30FPS模式
        case fake60FPSOptimization = "macrife.fake60FPSOptimization"
        case captureLowLatencyMode = "macrife.captureLowLatencyMode"

        // 采集色彩（对标 OBS 的 Color Range / Color Space）
        case captureColorRange = "macrife.captureColorRange"
        case captureColorMatrix = "macrife.captureColorMatrix"

        // HDR 色彩管理与色调映射 (HDR to SDR Tone Mapping)
        case hdrToneMapping = "macrife.hdrToneMapping"

        /// 这项设置是否影响**管线本身**（解码器 / 推理链 / 渲染链）。
        var affectsPipeline: Bool {
            switch self {
            case .rifeQualityMode, .rifeModel, .rifeResolution,
                 .interpolationBackend, .interpolationFlowResolution,
                 .rifeWorkerCount, .rifeTransitionDetection, .rifeSceneThreshold,
                 .rifeStaticFrameSkip, .rifeStaticThreshold, .rifeScaleFactor,
                 .rifeCustomTargetFps, .rifePrecision, .rifeQueueDepth,
                 .rifeFlowSmoothness, .rifeLargeMotionAssist, .rifePyramidStages,
                 .deinterlaceMode, .fake60FPSOptimization, .captureLowLatencyMode,
                 .metalFX, .anime4k, .anime4kPresetID, .anime4kSharpness, .anime4kDenoise, .decodeMode:
                return true
            case .rifeRateMode, .volume, .recentFiles, .playbackProgress,
                 // 色彩范围 / 矩阵 / HDR色调映射每帧在渲染前读取即可生效，不需要重建管线
                 .captureColorRange, .captureColorMatrix, .hdrToneMapping:
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
            case .interpolationBackend:
                return MPText.t("补帧后端", "Interpolation backend")
            case .interpolationFlowResolution:
                return MPText.t("光流推理分辨率", "Flow inference resolution")
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
            case .playbackProgress:
                return MPText.t("播放进度", "Playback progress")
            case .rifeFlowSmoothness:
                return MPText.t("光流平滑度", "Flow smoothness")
            case .rifeLargeMotionAssist:
                return MPText.t("大运动补偿", "Large motion assist")
            case .rifePyramidStages:
                return MPText.t("金字塔阶段", "Pyramid stages")
            case .deinterlaceMode:
                return MPText.t("反交错模式", "Deinterlace mode")
            case .fake60FPSOptimization:
                return MPText.t("主机 30FPS 模式", "Console 30 FPS mode")
            case .captureLowLatencyMode:
                return MPText.t("采集卡低延迟", "Capture low latency")
            case .captureColorRange:
                return MPText.t("采集色彩范围", "Capture color range")
            case .captureColorMatrix:
                return MPText.t("采集色彩矩阵", "Capture color matrix")
            case .hdrToneMapping:
                return MPText.t("HDR 色调映射", "HDR tone mapping")
            }
        }
    }

    private let defaults: ProfiledPlaybackDefaults

    init(defaults: UserDefaults = .standard, inputKind: PlaybackInputKind? = nil) {
        fixedInputKind = inputKind
        self.defaults = ProfiledPlaybackDefaults(defaults, inputKind: inputKind ?? .videoFile)
        // 保留旧Apple选择，迁移到独立后端；RIFE权重作为独立的回退配置。
        if defaults.string(forKey: Key.rifeModel.rawValue) == "appleLowLatency" {
            if defaults.object(forKey: Key.interpolationBackend.rawValue) == nil {
                defaults.set(InterpolationBackend.appleVideoToolbox.rawValue, forKey: Key.interpolationBackend.rawValue)
            }
            defaults.set(RIFEModelChoice.v426.rawValue, forKey: Key.rifeModel.rawValue)
        }
        // 已移除模型的旧偏好迁移到默认模型，避免重启后仍保留失效选择。
        if let raw = defaults.string(forKey: Key.rifeModel.rawValue),
           RIFEModelChoice(rawValue: raw) == nil {
            defaults.set(RIFEModelChoice.v426.rawValue, forKey: Key.rifeModel.rawValue)
        }
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

    var interpolationBackend: InterpolationBackend {
        get {
            if defaults.object(forKey: Key.interpolationBackend.rawValue) == nil,
               defaults.string(forKey: Key.rifeModel.rawValue) == "appleLowLatency" { return .appleVideoToolbox }
            return enumValue(Key.interpolationBackend, default: .rifeCoreML)
        }
        set { setEnum(Key.interpolationBackend, newValue) }
    }

    private func flowProfileKey(backend: InterpolationBackend) -> String {
        let profile: String
        switch backend {
        case .rifeCoreML: profile = "rife.\(rifeModel.rawValue)"
        case .appleVideoToolbox: profile = "apple"
        case .metalFX: profile = "metalfx"
        case .rifeMetalFast: profile = "rifemetal.fast"
        }
        return "macrife.interpolation.\(profile).flowResolution"
    }

    func flowResolution(for backend: InterpolationBackend) -> FlowInferenceResolution {
        if let raw = defaults.string(forKey: flowProfileKey(backend: backend)),
           let value = FlowInferenceResolution(rawValue: raw),
           !(backend == .rifeCoreML && rifeModel == .heavy426 && value == .p1440) { return value }
        // Preserve the previous working inference sizes; old UI scale controls
        // did not select CoreML variants and are not treated as measured settings.
        if backend == .rifeMetalFast { return .p1080 }
        return backend == .rifeCoreML ? .p576 : .p720
    }

    var interpolationFlowResolution: FlowInferenceResolution {
        get { flowResolution(for: interpolationBackend) }
        set {
            guard availableFlowResolutions.contains(newValue) else { return }
            defaults.set(newValue.rawValue, forKey: flowProfileKey(backend: interpolationBackend))
            notify(.interpolationFlowResolution)
        }
    }

    var availableFlowResolutions: [FlowInferenceResolution] {
        if interpolationBackend == .rifeCoreML, rifeModel == .heavy426 { return [.p576, .p720, .p1080] }
        return FlowInferenceResolution.allCases
    }

    /// Current compiled RIFE packages have FP16 tensor IO only. VideoToolbox
    /// owns its internal precision. Hide numeric selection until a backend
    /// actually offers multiple supported precisions.
    var availableComputePrecisions: [RIFEComputePrecision] {
        interpolationBackend == .rifeCoreML ? rifeModel.availableComputePrecisions : []
    }

    var computePrecisionDescription: String {
        if interpolationBackend == .rifeMetalFast { return "FP16（RifeMetal Fast 固定精度）" }
        return interpolationBackend == .rifeCoreML ? "FP16 模型（当前模型包）" : "系统管理（不公开 FP16 / FP32 控制）"
    }

    var rifeResolution: RIFEModelResolution {
        get {
            switch flowResolution(for: .rifeCoreML) {
            case .p576: return .sweet
            case .p720: return .normal
            case .p1080: return .quality
            case .p1440: return .top
            }
        }
        set {
            let resolution: FlowInferenceResolution
            switch newValue {
            case .sweet: resolution = .p576
            case .normal: resolution = .p720
            case .quality: resolution = .p1080
            case .top: resolution = .p1440
            }
            guard rifeModel.compiledVariant(resolution: resolution) != nil else { return }
            defaults.set(resolution.rawValue, forKey: flowProfileKey(backend: .rifeCoreML))
            defaults.set(newValue.rawValue, forKey: Key.rifeResolution.rawValue)
            notify(.rifeResolution)
        }
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

    /// Processing uses the source's fixed profile, including custom targets.
    func interpolationTargetFrameRate(source: Double) -> Double {
        guard source > 0 else { return 0 }
        switch rifeRateMode {
        case .off: return source
        case .fps60: return 60
        case .fps120: return 120
        case .customFps: return rifeCustomTargetFps
        default: return source * Double(rifeRateMode.multiplier ?? 1)
        }
    }

    /// 计算精度 (FP16 / FP32)。
    var rifePrecision: RIFEComputePrecision {
        get {
            let key = "macrife.interpolation.rife.\(rifeModel.rawValue).precision"
            guard let stored = defaults.string(forKey: key).flatMap(RIFEComputePrecision.init(rawValue:)),
                  rifeModel.availableComputePrecisions.contains(stored) else { return .fp16 }
            return stored
        }
        set {
            guard rifeModel.availableComputePrecisions.contains(newValue) else { return }
            defaults.set(newValue.rawValue, forKey: "macrife.interpolation.rife.\(rifeModel.rawValue).precision")
            notify(.rifePrecision)
        }
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

    /// 反交错模式（解决 1080 50i/60i 隔行扫描拉丝，倍帧输出至 50/60 fps）。
    var deinterlaceMode: DeinterlaceMode {
        get { enumValue(Key.deinterlaceMode, default: .auto) }
        set { setEnum(Key.deinterlaceMode, newValue) }
    }

    var fake60FPSOptimization: Fake60OptimizationMode {
        get { enumValue(Key.fake60FPSOptimization, default: .off) }
        set { setEnum(Key.fake60FPSOptimization, newValue) }
    }

    var captureLowLatencyMode: CaptureLowLatencyMode {
        get {
            let mode: CaptureLowLatencyMode = enumValue(Key.captureLowLatencyMode, default: .balanced)
            return mode == .off ? .balanced : mode
        }
        set { setEnum(Key.captureLowLatencyMode, newValue == .off ? .balanced : newValue) }
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

    /// HDR 转 SDR 色调映射模式（默认自动开启 ACES Filmic）
    var hdrToneMapping: HDRToneMappingMode {
        get { enumValue(Key.hdrToneMapping, default: .auto) }
        set { setEnum(Key.hdrToneMapping, newValue) }
    }

    /// 重置所有 RIFE 补帧参数为推荐默认值
    func resetRIFEToDefaults() {
        rifeRateMode = .off
        rifeQualityMode = .stable
        rifeModel = .v426
        interpolationBackend = .rifeCoreML
        for model in RIFEModelChoice.allCases {
            defaults.removeObject(forKey: "macrife.interpolation.rife.\(model.rawValue).flowResolution")
            defaults.removeObject(forKey: "macrife.interpolation.rife.\(model.rawValue).precision")
        }
        defaults.removeObject(forKey: "macrife.interpolation.apple.flowResolution")
        defaults.removeObject(forKey: "macrife.interpolation.metalfx.flowResolution")
        defaults.removeObject(forKey: "macrife.interpolation.rifemetal.fast.flowResolution")
        rifeResolution = .sweet
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
        hdrToneMapping = .auto
        if inputKind == .videoFile {
            deinterlaceMode = .auto
        } else {
            fake60FPSOptimization = .off
            captureLowLatencyMode = .balanced
        }
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

    // MARK: 播放进度 (Playback Progress)

    func progress(for name: String) -> Double? {
        PlaybackProgressManager.shared.progress(for: name)
    }

    func saveProgress(for name: String, time: Double, duration: Double) {
        PlaybackProgressManager.shared.saveProgress(for: name, time: time, duration: duration)
    }

    func clearProgress(for name: String) {
        PlaybackProgressManager.shared.clearProgress(for: name)
    }

    func clearAllProgress() {
        PlaybackProgressManager.shared.clearAllProgress()
    }

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

// MARK: - 影片播放进度管理器 (Playback Progress Manager)

/// 记住影片播放进度管理器。
///
/// 存储位置探讨（针对 macOS 播放器）：
/// 1. UserDefaults（~/Library/Preferences/<bundle-id>.plist）：
///    - 本工程当前做法：轻量、无锁争用、系统统一通过 cfprefsd 异步写盘，重启后保留。
///    - 采用字典结构 `[文件名: [字段: 值]]`，带上时间戳（updatedAt）。
///    - 加容量上限保护（LRU 淘汰旧记录，最多保留 1000 部影片），保证永久不超几十 KB。
/// 2. Application Support 目录（JSON 文件）：
///    - 适合海量元数据；但纯记录「影片名 -> 进度秒数」偏重，增加目录与原子写文件逻辑。
/// 3. Caches 目录：
///    - 不推荐，系统或清理工具在磁盘紧缺时可能无预警清空。
/// 4. 文件系统扩展属性（xattr）：
///    - 在只读介质、NAS、网络共享盘或只读卷上会写入失败。
///
/// 综上：基于 UserDefaults + LRU 淘汰是 macOS 视频播放器实现该特性的最佳实践。
final class PlaybackProgressManager {

    static let shared = PlaybackProgressManager()

    /// 最多保留多少部影片进度（防膨胀 LRU 淘汰）
    static let maxHistoryLimit = 1000

    /// 最小记录阈值（少于 5 秒视为刚打开，不记或从头开始）
    static let minimumRecordThreshold: Double = 5.0

    /// 片尾完成阈值（距离片尾不足 10 秒或播过 95%，视为看完，重置进度）
    static let completedMargin: Double = 10.0
    static let completedRatio: Double = 0.95

    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 获取某影片的进度（以文件名/lastPathComponent 为 key）
    func progress(for name: String) -> Double? {
        guard !name.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }

        guard let all = defaults.dictionary(forKey: PlaybackSettings.Key.playbackProgress.rawValue) as? [String: [String: Any]],
              let dict = all[name] else {
            return nil
        }

        let time = (dict["time"] as? NSNumber)?.doubleValue ?? (dict["time"] as? Double) ?? 0
        let duration = (dict["duration"] as? NSNumber)?.doubleValue ?? (dict["duration"] as? Double) ?? 0

        // 如果当时记录点已经接近片尾，或不足阈值，则视为无需恢复
        if time < Self.minimumRecordThreshold { return nil }
        if duration > 0 {
            if time >= (duration - Self.completedMargin) || (time / duration) >= Self.completedRatio {
                return nil
            }
        }
        return time
    }

    /// 保存播放进度（如果快播完了或者刚开始，会自动清除）
    func saveProgress(for name: String, time: Double, duration: Double) {
        guard !name.isEmpty, time.isFinite, time >= 0 else { return }

        lock.lock()
        defer { lock.unlock() }

        var all = defaults.dictionary(forKey: PlaybackSettings.Key.playbackProgress.rawValue) as? [String: [String: Any]] ?? [:]

        // 1. 如果进度太短（< 5s），不记录；如果已存在则清除
        if time < Self.minimumRecordThreshold {
            if all.removeValue(forKey: name) != nil {
                defaults.set(all, forKey: PlaybackSettings.Key.playbackProgress.rawValue)
            }
            return
        }

        // 2. 如果影片已经基本看完了（距离结尾 < 10s 或超过 95%），清除记录
        if duration > 0 && (time >= (duration - Self.completedMargin) || (time / duration) >= Self.completedRatio) {
            if all.removeValue(forKey: name) != nil {
                defaults.set(all, forKey: PlaybackSettings.Key.playbackProgress.rawValue)
            }
            return
        }

        // 3. 正常写入
        let record: [String: Any] = [
            "time": time,
            "duration": duration,
            "updatedAt": Date().timeIntervalSinceReferenceDate
        ]
        all[name] = record

        // 4. LRU 容量保护：超过上限时淘汰最旧的记录
        if all.count > Self.maxHistoryLimit {
            let sortedKeys = all.keys.sorted { k1, k2 in
                let t1 = (all[k1]?["updatedAt"] as? NSNumber)?.doubleValue ?? (all[k1]?["updatedAt"] as? Double) ?? 0
                let t2 = (all[k2]?["updatedAt"] as? NSNumber)?.doubleValue ?? (all[k2]?["updatedAt"] as? Double) ?? 0
                return t1 > t2
            }
            let keepKeys = Set(sortedKeys.prefix(Self.maxHistoryLimit))
            all = all.filter { keepKeys.contains($0.key) }
        }

        defaults.set(all, forKey: PlaybackSettings.Key.playbackProgress.rawValue)
    }

    /// 清除某部影片的进度
    func clearProgress(for name: String) {
        guard !name.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var all = defaults.dictionary(forKey: PlaybackSettings.Key.playbackProgress.rawValue) as? [String: [String: Any]] ?? [:]
        if all.removeValue(forKey: name) != nil {
            defaults.set(all, forKey: PlaybackSettings.Key.playbackProgress.rawValue)
        }
    }

    /// 清空所有影片进度
    func clearAllProgress() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: PlaybackSettings.Key.playbackProgress.rawValue)
    }

    /// 把秒格式化成 mm:ss（超过一小时给 h:mm:ss）
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}
