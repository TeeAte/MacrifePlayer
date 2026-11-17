// RIFEConfigPanelController.swift
// Macrife Player · 视频补帧详细配置与模型专属高级定制面板
//
// 架构设计：
// 1. 采用坚实深色高对比底板（Solid High-Contrast Dark Theme），彻底解决半透明磨砂
//    在纯黑视频/桌面背景下文字变暗、发灰模糊、对比度缺失的问题；
// 2. 独立立体浮凸卡片（Solid Card Layer），搭配 1px 高光描边与微投影，清晰分区；
// 3. 所有标签文字、数值指示器、复选框均升级为纯白与高饱和科技青色，对比鲜明锐利；
// 4. 为模型架构定制独立的高对比 Info Badge 提示框；
// 5. 将所有补帧模型选择收拢至本面板，一站式调控内核与精度；
// 6. 针对 RIFE 与 Apple 低延迟动态展示可用参数；
// 7. 全局实时热切换：所有参数滑动即刻写入 PlaybackSettings 并通知播放引擎。

import Foundation
import AppKit

// MARK: - 自定义高质感坚实深色底板
final class PanelBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        // 纯净不透明微渐变深空灰底色，彻底阻断窗口后方任何黑色/彩色画面的透光干扰
        let gradient = NSGradient(
            starting: NSColor(red: 0.145, green: 0.145, blue: 0.165, alpha: 1.0),
            ending: NSColor(red: 0.115, green: 0.115, blue: 0.130, alpha: 1.0)
        )
        gradient?.draw(in: bounds, angle: -90)
    }
}

// MARK: - 自定义高对比度浮凸卡片视图
final class PanelCardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // 实体深石墨色，与底板形成清晰的明暗阶梯，100% 不透明
        layer?.backgroundColor = NSColor(red: 0.20, green: 0.20, blue: 0.23, alpha: 1.0).cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.8
        // 细腻明亮的高光微描边
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.18).cgColor
        // 微弱柔和的环境阴影
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.shadowRadius = 4
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 高对比度模型提示徽章视图
final class PanelInfoBadgeView: NSView {
    enum Theme {
        case cyan    // RIFE 光流专属
        case neutral // 通用说明
    }

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.0

        label.font = .systemFont(ofSize: 11.5, weight: .medium)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, theme: Theme) {
        label.stringValue = text
        switch theme {
        case .cyan:
            layer?.backgroundColor = NSColor(red: 0.08, green: 0.20, blue: 0.28, alpha: 0.95).cgColor
            layer?.borderColor = NSColor(red: 0.30, green: 0.72, blue: 1.00, alpha: 0.60).cgColor
            label.textColor = NSColor(red: 0.70, green: 0.90, blue: 1.00, alpha: 1.0)
        case .neutral:
            layer?.backgroundColor = NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 0.95).cgColor
            layer?.borderColor = NSColor(white: 1.0, alpha: 0.20).cgColor
            label.textColor = NSColor(white: 0.92, alpha: 1.0)
        }
    }
}

private final class InterpolationSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 主控制器
final class RIFEConfigPanelController: NSWindowController {

    private static let videoPanel = RIFEConfigPanelController(inputKind: .videoFile)
    private static let capturePanel = RIFEConfigPanelController(inputKind: .captureCard)
    static func forInput(_ kind: PlaybackInputKind) -> RIFEConfigPanelController {
        kind == .videoFile ? videoPanel : capturePanel
    }
    static var shared: RIFEConfigPanelController { forInput(PlaybackSettings.shared.inputKind) }
    private let inputKind: PlaybackInputKind
    private let settings: PlaybackSettings
    var onOpenCaptureDevice: (() -> Void)?


    // MARK: - 控件

    // 1. 目标速率与帧率
    private let rateModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customFpsSlider = NSSlider(value: 60, minValue: 24, maxValue: 240, target: nil, action: nil)
    private let customFpsLabel = NSTextField(labelWithString: "60.0 FPS")
    private let customFpsRow = NSStackView()

    // 2. AI 模型与计算精度
    private let backendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var precisionRow: NSView?
    private let precisionInfoLabel = NSTextField(labelWithString: "")
    private let latencyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let console30Popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let resolutionTip = NSTextField(wrappingLabelWithString: "")
    private var protectionCard: NSView?
    private let precisionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelTipBadge = PanelInfoBadgeView()

