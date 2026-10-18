// CaptureDevicePanelController.swift
// MacrifePlayer - 采集卡输入选择与详细配置面板

import Foundation
import AppKit
import AVFoundation

// MARK: - FourCC 文本化

/// 把像素格式的 FourCharCode 转成可读文本（dev 转储与日志共用）。
enum CaptureFormatFourCC {
    static func text(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}

// MARK: - 设备真实规格模型

/// 从 `AVCaptureDevice.formats` 实测枚举出来的一条可选规格。
///
/// 与旧版「预设 1080p / 4K 列表」的本质区别：这里每一项都是采集卡自己上报的能力，
/// 设备不支持的规格根本不会出现在列表里。
/// 旧版哪怕设备最高只有 1080p，也会列出「4K @ 60 FPS」，用户选了之后
/// `findBestFormat` 匹配不到就静默回落到 activeFormat —— 看起来选了，实际等于没选。
private struct CaptureFormatOption {
    let format: AVCaptureDevice.Format
    let width: Int
    let height: Int
    let subType: FourCharCode
    /// 该规格支持的帧率档位（降序），**保留原始 AVFrameRateRange 对象**。
    ///
    /// 为什么必须留原始对象：锁定帧率要用 range 自带的精确 CMTime。
    /// UVC 设备上报的 60fps 实际是 `1000000 / 60000240`，不是 `1 / 60`——
    /// 自己按 1/N 构造会让 CoreMediaIO 抛 NSInvalidArgumentException（Swift 抓不到 → SIGABRT）。
    /// 实测：用 1/N 设置 60 和 30 两档必崩；用 range 自带时长则 5 档全部设置成功。
    let ranges: [AVFrameRateRange]

    var frameRates: [Double] { ranges.map { $0.maxFrameRate } }
    var maxFPS: Double { ranges.first?.maxFrameRate ?? 30.0 }

    var pixelFormatName: String {
        switch subType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "NV12"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  return "NV12(f)"
        case kCVPixelFormatType_422YpCbCr8_yuvs:              return "YUY2"
        case kCVPixelFormatType_422YpCbCr8:                   return "UYVY"
        case kCVPixelFormatType_32BGRA:                       return "BGRA"
        case kCVPixelFormatType_24RGB:                        return "RGB"
        case kCVPixelFormatType_420YpCbCr8Planar:             return "I420"
        default: return Self.fourCC(subType)
        }
    }

    /// 像素格式是否走播放器最快路径（NV12 双平面，Metal 直接双纹理上传，零转换）。
    var isNativeNV12: Bool {
        subType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || subType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    /// 当前渲染器能否直接吃下这个像素格式。
    ///
    /// 两类都支持：
    ///   · 双平面 NV12 / P010 —— Y 一张 r8/r16 纹理，CbCr 一张 rg8/rg16 纹理
    ///   · 打包 4:2:2 的 **YUY2（'yuvs'）** —— 整块缓冲一张 rg8 纹理，专用片段函数解包
    ///     （video_fragment_yuy2；已用合成缓冲离屏验证映射与色彩数学）
    ///
    /// 注意 UYVY（'2vuy'）**不**在这里：它的字节序与 YUY2 相反
    ///（UYVY 是 [U][Y0][V][Y1]，YUY2 是 [Y0][U][Y1][V]），
    /// 解包下标完全不同，共用同一个着色器会得到错位的画面。
    /// 本机采集卡只提供 YUY2，UYVY 尚无实测样本 —— 没验证过的路径不放出来。
    static func isRenderablePixelFormat(_ sub: OSType) -> Bool {
        switch sub {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr8_yuvs:
            return true
        default:
            return false
        }
    }

    /// 下拉列表里的紧凑标题。
    ///
    /// 不把 5 个帧率档位全铺出来（`1920×1080 · 60/50/30/20/10 FPS · NV12`）：
    /// NSPopUpButton 的 intrinsic 宽度会把整个面板链条撑宽（实测 560 → 609pt，右侧被裁）。
    /// 完整档位放在下面的「实际输出」回显行里，那里能换行。
    /// 分辨率下拉里的标题（帧率由旁边那个下拉单独选，这里不重复）。
    var title: String {
        "\(width)×\(height) · \(pixelFormatName)"
    }

    /// 回显用的完整描述。
    var detailText: String {
        let quality: String
        switch subType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            quality = "原生双平面 NV12（零转换直出）"
        case kCVPixelFormatType_422YpCbCr8_yuvs:
            quality = "原生 4:2:2（色度不横向减半 · 彩色细节更实；运行时转 NV12 后可补帧）"
        default:
            quality = "需转码"
        }
        let all = frameRates.map { Self.fmt($0) }.joined(separator: "/")
        return "\(width)×\(height) · \(pixelFormatName) · \(quality) · 帧率可选 \(all)"
    }

    /// 该规格下第 `index` 档帧率对应的**精确帧时长**（直接喂给 activeVideoMin/MaxFrameDuration）。
    func frameDuration(at index: Int) -> CMTime? {
        guard index >= 0, index < ranges.count else { return nil }
        return ranges[index].minFrameDuration
    }

    static func fmt(_ v: Double) -> String {
        abs(v - v.rounded()) < 0.05 ? String(Int(v.rounded())) : String(format: "%.2f", v)
    }

    static func fourCC(_ code: FourCharCode) -> String { CaptureFormatFourCC.text(code) }
}

final class CaptureDevicePanelController: NSWindowController {

    static let shared = CaptureDevicePanelController()

    /// 回调。`frameDuration` 是要锁定的精确帧时长，来自用户选中的那个 `AVFrameRateRange`；
    /// 为 nil 表示不锁、沿用设备当前值。
    var onStartCapture: ((_ videoDevice: AVCaptureDevice, _ audioDevice: AVCaptureDevice?,
                          _ format: AVCaptureDevice.Format?, _ fps: Double,
                          _ frameDuration: CMTime?) -> Void)?