    // 4. 推理缩放与分辨率
    private let resPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // 5. 调度与性能

    // 6. 画面保护与节能
    private let sceneDetectionCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sceneThresholdSlider = NSSlider(value: 0.30, minValue: 0.05, maxValue: 0.80, target: nil, action: nil)
    private let sceneThresholdLabel = NSTextField(labelWithString: "30%")

    private let staticSkipCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let staticThresholdSlider = NSSlider(value: 0.02, minValue: 0.005, maxValue: 0.10, target: nil, action: nil)
    private let staticThresholdLabel = NSTextField(labelWithString: "2.0%")

    // 7. 广播级隔行反交错 (MTS / 1080 50i/60i)
    private let deinterlacePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // 8. HDR 转 SDR 色调映射 (Tone Mapping)
    private let hdrToneMappingPopup = NSPopUpButton(frame: .zero, pullsDown: false)


    // 底部工具条
    private let statusIndicator = NSTextField(labelWithString: "● 设置按后端能力生效")
    private let resetButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)

    private var isUpdatingUI = false

    // MARK: - 初始化

    private init(inputKind: PlaybackInputKind) {
        self.inputKind = inputKind
        self.settings = PlaybackSettings.forInput(inputKind)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 920),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "AI 视频补帧 · 详细配置与模型专属定制"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        // 强制采用专业深色模式外观，阻断外部浅色穿透
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(red: 0.13, green: 0.13, blue: 0.15, alpha: 1.0)
        panel.isOpaque = true

        super.init(window: panel)

        setupUI()
        loadFromSettings()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSettingsChanged(_:)),
            name: .playbackSettingsDidChange, object: nil
        )
        NotificationCenter.default.addObserver(self, selector: #selector(handleSettingsChanged(_:)),
            name: .playbackInputProfileDidChange, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 呈现与定位

    func show(relativeTo parentWindow: NSWindow? = nil) {
        guard let window = self.window else { return }
        window.title = settings.inputKind.title + "补帧 · 独立配置"
        loadFromSettings()

        if let parent = parentWindow, !window.isVisible {
            let parentFrame = parent.frame
            let x = parentFrame.origin.x + max(20, (parentFrame.width - window.frame.width) / 2)
            let y = parentFrame.origin.y + max(20, (parentFrame.height - window.frame.height) / 2)
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else if !window.isVisible {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI 构建

    private func setupUI() {
        guard let window = self.window else { return }

        // 1. 根背景视图：使用完全不透明的坚实暗炭色背景，避免半透明磨砂在纯黑窗口下混色发暗
        let bgView = PanelBackgroundView(frame: window.contentView?.bounds ?? .zero)
        bgView.autoresizingMask = [.width, .height]
        window.contentView = bgView

        // 2. 滚动容器：保证在不同屏幕比例下所有高级选项均能顺畅浏览
        let scrollView = NSScrollView(frame: bgView.bounds)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        bgView.addSubview(scrollView)

        let clipView = NSClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        let scrollDocView = InterpolationSettingsDocumentView()
        scrollDocView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = scrollDocView

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 11
        rootStack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        scrollDocView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: bgView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: bgView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bgView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bgView.bottomAnchor),

            scrollDocView.leadingAnchor.constraint(equalTo: clipView.leadingAnchor),
            scrollDocView.trailingAnchor.constraint(equalTo: clipView.trailingAnchor),
            scrollDocView.topAnchor.constraint(equalTo: clipView.topAnchor),

            rootStack.leadingAnchor.constraint(equalTo: scrollDocView.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: scrollDocView.trailingAnchor),
            rootStack.topAnchor.constraint(equalTo: scrollDocView.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: scrollDocView.bottomAnchor),
            scrollDocView.bottomAnchor.constraint(equalTo: rootStack.bottomAnchor)
        ])

        // 1. 卡片：速率与目标帧率
        let rateCard = makeCardView(title: "目标速率与帧率")
        let rateStack = NSStackView()
        rateStack.orientation = .vertical
        rateStack.alignment = .leading
        rateStack.spacing = 7

        rateModePopup.addItems(withTitles: [
            "关闭补帧",
            "2X (双倍插帧)",
            "3X (三倍插帧)",
            "4X (四倍插帧)",
            "5X (五倍插帧)",
            "60 FPS (标准平滑)",
            "120 FPS (ProMotion 动态高刷)",
            "自定义目标 FPS"
        ])
        rateModePopup.target = self
        rateModePopup.action = #selector(onRateModeChanged(_:))

        let rateRow = makeRow(label: "预设模式:", control: rateModePopup)
        rateStack.addArrangedSubview(rateRow)

        customFpsSlider.target = self
        customFpsSlider.action = #selector(onCustomFpsChanged(_:))
        customFpsSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        customFpsLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        customFpsLabel.textColor = NSColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0) // 科技亮蓝，极高对比

        customFpsRow.orientation = .horizontal
        customFpsRow.spacing = 10
        customFpsRow.alignment = .centerY
        let customPrompt = NSTextField(labelWithString: "目标帧率:")
        customPrompt.font = .systemFont(ofSize: 12.5, weight: .medium)
        customPrompt.textColor = NSColor(white: 0.95, alpha: 1.0)
        customPrompt.alignment = .right
        customPrompt.widthAnchor.constraint(equalToConstant: 88).isActive = true
        customFpsRow.addArrangedSubview(customPrompt)
        customFpsRow.addArrangedSubview(customFpsSlider)
        customFpsRow.addArrangedSubview(customFpsLabel)

        rateStack.addArrangedSubview(customFpsRow)
        rateCard.contentView.addSubview(rateStack)
        rateStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(rateStack, in: rateCard.contentView)
        rootStack.addArrangedSubview(rateCard.container)
        rateCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        // 2. 卡片：AI 补帧模型内核与精度
        let modelCard = makeCardView(title: "补帧后端与模型")
        let modelStack = NSStackView()
        modelStack.orientation = .vertical
        modelStack.alignment = .leading
        modelStack.spacing = 8

        backendPopup.addItems(withTitles: InterpolationBackend.allCases.map(\.title))
        backendPopup.target = self
        backendPopup.action = #selector(onBackendChanged(_:))
        modelStack.addArrangedSubview(makeRow(label: "补帧后端:", control: backendPopup))
        modelPopup.addItems(withTitles: RIFEModelChoice.allCases.map(\.menuTitle))
        modelPopup.target = self
        modelPopup.action = #selector(onModelChanged(_:))
        modelStack.addArrangedSubview(makeRow(label: "模型权重:", control: modelPopup))

        precisionPopup.addItems(withTitles: [
            "FP16 半精度 (推荐 · Metal & Neural Engine 硬件加速)",
            "FP32 单精度 (完整浮点精度)"
        ])
        precisionPopup.target = self
        precisionPopup.action = #selector(onPrecisionChanged(_:))
        let numericRow = makeRow(label: "数值精度:", control: precisionPopup)
        precisionRow = numericRow
        modelStack.addArrangedSubview(numericRow)
        precisionInfoLabel.font = .systemFont(ofSize: 11.5)
        precisionInfoLabel.textColor = .secondaryLabelColor
        modelStack.addArrangedSubview(precisionInfoLabel)

        // 模型专属高对比提示徽章
        modelStack.addArrangedSubview(modelTipBadge)
        modelTipBadge.translatesAutoresizingMaskIntoConstraints = false
        modelTipBadge.widthAnchor.constraint(equalTo: modelStack.widthAnchor).isActive = true

        modelCard.contentView.addSubview(modelStack)
        modelStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(modelStack, in: modelCard.contentView)
        rootStack.addArrangedSubview(modelCard.container)
        modelCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        // 4. 卡片：推理分辨率与画面缩放
        let resCard = makeCardView(title: "光流推理分辨率")
        let resStack = NSStackView()
        resStack.orientation = .vertical
        resStack.alignment = .leading
        resStack.spacing = 7

        resPopup.target = self
        resPopup.action = #selector(onResolutionChanged(_:))
        resStack.addArrangedSubview(makeRow(label: "光流分辨率:", control: resPopup))
        resolutionTip.stringValue = "两类输入分别保存，每个后端独立记忆推理预算。"
        resolutionTip.font = .systemFont(ofSize: 11.5)
        resolutionTip.textColor = .secondaryLabelColor
        resStack.addArrangedSubview(resolutionTip)
        resolutionTip.widthAnchor.constraint(equalTo: resStack.widthAnchor).isActive = true
        resolutionTip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        resCard.contentView.addSubview(resStack)
        resStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(resStack, in: resCard.contentView)
        rootStack.addArrangedSubview(resCard.container)
        resCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        if inputKind == .captureCard {
        // Live-input controls belong only to the capture settings page.
        let perfCard = makeCardView(title: "采集延迟策略（所有补帧后端通用）")
        let perfStack = NSStackView()
        perfStack.orientation = .vertical
        perfStack.alignment = .leading
        perfStack.spacing = 7

        latencyPopup.addItems(withTitles: CaptureLowLatencyMode.allCases.map(\.title))
        latencyPopup.target = self
        latencyPopup.action = #selector(onLatencyChanged(_:))
        perfStack.addArrangedSubview(makeRow(label: "采集延迟:", control: latencyPopup))
        console30Popup.addItems(withTitles: Fake60OptimizationMode.allCases.map(\.title))
        console30Popup.target = self
        console30Popup.action = #selector(onConsole30Changed(_:))
        perfStack.addArrangedSubview(makeRow(label: "内容模式:", control: console30Popup))
        let latencyTip = NSTextField(wrappingLabelWithString: "主机 30FPS / 假60 输入：需要 60FPS 采集，固定隔帧取样后由 AI 补到 60FPS。原生60FPS游戏选择原始输入。低延迟策略只影响采集卡。")
        latencyTip.font = .systemFont(ofSize: 11.5)
        latencyTip.textColor = .secondaryLabelColor
        perfStack.addArrangedSubview(latencyTip)
        latencyTip.widthAnchor.constraint(equalTo: perfStack.widthAnchor).isActive = true
        latencyTip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let inputButton = NSButton(title: "采集设备与输入格式…", target: self, action: #selector(onOpenCaptureDevice(_:)))
        perfStack.addArrangedSubview(inputButton)

        perfCard.contentView.addSubview(perfStack)
        perfStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(perfStack, in: perfCard.contentView)
        rootStack.addArrangedSubview(perfCard.container)
        perfCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        }

        // 6. 卡片：智能保护与节能
        let protCard = makeCardView(title: "RIFE 转场与静帧保护")
        protectionCard = protCard.container
        let protStack = NSStackView()
        protStack.orientation = .vertical
        protStack.alignment = .leading
        protStack.spacing = 7

        configureCheckbox(sceneDetectionCheckbox, title: "启用镜头转场保护 (防跳变溶接鬼影)")
        sceneDetectionCheckbox.target = self
        sceneDetectionCheckbox.action = #selector(onSceneDetectionToggled(_:))
        protStack.addArrangedSubview(sceneDetectionCheckbox)

        sceneThresholdSlider.target = self
        sceneThresholdSlider.action = #selector(onSceneThresholdChanged(_:))
        sceneThresholdSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        sceneThresholdLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        sceneThresholdLabel.textColor = NSColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0)
        let sceneRow = makeRow(label: "转场灵敏度:", control: sceneThresholdSlider)
        sceneRow.addArrangedSubview(sceneThresholdLabel)
        protStack.addArrangedSubview(sceneRow)

        configureCheckbox(staticSkipCheckbox, title: "静止与微动画面跳过 (节能降温)")
        staticSkipCheckbox.target = self
        staticSkipCheckbox.action = #selector(onStaticSkipToggled(_:))
        protStack.addArrangedSubview(staticSkipCheckbox)

        staticThresholdSlider.target = self
        staticThresholdSlider.action = #selector(onStaticThresholdChanged(_:))
        staticThresholdSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        staticThresholdLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        staticThresholdLabel.textColor = NSColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0)
        let staticRow = makeRow(label: "静止判定阈值:", control: staticThresholdSlider)
        staticRow.addArrangedSubview(staticThresholdLabel)
        protStack.addArrangedSubview(staticRow)

        protCard.contentView.addSubview(protStack)
        protStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(protStack, in: protCard.contentView)
        rootStack.addArrangedSubview(protCard.container)
        protCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        let processingCard = makeCardView(title: inputKind == .videoFile ? "视频文件处理" : "HDMI 色彩处理")
        let processingStack = NSStackView()
        processingStack.orientation = .vertical
        processingStack.alignment = .leading
        processingStack.spacing = 7
        if inputKind == .videoFile {
            deinterlacePopup.addItems(withTitles: DeinterlaceMode.allCases.map(\.title))
            deinterlacePopup.target = self
            deinterlacePopup.action = #selector(onDeinterlaceModeChanged(_:))
            processingStack.addArrangedSubview(makeRow(label: "隔行反交错:", control: deinterlacePopup))
            let tip = NSTextField(wrappingLabelWithString: "用于 50i/60i 隔行视频文件。逐行视频保持关闭或自动，不使用主机抽帧逻辑。")
            tip.font = .systemFont(ofSize: 11.5)
            tip.textColor = .secondaryLabelColor
            processingStack.addArrangedSubview(tip)
            tip.widthAnchor.constraint(equalTo: processingStack.widthAnchor).isActive = true
        }
        hdrToneMappingPopup.addItems(withTitles: HDRToneMappingMode.allCases.map(\.title))
        hdrToneMappingPopup.target = self
        hdrToneMappingPopup.action = #selector(onHDRToneMappingChanged(_:))
        processingStack.addArrangedSubview(makeRow(label: "HDR 转 SDR:", control: hdrToneMappingPopup))
        let colorTip = NSTextField(wrappingLabelWithString: inputKind == .videoFile
            ? "仅处理当前视频文件的 HDR 色调映射，不改动采集卡参数。"
            : "采集色彩范围与矩阵在输入格式窗口设置；这里仅控制本链路的 HDR 色调映射。")
        colorTip.font = .systemFont(ofSize: 11.5)
        colorTip.textColor = .secondaryLabelColor
        processingStack.addArrangedSubview(colorTip)
        colorTip.widthAnchor.constraint(equalTo: processingStack.widthAnchor).isActive = true
        processingCard.contentView.addSubview(processingStack)
        processingStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(processingStack, in: processingCard.contentView)
        rootStack.addArrangedSubview(processingCard.container)
        processingCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        // 7. 底部工具条
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 12
        bottomRow.distribution = .fill

        statusIndicator.font = .systemFont(ofSize: 12, weight: .semibold)
        statusIndicator.textColor = NSColor(red: 0.35, green: 0.95, blue: 0.50, alpha: 1.0) // 醒目翠绿

        resetButton.target = self
        resetButton.action = #selector(onResetDefaults(_:))

        doneButton.target = self
        doneButton.action = #selector(onDone(_:))
        doneButton.keyEquivalent = "\r"

        bottomRow.addArrangedSubview(statusIndicator)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottomRow.addArrangedSubview(spacer)
        bottomRow.addArrangedSubview(resetButton)
        bottomRow.addArrangedSubview(doneButton)

        rootStack.addArrangedSubview(bottomRow)
        bottomRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true
    }

    // MARK: - 辅助组件生成

    private func makeCardView(title: String) -> (container: NSView, contentView: NSView) {
        let container = PanelCardView()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = NSColor.white // 纯白高对比
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentView)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            contentView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            contentView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            contentView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            contentView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12)
        ])

        return (container, contentView)
    }

    private func makeRow(label: String, control: NSView) -> NSStackView {
        if control is NSPopUpButton {
            control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            control.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        }
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY

        let prompt = NSTextField(labelWithString: label)
        prompt.font = .systemFont(ofSize: 12.5, weight: .medium)
        prompt.textColor = NSColor(white: 0.95, alpha: 1.0) // 纯净高亮白
        prompt.alignment = .right
        prompt.widthAnchor.constraint(equalToConstant: 88).isActive = true

        stack.addArrangedSubview(prompt)
        stack.addArrangedSubview(control)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func configureCheckbox(_ button: NSButton, title: String) {
        button.setButtonType(.switch)
        let pstyle = NSMutableParagraphStyle()
        pstyle.alignment = .left
        let attr = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor(white: 0.96, alpha: 1.0),
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .paragraphStyle: pstyle
            ]
        )
        button.attributedTitle = attr
    }

    private func pinToEdges(_ view: NSView, in parent: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            view.topAnchor.constraint(equalTo: parent.topAnchor),
            view.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    // MARK: - 读取与写回 Settings

    private func loadFromSettings() {
        window?.title = settings.inputKind.title + "补帧 · 独立配置"
        isUpdatingUI = true
        let s = settings
        statusIndicator.stringValue = inputKind == .videoFile ? "仅用于视频文件" : "仅用于采集卡"

        // 1. 速率
        switch s.rifeRateMode {
        case .off:       rateModePopup.selectItem(at: 0)
        case .x2:        rateModePopup.selectItem(at: 1)
        case .x3:        rateModePopup.selectItem(at: 2)
        case .x4:        rateModePopup.selectItem(at: 3)
        case .x5:        rateModePopup.selectItem(at: 4)
        case .fps60:     rateModePopup.selectItem(at: 5)
        case .fps120:    rateModePopup.selectItem(at: 6)
        case .customFps: rateModePopup.selectItem(at: 7)
        }
        customFpsRow.isHidden = (s.rifeRateMode != .customFps)
        customFpsSlider.doubleValue = s.rifeCustomTargetFps
        customFpsLabel.stringValue = String(format: "%.1f FPS", s.rifeCustomTargetFps)

        // Backend, weight profile and precision are separate settings.
        backendPopup.selectItem(at: InterpolationBackend.allCases.firstIndex(of: s.interpolationBackend) ?? 0)
        modelPopup.removeAllItems()
        if s.interpolationBackend == .rifeCoreML {
            modelPopup.addItems(withTitles: RIFEModelChoice.allCases.map(\.menuTitle))
            modelPopup.selectItem(at: RIFEModelChoice.allCases.firstIndex(of: s.rifeModel) ?? 0)
        } else {
            modelPopup.addItem(withTitle: s.interpolationBackend == .rifeMetalFast
                ? "RIFE v4.25 · Fast（内部 1/4 网格）"
                : s.interpolationBackend == .metalFX
                ? "MetalFX 系统补帧器（实验性）" : "Apple 系统模型（随 macOS 提供）")
        }
        modelPopup.isEnabled = s.interpolationBackend == .rifeCoreML
        updateModelTip(s.rifeModel)
        updateBackendControls()
        precisionPopup.removeAllItems()
        precisionPopup.addItems(withTitles: s.availableComputePrecisions.map(\.title))
        if let precisionIndex = s.availableComputePrecisions.firstIndex(of: s.rifePrecision) {
            precisionPopup.selectItem(at: precisionIndex)
        }
        precisionRow?.isHidden = s.availableComputePrecisions.count <= 1
        precisionInfoLabel.stringValue = "数值精度：" + s.computePrecisionDescription
        if inputKind == .captureCard {
            latencyPopup.selectItem(at: CaptureLowLatencyMode.allCases.firstIndex(of: s.captureLowLatencyMode) ?? 1)
            console30Popup.selectItem(at: Fake60OptimizationMode.allCases.firstIndex(of: s.fake60FPSOptimization) ?? 0)
        }
        resolutionTip.stringValue = s.interpolationBackend == .rifeCoreML || s.interpolationBackend == .rifeMetalFast
            ? "只降低运动估计预算，最终用源尺寸画面融合。此设置与输出分辨率、目标帧率独立。"
            : "系统模型按此尺寸推理后恢复输出尺寸。降低此值会减少计算量，也可能让中间帧偏软；这不是独立的内部光流精度控制。"

        resPopup.removeAllItems()
        resPopup.addItems(withTitles: s.availableFlowResolutions.map {
            s.interpolationBackend == .rifeMetalFast
                ? "推理预算 \($0.height)p · 原尺寸合成" : $0.title
        })
        resPopup.selectItem(at: s.availableFlowResolutions.firstIndex(of: s.interpolationFlowResolution) ?? 0)

        // 6. 画面保护
        sceneDetectionCheckbox.state = s.rifeTransitionDetection ? .on : .off
        sceneThresholdSlider.isEnabled = s.interpolationBackend == .rifeCoreML && s.rifeTransitionDetection
        sceneThresholdSlider.doubleValue = s.rifeSceneThreshold
        sceneThresholdLabel.stringValue = String(format: "%.0f%%", s.rifeSceneThreshold * 100)

        staticSkipCheckbox.state = s.rifeStaticFrameSkip ? .on : .off
        staticThresholdSlider.isEnabled = s.interpolationBackend == .rifeCoreML && s.rifeStaticFrameSkip
        staticThresholdSlider.doubleValue = s.rifeStaticThreshold
        staticThresholdLabel.stringValue = String(format: "%.1f%%", s.rifeStaticThreshold * 100)

        // 7. 隔行反交错
        if inputKind == .videoFile, let deintIdx = DeinterlaceMode.allCases.firstIndex(of: s.deinterlaceMode) {
            deinterlacePopup.selectItem(at: deintIdx)
        }

        // 8. HDR 转 SDR 色调映射
        if let hdrIdx = HDRToneMappingMode.allCases.firstIndex(of: s.hdrToneMapping) {
            hdrToneMappingPopup.selectItem(at: hdrIdx)
        }

        isUpdatingUI = false
    }

    private func updateBackendControls() {
        let isRIFE = settings.interpolationBackend == .rifeCoreML
        protectionCard?.isHidden = !isRIFE
        // The legacy block-matching parameters are not controls for the CoreML
        // weights or the system model. Do not offer knobs that cannot take effect.
        resPopup.isEnabled = true
        latencyPopup.isEnabled = true
        sceneDetectionCheckbox.isEnabled = isRIFE
        staticSkipCheckbox.isEnabled = isRIFE
        sceneThresholdSlider.isEnabled = isRIFE && sceneDetectionCheckbox.state == .on
        staticThresholdSlider.isEnabled = isRIFE && staticSkipCheckbox.state == .on
    }

    // MARK: - 事件监听与触发

    @objc private func handleSettingsChanged(_ note: Notification) {
        guard !isUpdatingUI else { return }
        loadFromSettings()
    }

    @objc private func onRateModeChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = rateModePopup.indexOfSelectedItem
        let s = settings
        switch idx {
        case 0: s.rifeRateMode = .off
        case 1: s.rifeRateMode = .x2
        case 2: s.rifeRateMode = .x3
        case 3: s.rifeRateMode = .x4
        case 4: s.rifeRateMode = .x5
        case 5: s.rifeRateMode = .fps60
        case 6: s.rifeRateMode = .fps120
        case 7: s.rifeRateMode = .customFps
        default: break
        }
        customFpsRow.isHidden = (idx != 7)
    }

    @objc private func onCustomFpsChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(customFpsSlider.doubleValue * 2) / 2
        customFpsLabel.stringValue = String(format: "%.1f FPS", val)
        settings.rifeCustomTargetFps = val
    }

    @objc private func onBackendChanged(_ sender: Any?) {
        guard !isUpdatingUI, InterpolationBackend.allCases.indices.contains(backendPopup.indexOfSelectedItem) else { return }
        settings.interpolationBackend = InterpolationBackend.allCases[backendPopup.indexOfSelectedItem]
    }

    @objc private func onConsole30Changed(_ sender: Any?) {
        guard !isUpdatingUI, inputKind == .captureCard,
              Fake60OptimizationMode.allCases.indices.contains(console30Popup.indexOfSelectedItem) else { return }
        settings.fake60FPSOptimization = Fake60OptimizationMode.allCases[console30Popup.indexOfSelectedItem]
        if settings.fake60FPSOptimization == .on { settings.rifeRateMode = .fps60 }
    }

    @objc private func onOpenCaptureDevice(_ sender: Any?) { onOpenCaptureDevice?() }

    @objc private func onLatencyChanged(_ sender: Any?) {
        guard !isUpdatingUI, CaptureLowLatencyMode.allCases.indices.contains(latencyPopup.indexOfSelectedItem) else { return }
        settings.captureLowLatencyMode = CaptureLowLatencyMode.allCases[latencyPopup.indexOfSelectedItem]
    }

    @objc private func onModelChanged(_ sender: Any?) {
        guard !isUpdatingUI, settings.interpolationBackend == .rifeCoreML else { return }
        let models = RIFEModelChoice.allCases
        let index = modelPopup.indexOfSelectedItem
        guard models.indices.contains(index) else { return }
        settings.rifeModel = models[index]
    }

    private func updateModelTip(_ model: RIFEModelChoice) {
        if settings.interpolationBackend == .rifeMetalFast {
            modelTipBadge.configure(
                text: "RifeMetal Fast：RIFE 4.25 FP16。下方只控制内部光流推理预算，输入原图保持源尺寸；中间帧通过放大的光流在原图上变形融合，避免低分辨率中间帧直接放大造成清晰度交替。支持 SDR 2X，失败回退 Core ML RIFE。",
                theme: .cyan)
        } else if settings.interpolationBackend == .metalFX {
            modelTipBadge.configure(
                text: "MetalFX 实验性补帧：由画面估算光流，深度采用平面近似，可能重影；尚未验证性能。仅支持 SDR 2X，需 macOS 26 及支持的 GPU；失败使用 RIFE 回退。数值精度由系统管理。",
                theme: .cyan)
        } else if settings.interpolationBackend == .appleVideoToolbox {
            modelTipBadge.configure(
                text: "Apple 系统模型：推理分辨率独立可选，原始帧保持源画质；中间帧直接使用系统模型输出，不用源图替代。低于源尺寸推理时，中间帧清晰度可能下降；需要原图运动融合时可选 RIFE 或 RifeMetal Fast。系统不开放数值精度控制。支持2X；不支持时使用RIFE回退配置。",
                theme: .cyan)
        } else {
            modelTipBadge.configure(
                text: "RIFE模型：光流分辨率选择对应的实际模型包；输出仍按源尺寸融合。当前包仅提供FP16。较高分辨率不保证实时帧率。",
                theme: .cyan)
        }
    }

    @objc private func onPrecisionChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let choices = settings.availableComputePrecisions
        guard choices.indices.contains(precisionPopup.indexOfSelectedItem) else { return }
        settings.rifePrecision = choices[precisionPopup.indexOfSelectedItem]
    }

    @objc private func onResolutionChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let choices = settings.availableFlowResolutions
        guard choices.indices.contains(resPopup.indexOfSelectedItem) else { return }
        settings.interpolationFlowResolution = choices[resPopup.indexOfSelectedItem]
    }

    @objc private func onSceneDetectionToggled(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let on = (sceneDetectionCheckbox.state == .on)
        settings.rifeTransitionDetection = on
        sceneThresholdSlider.isEnabled = on
    }

    @objc private func onSceneThresholdChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(sceneThresholdSlider.doubleValue * 20) / 20
        sceneThresholdLabel.stringValue = String(format: "%.0f%%", val * 100)
        settings.rifeSceneThreshold = val
    }

    @objc private func onStaticSkipToggled(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let on = (staticSkipCheckbox.state == .on)
        settings.rifeStaticFrameSkip = on
        staticThresholdSlider.isEnabled = on
    }

    @objc private func onStaticThresholdChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(staticThresholdSlider.doubleValue * 200) / 200
        staticThresholdLabel.stringValue = String(format: "%.1f%%", val * 100)
        settings.rifeStaticThreshold = val
    }

    @objc private func onDeinterlaceModeChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = deinterlacePopup.indexOfSelectedItem
        if idx >= 0 && idx < DeinterlaceMode.allCases.count {
            settings.deinterlaceMode = DeinterlaceMode.allCases[idx]
        }
    }

    @objc private func onHDRToneMappingChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = hdrToneMappingPopup.indexOfSelectedItem
        if idx >= 0 && idx < HDRToneMappingMode.allCases.count {
            let mode = HDRToneMappingMode.allCases[idx]
            settings.hdrToneMapping = mode
            statusIndicator.stringValue = "● 已切换 HDR 转 SDR: \(mode.title)"
        }
    }


    @objc private func onResetDefaults(_ sender: Any?) {
        settings.resetRIFEToDefaults()
        loadFromSettings()
    }

    @objc private func onDone(_ sender: Any?) {
        window?.orderOut(nil)
    }
}