    // MARK: - 内部状态
    private var videoDevices: [AVCaptureDevice] = []
    private var audioDevices: [AVCaptureDevice] = []
    /// 与 formatPopup 的条目一一对应的真实规格（索引 0 是「设备当前默认」占位）。
    private var formatOptions: [CaptureFormatOption] = []

    // MARK: - UI 控件
    private let videoDevicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "刷新", target: nil, action: nil)
    private let deviceStatusLabel = NSTextField(labelWithString: "🟢 设备就绪")

    /// 分辨率 + 像素格式（帧率不在这里选）
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 帧率档位，随上面选中的分辨率联动重建
    private let fpsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 选中规格后如实回显「实际会输出什么」，避免再出现「选了 4K 其实只有 1080p」。
    private let formatDetailLabel = NSTextField(labelWithString: "—")
    private let audioDevicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 采集卡的硬件身份（厂商 / 型号 / 总线 ID），用于确认选中的确实是要用的那张卡。
    private let deviceInfoLabel = NSTextField(labelWithString: "—")
    /// 「自动匹配」实际匹配到的音频设备（旧版用名称包含匹配，实测会失配，这里如实回显）。
    private let audioMatchLabel = NSTextField(labelWithString: "—")

    private let latencyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fake60Popup = NSPopUpButton(frame: .zero, pullsDown: false)
    /// 色彩范围 / 矩阵（对标 OBS 的 Color Range / Color Space）。
    /// 自动档读采集卡上报值；手动档用于驱动上报与实际数据不一致时纠偏。
    private let colorRangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorMatrixPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private let startButton = NSButton(title: "开始采集 / 播放", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    // MARK: - 初始化

    private init() {
        // 560×880：内容实测 863pt 高（导出 PNG 量出来的，不是估的）。
        // 卡片数量涨到 6 张（新增「采集色彩」）后必须同步加高，
        // 否则底部「开始采集 / 取消」会被裁在窗口外 —— 之前 720pt 那次就是这样被发现的。
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 880),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "打开采集卡设备 (Capture Device)"
        panel.isFloatingPanel = true
        panel.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
        panel.center()

        super.init(window: panel)
        buildUI()
        reloadDevices()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 呈现与交互

    func show(parentWindow: NSWindow? = nil,
              onStart: ((_ videoDevice: AVCaptureDevice, _ audioDevice: AVCaptureDevice?,
                         _ format: AVCaptureDevice.Format?, _ fps: Double,
                         _ frameDuration: CMTime?) -> Void)? = nil) {
        self.onStartCapture = onStart
        reloadDevices()
        syncSettingsToUI()

        guard let window = self.window else { return }
        if let parent = parentWindow {
            window.center()
        }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func `open`(_ sender: Any?) {
        show()
    }

    // MARK: - UI 构建

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).cgColor

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            rootStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18)
        ])

        // 顶部标题
        let headerBox = NSStackView()
        headerBox.orientation = .horizontal
        headerBox.spacing = 10
        headerBox.alignment = .centerY

        let iconLabel = NSTextField(labelWithString: "🎮")
        iconLabel.font = .systemFont(ofSize: 24)

        let titleVStack = NSStackView()
        titleVStack.orientation = .vertical
        titleVStack.alignment = .leading
        titleVStack.spacing = 2

        let titleLabel = NSTextField(labelWithString: "视频采集卡与主机信号输入")
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white

        let subLabel = NSTextField(labelWithString: "检测 HDMI/USB 采集卡输入，配置输入延迟与 60Hz 假 60 帧智能重构")
        subLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = NSColor(white: 0.65, alpha: 1.0)

        titleVStack.addArrangedSubview(titleLabel)
        titleVStack.addArrangedSubview(subLabel)
        makeWrappingLabel(subLabel, in: titleVStack)

        headerBox.addArrangedSubview(iconLabel)
        headerBox.addArrangedSubview(titleVStack)
        rootStack.addArrangedSubview(headerBox)
        headerBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 1. 卡片：视频输入设备
        let videoCard = makeCardView(title: "1. 视频输入设备 (Video Device)")
        let videoStack = NSStackView()
        videoStack.orientation = .vertical
        videoStack.alignment = .leading
        videoStack.spacing = 8

        let devRow = NSStackView()
        devRow.orientation = .horizontal
        devRow.spacing = 8
        videoDevicePopup.target = self
        videoDevicePopup.action = #selector(onVideoDeviceChanged(_:))
        videoDevicePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        videoDevicePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        refreshButton.target = self
        refreshButton.action = #selector(onRefreshClicked(_:))
        refreshButton.bezelStyle = .rounded

        devRow.addArrangedSubview(videoDevicePopup)
        devRow.addArrangedSubview(refreshButton)

        deviceStatusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        deviceStatusLabel.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.50, alpha: 1.0)

        videoStack.addArrangedSubview(devRow)
        videoStack.addArrangedSubview(deviceStatusLabel)

        deviceInfoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        deviceInfoLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        videoStack.addArrangedSubview(deviceInfoLabel)
        makeWrappingLabel(deviceInfoLabel, in: videoStack)

        devRow.widthAnchor.constraint(equalTo: videoStack.widthAnchor).isActive = true

        videoCard.contentView.addSubview(videoStack)
        videoStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(videoStack, in: videoCard.contentView)
        rootStack.addArrangedSubview(videoCard.container)
        videoCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 2. 卡片：分辨率与帧率
        let formatCard = makeCardView(title: "2. 采集分辨率与刷新率 (Format & FPS)")
        let formatStack = NSStackView()
        formatStack.orientation = .vertical
        formatStack.alignment = .leading
        formatStack.spacing = 8

        formatPopup.target = self
        formatPopup.action = #selector(onFormatChanged(_:))
        // 宽度上限：不设的话 NSPopUpButton 会拿「最长标题的固有宽度」反向把面板顶宽
        // （实测 contentView 被撑到 609pt > 窗口 560pt，右侧控件会被裁）。
        formatPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        formatStack.addArrangedSubview(makeRow(label: "分辨率:", control: formatPopup))

        fpsPopup.target = self
        fpsPopup.action = #selector(onFpsChanged(_:))
        fpsPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        formatStack.addArrangedSubview(makeRow(label: "采集帧率:", control: fpsPopup))

        formatDetailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        formatDetailLabel.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.50, alpha: 1.0)
        formatStack.addArrangedSubview(formatDetailLabel)
        makeWrappingLabel(formatDetailLabel, in: formatStack)

        let formatTip = NSTextField(labelWithString: "📋 分辨率与帧率均来自采集卡实时上报，只列它真正支持的组合。帧率按设备原生的精确时长锁定，选多少就是多少。")
        formatTip.font = .systemFont(ofSize: 11, weight: .regular)
        formatTip.textColor = NSColor(white: 0.65, alpha: 1.0)
        formatStack.addArrangedSubview(formatTip)
        makeWrappingLabel(formatTip, in: formatStack)

        formatCard.contentView.addSubview(formatStack)
        formatStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(formatStack, in: formatCard.contentView)
        rootStack.addArrangedSubview(formatCard.container)
        formatCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 3. 卡片：音频输入设备
        let audioCard = makeCardView(title: "3. 音频输入设备 (Audio Device)")
        let audioStack = NSStackView()
        audioStack.orientation = .vertical
        audioStack.alignment = .leading
        audioStack.spacing = 8

        audioDevicePopup.target = self
        audioDevicePopup.action = #selector(onAudioDeviceChanged(_:))
        audioDevicePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 400).isActive = true
        audioStack.addArrangedSubview(makeRow(label: "音频通道:", control: audioDevicePopup))

        audioMatchLabel.font = .systemFont(ofSize: 11, weight: .medium)
        audioMatchLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        audioStack.addArrangedSubview(audioMatchLabel)
        makeWrappingLabel(audioMatchLabel, in: audioStack)

        let audioTip = NSTextField(labelWithString: "🔊 按 USB 厂商/产品 ID 与采集卡做硬件关联匹配，保证游戏声音与画面同源、低延迟同步。")
        audioTip.font = .systemFont(ofSize: 11, weight: .regular)
        audioTip.textColor = NSColor(white: 0.65, alpha: 1.0)
        audioStack.addArrangedSubview(audioTip)
        makeWrappingLabel(audioTip, in: audioStack)

        audioCard.contentView.addSubview(audioStack)
        audioStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(audioStack, in: audioCard.contentView)
        rootStack.addArrangedSubview(audioCard.container)
        audioCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 4. 卡片：推流输入延迟优化
        let latencyCard = makeCardView(title: "4. 采集卡推流延迟模式 (Low Latency)")
        let latencyStack = NSStackView()
        latencyStack.orientation = .vertical
        latencyStack.alignment = .leading
        latencyStack.spacing = 8

        latencyPopup.addItems(withTitles: CaptureLowLatencyMode.allCases.map { $0.title })
        latencyPopup.target = self
        latencyPopup.action = #selector(onLatencyChanged(_:))
        latencyStack.addArrangedSubview(makeRow(label: "延迟模式:", control: latencyPopup))

        let latencyTip = NSTextField(labelWithString: "⚡️ 极限模式跳过音视频时钟等待，采集帧直通 Metal 渲染流水线，跟手无感操作。")
        latencyTip.font = .systemFont(ofSize: 11, weight: .regular)
        latencyTip.textColor = NSColor(white: 0.65, alpha: 1.0)
        latencyStack.addArrangedSubview(latencyTip)
        makeWrappingLabel(latencyTip, in: latencyStack)

        latencyCard.contentView.addSubview(latencyStack)
        latencyStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(latencyStack, in: latencyCard.contentView)
        rootStack.addArrangedSubview(latencyCard.container)
        latencyCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 5. 卡片：主机游戏 60Hz 假 60 帧识别重构
        let fake60Card = makeCardView(title: "5. 主机 60Hz 假 60 帧识别重构 (Fake 60 FPS)")
        let fake60Stack = NSStackView()
        fake60Stack.orientation = .vertical
        fake60Stack.alignment = .leading
        fake60Stack.spacing = 8

        fake60Popup.addItems(withTitles: Fake60OptimizationMode.allCases.map { $0.title })
        fake60Popup.target = self
        fake60Popup.action = #selector(onFake60Changed(_:))
        fake60Stack.addArrangedSubview(makeRow(label: "假60重构:", control: fake60Popup))

        let fake60Tip = NSTextField(labelWithString: "🎮 针对 PS5/Switch/Xbox 30 FPS 画质模式在 HDMI 60Hz 信号下的重复帧，自动 AI 补帧升级为满血 60 FPS！")
        fake60Tip.font = .systemFont(ofSize: 11, weight: .regular)
        fake60Tip.textColor = NSColor(white: 0.65, alpha: 1.0)
        fake60Stack.addArrangedSubview(fake60Tip)
        makeWrappingLabel(fake60Tip, in: fake60Stack)

        fake60Card.contentView.addSubview(fake60Stack)
        fake60Stack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(fake60Stack, in: fake60Card.contentView)
        rootStack.addArrangedSubview(fake60Card.container)
        fake60Card.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 6. 卡片：采集色彩（对标 OBS 的 Color Range / Color Space）
        let colorCard = makeCardView(title: "6. 采集色彩 (Color Range & Matrix)")
        let colorStack = NSStackView()
        colorStack.orientation = .vertical
        colorStack.alignment = .leading
        colorStack.spacing = 8

        colorRangePopup.addItems(withTitles: CaptureColorRange.allCases.map { $0.title })
        colorRangePopup.target = self
        colorRangePopup.action = #selector(onColorChanged(_:))
        colorRangePopup.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        colorStack.addArrangedSubview(makeRow(label: "色彩范围:", control: colorRangePopup))

        colorMatrixPopup.addItems(withTitles: CaptureColorMatrix.allCases.map { $0.title })
        colorMatrixPopup.target = self
        colorMatrixPopup.action = #selector(onColorChanged(_:))
        colorMatrixPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        colorStack.addArrangedSubview(makeRow(label: "色彩矩阵:", control: colorMatrixPopup))

        let colorTip = NSTextField(labelWithString: "🎨 默认「自动」= 直接采用采集卡上报的像素格式与色彩附件，不做任何范围压缩（OBS 同款做法）。若驱动上报与实际数据不符，用这两档纠偏：范围选错表现为黑位压死/发灰，矩阵选错表现为偏色。")
        colorTip.font = .systemFont(ofSize: 11, weight: .regular)
        colorTip.textColor = NSColor(white: 0.65, alpha: 1.0)
        colorStack.addArrangedSubview(colorTip)
        makeWrappingLabel(colorTip, in: colorStack)

        colorCard.contentView.addSubview(colorStack)
        colorStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(colorStack, in: colorCard.contentView)
        rootStack.addArrangedSubview(colorCard.container)
        colorCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true

        // 底部工具条
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12
        bottomRow.alignment = .centerY

        cancelButton.target = self
        cancelButton.action = #selector(onCancelClicked(_:))
        cancelButton.bezelStyle = .rounded

        startButton.target = self
        startButton.action = #selector(onStartClicked(_:))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        bottomRow.addArrangedSubview(spacer)
        bottomRow.addArrangedSubview(cancelButton)
        bottomRow.addArrangedSubview(startButton)
        rootStack.addArrangedSubview(bottomRow)
        bottomRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
    }

    // MARK: - 设备扫描与填充

    func reloadDevices() {
        // 扫描视频输入设备
        let videoTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 13.0, *) {
            videoTypes = [.external, .builtInWideAngleCamera, .continuityCamera]
        } else {
            videoTypes = [.external, .builtInWideAngleCamera]
        }
        let vSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: videoTypes,
            mediaType: .video,
            position: .unspecified
        )
        videoDevices = vSession.devices

        videoDevicePopup.removeAllItems()
        if videoDevices.isEmpty {
            videoDevicePopup.addItem(withTitle: "未检测到视频采集卡或摄像头")
            videoDevicePopup.isEnabled = false
            deviceStatusLabel.stringValue = "⚠️ 未检测到采集设备，请插入 USB/HDMI 采集卡后点击刷新"
            deviceStatusLabel.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)
            startButton.isEnabled = false
        } else {
            for dev in videoDevices {
                let isExternal = (dev.deviceType == .external)
                let prefix = isExternal ? "🔌 [采集卡/外接] " : "📷 [内置/摄像头] "
                videoDevicePopup.addItem(withTitle: "\(prefix)\(dev.localizedName)")
            }
            videoDevicePopup.isEnabled = true
            deviceStatusLabel.stringValue = "🟢 已发现 \(videoDevices.count) 个可用视频输入设备"
            deviceStatusLabel.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.50, alpha: 1.0)
            startButton.isEnabled = true

            // 默认落在**外接采集卡**上：打开这个面板的场景就是要用采集卡，
            // 而 DiscoverySession 的返回顺序不保证外接优先（实测内置相机排在最前）。
            if let extIndex = videoDevices.firstIndex(where: { $0.deviceType == .external }) {
                videoDevicePopup.selectItem(at: extIndex)
            }
        }

        // 扫描音频输入设备
        let aSession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInMicrophone],
            mediaType: .audio,
            position: .unspecified
        )
        audioDevices = aSession.devices

        audioDevicePopup.removeAllItems()
        audioDevicePopup.addItem(withTitle: "伴随视频采集卡音频 (自动匹配)")
        for aDev in audioDevices {
            let isExternal = (aDev.deviceType == .external)
            audioDevicePopup.addItem(withTitle: "\(isExternal ? "🔌" : "🎙️") \(aDev.localizedName)")
        }
        audioDevicePopup.addItem(withTitle: "🔇 静音 (不输入音频)")

        updateDeviceInfo()
        reloadFormats()
        updateAudioMatch()
    }

    // MARK: - dev：采集能力转储 / 启动契约探测

    /// dev-only（`MP_CAPTURE_START`）：走一遍真实启动路径，但只把「交给播放引擎的参数」
    /// 交给回调，**不真的开采集**。
    ///
    /// 为什么要单独留这个口：面板的对外契约就是 `onStartCapture` 这四个参数。
    /// 旧版的问题恰恰是「列表上是 A、交出去的是 B」（选 4K 交出去 1080p、选 60 交出去预设值）。
    /// 光看列表对不对证明不了契约，必须把真正交出去的那四个值打出来。
    func devStart() {
        onStartClicked(nil)
    }

    /// dev-only（`MP_CAPTURE_DUMP`）：把面板当前枚举到的**设备真实能力**打成文本。
    /// 用途是自查「面板列出的规格是不是设备真的支持的」，而不是靠截图肉眼比对。
    func debugDumpText() -> String {
        var out = ["", "[采集能力转储] 视频设备 \(videoDevices.count) 个 · 音频设备 \(audioDevices.count) 个"]
        for (i, d) in videoDevices.enumerated() {
            out.append("  #\(i) \(d.localizedName) | type=\(d.deviceType.rawValue)")
            out.append("       model=\(d.modelID) mfr=\(d.manufacturer) uid=\(d.uniqueID)")
            let dims = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
            out.append("       active=\(Int(dims.width))x\(Int(dims.height)) sub=\(CaptureFormatOption.fourCC(CMFormatDescriptionGetMediaSubType(d.activeFormat.formatDescription)))")
        }
        out.append("  音频:")
        for a in audioDevices {
            out.append("       \(a.localizedName) | uid=\(a.uniqueID) | model=\(a.modelID) | mfr=\(a.manufacturer)")
        }
        if !videoDevices.isEmpty {
            let vIndex = max(0, min(videoDevicePopup.indexOfSelectedItem, videoDevices.count - 1))
            let v = videoDevices[vIndex]
            if let (vid, pid) = Self.usbVIDPID(from: v.modelID) {
                out.append("  VID:PID 解析: \(v.modelID) → \(vid):\(pid)")
            } else {
                out.append("  VID:PID 解析: \(v.modelID) → 无（非 USB UVC 命名）")
            }
            if let m = matchedAudioDevice(for: v) {
                out.append("  音频自动匹配 → \(m.localizedName)")
            } else {
                out.append("  音频自动匹配 → 未命中")
            }
        }
        out.append("  规格列表（formatPopup \(formatPopup.numberOfItems) 项 / 模型 \(formatOptions.count) 条）:")
        for (i, item) in formatPopup.itemTitles.enumerated() {
            let detail = i < formatOptions.count ? formatOptions[i].detailText : ""
            let mark = (i == formatPopup.indexOfSelectedItem) ? "→" : " "
            out.append("    \(mark)[\(i)] \(item)\(detail.isEmpty || item.contains("Native") ? "" : "   <<\(detail)>>")")
        }
        out.append("  帧率列表（fpsPopup \(fpsPopup.numberOfItems) 项，随分辨率联动）:")
        for (i, t) in fpsPopup.itemTitles.enumerated() {
            let mark = (i == fpsPopup.indexOfSelectedItem) ? "→" : " "
            let durText: String
            if i < (formatOptions.indices.contains(max(0, min(formatPopup.indexOfSelectedItem, formatOptions.count - 1))) ? formatOptions[max(0, min(formatPopup.indexOfSelectedItem, formatOptions.count - 1))].ranges.count : 0) {
                let idx = max(0, min(formatPopup.indexOfSelectedItem, formatOptions.count - 1))
                let d = formatOptions[idx].ranges[i].minFrameDuration
                durText = "  精确时长 \(d.value)/\(d.timescale)"
            } else { durText = "" }
            out.append("    \(mark)[\(i)] \(t)\(durText)")
        }
        out.append("  回显: \(formatDetailLabel.stringValue)")
        out.append("  音频: \(audioMatchLabel.stringValue)")
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - 设备信息 / 音频硬件关联

    /// 显示采集卡的硬件身份，便于确认选中的确实是要用的那张卡（同名设备插多张时很有用）。
    private func updateDeviceInfo() {
        guard !videoDevices.isEmpty else {
            deviceInfoLabel.stringValue = "—"
            return
        }
        let vIndex = max(0, min(videoDevicePopup.indexOfSelectedItem, videoDevices.count - 1))
        let d = videoDevices[vIndex]
        let uid = d.uniqueID
        let shortUID = uid.count > 18 ? "\(uid.prefix(8))…\(uid.suffix(6))" : uid
        deviceInfoLabel.stringValue = "厂商 \(d.manufacturer.isEmpty ? "未知" : d.manufacturer) · 型号 \(d.modelID) · ID \(shortUID)"
    }

    /// 按 USB 厂商/产品 ID 把采集卡的音频通道关联出来。
    ///
    /// 旧版用 `localizedName.contains(视频设备名)` 猜，实测会失配：
    /// 本机 USB3 Video 采集卡的视频名是「USB3 Video」、音频名是「USB3 Digital Audio」，
    /// 包含判断为 false，只能碰运气回落到「第一个外接音频」。
    /// 这里改用硬件身份：视频 modelID 里的 `VendorID_13407 ProductID_8496`
    /// 正好对上音频 uid/model 里的 `345F:2130`（13407=0x345F, 8496=0x2130）。
    private func matchedAudioDevice(for video: AVCaptureDevice) -> AVCaptureDevice? {
        // 1) USB VID:PID 硬件关联 —— 最强的同源证据
        if let (vid, pid) = Self.usbVIDPID(from: video.modelID) {
            for a in audioDevices where Self.audioHaystack(a).contains("\(vid):\(pid)") {
                return a
            }
            for a in audioDevices {
                let hay = Self.audioHaystack(a)
                if hay.contains(vid) && hay.contains(pid) { return a }
            }
        }
        // 2) 同一厂商（多张同厂卡时会命中多个，优先外接）
        let mfr = video.manufacturer
        if !mfr.isEmpty {
            let same = audioDevices.filter { $0.manufacturer == mfr }
            if same.count == 1 { return same[0] }
            if let first = same.first(where: { $0.deviceType == .external }) { return first }
        }
        // 3) 名称最长公共前缀（Continuity Camera 的「…的相机 / …的麦克风」靠这条命中）
        var best: (AVCaptureDevice, Int)?
        for a in audioDevices {
            let common = Self.commonPrefixLength(video.localizedName, a.localizedName)
            if common >= 4, best == nil || common > best!.1 { best = (a, common) }
        }
        if let b = best { return b.0 }
        // 4) 最后兜底：第一个外接音频设备
        return audioDevices.first { $0.deviceType == .external }
    }

    private static func audioHaystack(_ a: AVCaptureDevice) -> String {
        "\(a.uniqueID) \(a.modelID) \(a.localizedName)".uppercased()
    }

    /// 从 `UVC Camera VendorID_13407 ProductID_8496` 里取出十六进制 VID/PID。
    /// 也兼容 `USB3 Digital Audio:345F:2130` 这类直接带 hex 的形式。
    private static func usbVIDPID(from modelID: String) -> (String, String)? {
        var vid: Int?, pid: Int?
        for p in modelID.split(separator: " ") {
            if p.hasPrefix("VendorID_"), let v = Int(p.dropFirst("VendorID_".count)) { vid = v }
            if p.hasPrefix("ProductID_"), let v = Int(p.dropFirst("ProductID_".count)) { pid = v }
        }
        if let v = vid, let p = pid {
            return (String(format: "%04X", v), String(format: "%04X", p))
        }
        let hexParts = modelID.split(separator: ":").compactMap { UInt32($0, radix: 16) }
        if hexParts.count >= 2 {
            return (String(format: "%04X", hexParts[0]), String(format: "%04X", hexParts[1]))
        }
        return nil
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        var n = 0
        for (ca, cb) in zip(a, b) {
            if ca != cb { break }
            n += 1
        }
        return n
    }

    /// 如实回显「自动匹配」到底匹配到了什么 —— 不再让用户以为匹配上了其实是碰运气。
    private func updateAudioMatch() {
        let aIndex = audioDevicePopup.indexOfSelectedItem
        guard !videoDevices.isEmpty else {
            audioMatchLabel.stringValue = "—"
            return
        }
        if aIndex == 0 {
            let vIndex = max(0, min(videoDevicePopup.indexOfSelectedItem, videoDevices.count - 1))
            let videoDev = videoDevices[vIndex]
            if let m = matchedAudioDevice(for: videoDev) {
                audioMatchLabel.stringValue = "自动匹配 → \(m.localizedName)"
                audioMatchLabel.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.50, alpha: 1.0)
            } else {
                audioMatchLabel.stringValue = "未匹配到同源音频，将仅采集视频"
                audioMatchLabel.textColor = NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0)
            }
        } else if aIndex >= audioDevices.count + 1 {
            audioMatchLabel.stringValue = "静音：不输入音频"
            audioMatchLabel.textColor = NSColor(white: 0.55, alpha: 1.0)
        } else {
            audioMatchLabel.stringValue = "手动指定：\(audioDevices[max(0, aIndex - 1)].localizedName)"
            audioMatchLabel.textColor = NSColor(white: 0.85, alpha: 1.0)
        }
    }

    /// 从采集卡实际支持的 `formats` 枚举可选规格。
    ///
    /// 旧版是硬编码 7 条预设（含设备压根不存在的 4K@60），选了不支持的会静默回落；
    /// 现在列表里出现的每一项都是设备自己上报的，选哪个就一定拿到哪个。
    func reloadFormats() {
        formatPopup.removeAllItems()
        formatOptions.removeAll()

        guard !videoDevices.isEmpty else {
            formatPopup.addItem(withTitle: "请先选择视频输入设备")
            formatPopup.isEnabled = false
            fpsPopup.removeAllItems()
            fpsPopup.isEnabled = false
            formatDetailLabel.stringValue = "无设备"
            return
        }
        let vIndex = max(0, min(videoDevicePopup.indexOfSelectedItem, videoDevices.count - 1))
        let device = videoDevices[vIndex]

        // 设备当前生效规格（Native）—— 放在第一位，作为「不改直接用」的选项。
        formatPopup.addItem(withTitle: "设备当前默认 (Native)")
        formatOptions.append(CaptureFormatOption(format: device.activeFormat,
                                                 width: 0, height: 0,
                                                 subType: 0, ranges: []))

        // 按 (分辨率 + 像素格式) 归并：同一组可能对应多个 format 对象，帧率档位要并起来。
        var buckets: [String: (option: CaptureFormatOption, ranges: [AVFrameRateRange])] = [:]
        var skippedPacked = 0
        for f in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let w = Int(dims.width), h = Int(dims.height)
            guard w > 0, h > 0 else { continue }
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)

            // 打包格式 YUY2（'yuvs'，4:2:2 单平面）：渲染器专用片段函数直出，且
            // PlaybackEngine.enqueueFrame 里已接入 YUY2→NV12 的 GPU 实时转换，
            // 选它开补帧也能正常工作（每帧多一次轻量转码）。UYVY('2vuy') 字节序相反、
            // 无实测样本，仍排除在可渲染格式之外。
            guard CaptureFormatOption.isRenderablePixelFormat(sub) else { skippedPacked += 1; continue }

            let key = "\(w)x\(h)-\(sub)"
            if var existing = buckets[key] {
                // 同组不同 format 对象的档位合并，按帧率去重（保留第一个，时长值相同）
                let known = Set(existing.ranges.map { $0.maxFrameRate })
                for r in f.videoSupportedFrameRateRanges where !known.contains(r.maxFrameRate) {
                    existing.ranges.append(r)
                }
                buckets[key] = existing
            } else {
                let opt = CaptureFormatOption(format: f, width: w, height: h,
                                              subType: sub, ranges: [])
                buckets[key] = (opt, f.videoSupportedFrameRateRanges)
            }
        }
        if skippedPacked > 0 {
            NSLog("[Capture] 已跳过 %d 个打包 4:2:2 规格（渲染器仅支持双平面 NV12/P010）", skippedPacked)
        }

        var list: [CaptureFormatOption] = buckets.values.map { pair in
            CaptureFormatOption(format: pair.option.format,
                                width: pair.option.width,
                                height: pair.option.height,
                                subType: pair.option.subType,
                                ranges: pair.ranges.sorted { $0.maxFrameRate > $1.maxFrameRate })
        }

        // 排序：分辨率降序 → 高帧率优先 → 原生 NV12 优先（省一次逐帧转码）
        list.sort { a, b in
            let pa = a.width * a.height, pb = b.width * b.height
            if pa != pb { return pa > pb }
            if a.maxFPS != b.maxFPS { return a.maxFPS > b.maxFPS }
            if a.isNativeNV12 != b.isNativeNV12 { return a.isNativeNV12 && !b.isNativeNV12 }
            return a.subType < b.subType
        }

        for opt in list {
            formatPopup.addItem(withTitle: opt.title)
            formatOptions.append(opt)
        }

        // 设备只提供暂不支持的格式（UYVY / RGB / BGRA / I420 等）时列表会是空的。
        // 这里必须给出明确说明并禁用，不能让用户对着一片空白点「开始采集」。
        // 注：YUY2（'yuvs'）已纳入可渲染格式，YUY2-only 设备能正常列出与采集。
        if list.isEmpty {
            formatPopup.addItem(withTitle: "该设备无可用规格（仅提供 UYVY/RGB 等暂不支持格式）")
            formatPopup.isEnabled = false
            fpsPopup.removeAllItems()
            fpsPopup.isEnabled = false
            formatDetailLabel.stringValue = "⚠️ 渲染器当前支持 NV12 / P010 / YUY2，该设备未提供这类规格"
            return
        }
        fpsPopup.isEnabled = true

        formatPopup.isEnabled = true

        // 默认选中设备能力最强的原生 NV12 规格；没有 NV12 就选列表第一条。
        let preferred = list.firstIndex { $0.isNativeNV12 } ?? 0
        let selectIndex = list.isEmpty ? 0 : preferred + 1
        formatPopup.selectItem(at: selectIndex)
        reloadFrameRates()
    }

    /// 帧率档位随选中的分辨率联动重建 —— 只列这个分辨率**真的支持**的档位。
    private func reloadFrameRates() {
        fpsPopup.removeAllItems()
        let idx = max(0, min(formatPopup.indexOfSelectedItem, formatOptions.count - 1))
        let opt = formatOptions[idx]
        let rates = opt.frameRates

        guard !rates.isEmpty else {
            fpsPopup.addItem(withTitle: "设备默认")
            fpsPopup.isEnabled = false
            updateFormatDetail()
            return
        }

        for r in rates {
            fpsPopup.addItem(withTitle: "\(CaptureFormatOption.fmt(r)) FPS")
        }
        fpsPopup.isEnabled = true
        fpsPopup.selectItem(at: 0)   // 默认最高帧率
        updateFormatDetail()
    }

    /// 当前选中的帧率档位在 `ranges` 里的下标（-1 表示未选/用设备默认）。
    private var selectedFpsIndex: Int {
        let idx = max(0, min(formatPopup.indexOfSelectedItem, formatOptions.count - 1))
        let fIdx = fpsPopup.indexOfSelectedItem
        guard fpsPopup.isEnabled, fIdx >= 0, fIdx < formatOptions[idx].ranges.count else { return -1 }
        return fIdx
    }

    /// 回显选中规格的实际输出，并如实标注「帧率由规格决定、无法软件锁定」。
    private func updateFormatDetail() {
        let idx = max(0, min(formatPopup.indexOfSelectedItem, formatOptions.count - 1))
        let opt = formatOptions[idx]
        if idx == 0 {
            guard !videoDevices.isEmpty else {
                formatDetailLabel.stringValue = "无设备"
                return
            }
            let vIndex = max(0, min(videoDevicePopup.indexOfSelectedItem, videoDevices.count - 1))
            let device = videoDevices[vIndex]
            let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let sub = CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
            let name = CaptureFormatOption(format: device.activeFormat, width: 0, height: 0,
                                           subType: sub, ranges: []).pixelFormatName
            let fps = device.activeFormat.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30.0
            formatDetailLabel.stringValue =
                "实际输出 \(Int(dims.width))×\(Int(dims.height)) · \(CaptureFormatOption.fmt(fps)) FPS · \(name)（设备当前值，帧率未锁定）"
        } else {
            let fpsIdx = selectedFpsIndex
            if fpsIdx >= 0 {
                let r = opt.ranges[fpsIdx]
                let nv12 = opt.isNativeNV12 ? "原生 NV12" : "\(opt.pixelFormatName)（需转码）"
                formatDetailLabel.stringValue =
                    "实际输出 \(opt.width)×\(opt.height) · \(CaptureFormatOption.fmt(r.maxFrameRate)) FPS · \(nv12) · 帧率已锁定"
            } else {
                formatDetailLabel.stringValue = "实际输出 \(opt.detailText)"
            }
        }
    }

    private func syncSettingsToUI() {
        let s = PlaybackSettings.shared
        if let idx = CaptureLowLatencyMode.allCases.firstIndex(of: s.captureLowLatencyMode) {
            latencyPopup.selectItem(at: idx)
        }
        if let idx = Fake60OptimizationMode.allCases.firstIndex(of: s.fake60FPSOptimization) {
            fake60Popup.selectItem(at: idx)
        }
        if let idx = CaptureColorRange.allCases.firstIndex(of: s.captureColorRange) {
            colorRangePopup.selectItem(at: idx)
        }
        if let idx = CaptureColorMatrix.allCases.firstIndex(of: s.captureColorMatrix) {
            colorMatrixPopup.selectItem(at: idx)
        }
    }

    // MARK: - 事件响应

    @objc private func onRefreshClicked(_ sender: Any?) {
        reloadDevices()
    }

    @objc private func onVideoDeviceChanged(_ sender: Any?) {
        updateDeviceInfo()
        reloadFormats()
        updateAudioMatch()
    }

    @objc private func onFormatChanged(_ sender: Any?) {
        reloadFrameRates()   // 帧率档位跟着分辨率变
    }

    @objc private func onFpsChanged(_ sender: Any?) {
        updateFormatDetail()
    }

    @objc private func onAudioDeviceChanged(_ sender: Any?) {
        updateAudioMatch()
    }

    @objc private func onLatencyChanged(_ sender: Any?) {
        let idx = latencyPopup.indexOfSelectedItem
        if idx >= 0 && idx < CaptureLowLatencyMode.allCases.count {
            PlaybackSettings.shared.captureLowLatencyMode = CaptureLowLatencyMode.allCases[idx]
        }
    }

    @objc private func onFake60Changed(_ sender: Any?) {
        let idx = fake60Popup.indexOfSelectedItem
        if idx >= 0 && idx < Fake60OptimizationMode.allCases.count {
            PlaybackSettings.shared.fake60FPSOptimization = Fake60OptimizationMode.allCases[idx]
        }
    }

    @objc private func onColorChanged(_ sender: Any?) {
        let r = colorRangePopup.indexOfSelectedItem
        if r >= 0 && r < CaptureColorRange.allCases.count {
            PlaybackSettings.shared.captureColorRange = CaptureColorRange.allCases[r]
        }
        let m = colorMatrixPopup.indexOfSelectedItem
        if m >= 0 && m < CaptureColorMatrix.allCases.count {
            PlaybackSettings.shared.captureColorMatrix = CaptureColorMatrix.allCases[m]
        }
    }

    @objc private func onCancelClicked(_ sender: Any?) {
        window?.close()
    }

    @objc private func onStartClicked(_ sender: Any?) {
        guard !videoDevices.isEmpty else { return }
        let vIndex = max(0, min(videoDevicePopup.indexOfSelectedItem, videoDevices.count - 1))
        let selectedVideo = videoDevices[vIndex]

        // 音频设备选择：自动档走硬件 VID:PID 关联，不再用名称包含去猜
        var selectedAudio: AVCaptureDevice? = nil
        let aIndex = audioDevicePopup.indexOfSelectedItem
        if aIndex == 0 {
            selectedAudio = matchedAudioDevice(for: selectedVideo)
        } else if aIndex > 0 && aIndex <= audioDevices.count {
            selectedAudio = audioDevices[aIndex - 1]
        }
        // aIndex == audioDevices.count + 1 → 静音，保持 nil

        // 规格与帧率：都从设备真实上报的 format 取，不再用预设值
        let fIndex = max(0, min(formatPopup.indexOfSelectedItem, formatOptions.count - 1))
        let chosenFormat = formatOptions[fIndex].format
        let fpsIdx = selectedFpsIndex
        // 帧率取用户选中的那一档，而不是规格的最高帧率 —— 用户要的就是「能自己选」。
        let targetFPS: Double
        if fpsIdx >= 0 {
            targetFPS = formatOptions[fIndex].ranges[fpsIdx].maxFrameRate
        } else {
            targetFPS = chosenFormat.videoSupportedFrameRateRanges
                .map { $0.maxFrameRate }.max() ?? 30.0
        }
        // 精确帧时长：必须用 range 自带的 CMTime（60fps 是 1000000/60000240 而非 1/60），
        // 自己构造 1/N 会让 CoreMediaIO 抛异常直接闪退。
        let frameDuration = formatOptions[fIndex].frameDuration(at: fpsIdx)

        NSLog("[Capture] 启动 %@ · %d×%d · %.2f FPS · 锁定时长=%@ · 音频=%@",
              selectedVideo.localizedName,
              formatOptions[fIndex].width, formatOptions[fIndex].height,
              targetFPS,
              frameDuration.map { "\($0.value)/\($0.timescale)" } ?? "不锁定",
              selectedAudio?.localizedName ?? "静音")

        // 保存设置
        onLatencyChanged(self)
        onFake60Changed(self)

        window?.close()
        onStartCapture?(selectedVideo, selectedAudio, chosenFormat, targetFPS, frameDuration)
    }

    // MARK: - 辅助组件生成

    private func makeCardView(title: String) -> (container: NSView, contentView: NSView) {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(red: 0.16, green: 0.16, blue: 0.19, alpha: 1.0).cgColor
        box.layer?.cornerRadius = 8
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 0.25, alpha: 1.0).cgColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 1.0)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(titleLabel)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),

            content.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8)
        ])

        return (box, content)
    }

    private func makeRow(label: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = NSColor(white: 0.85, alpha: 1.0)
        lbl.setContentHuggingPriority(.required, for: .horizontal)

        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // 允许控件被压缩：否则长标题（如 `1920×1080 · 60p · NV12`）会以 intrinsic 宽度
        // 反向撑宽整条约束链，把面板顶出窗口。
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(lbl)
        row.addArrangedSubview(control)
        return row
    }

    /// 让多行说明文本按容器宽度换行，而不是拿 intrinsic 宽度把整个面板撑宽。
    ///
    /// NSStackView 的 `.leading` 对齐不会拉伸 arrangedSubview 的宽度，
    /// 所以 wordWrap 的火柴盒宽度会被当成「一行到底」——面板实测被撑到 720pt。
    private func makeWrappingLabel(_ label: NSTextField, in container: NSStackView) {
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func pinToEdges(_ subview: NSView, in parent: NSView) {
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: parent.topAnchor),
            subview.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            subview.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
        ])
    }
}
