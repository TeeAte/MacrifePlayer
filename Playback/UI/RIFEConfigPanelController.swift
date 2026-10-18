// RIFEConfigPanelController.swift
// Macrife Player · 视频补帧详细配置与模型专属高级定制面板
//
// 架构设计：
// 1. 采用坚实深色高对比底板（Solid High-Contrast Dark Theme），彻底解决半透明磨砂
//    在纯黑视频/桌面背景下文字变暗、发灰模糊、对比度缺失的问题；
// 2. 独立立体浮凸卡片（Solid Card Layer），搭配 1px 高光描边与微投影，清晰分区；
// 3. 所有标签文字、数值指示器、复选框均升级为纯白与高饱和科技青色，对比鲜明锐利；
// 4. 为模型架构定制独立的高对比 Info Badge 提示框（琥珀金/翡翠绿/冰晶蓝）；
// 5. 将所有补帧模型选择收拢至本面板，一站式调控内核与精度；
// 6. 针对 RIFE、FLAVR、DistilDRBA 三套不同算法内核动态展示专属参数；
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
        case amber   // 动漫/DistilDRBA 专属
        case emerald // FLAVR 3D-CNN / ANE 专属
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
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
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
        case .amber:
            layer?.backgroundColor = NSColor(red: 0.28, green: 0.17, blue: 0.06, alpha: 0.95).cgColor
            layer?.borderColor = NSColor(red: 0.96, green: 0.65, blue: 0.18, alpha: 0.60).cgColor
            label.textColor = NSColor(red: 1.0, green: 0.88, blue: 0.45, alpha: 1.0)
        case .emerald:
            layer?.backgroundColor = NSColor(red: 0.07, green: 0.24, blue: 0.13, alpha: 0.95).cgColor
            layer?.borderColor = NSColor(red: 0.25, green: 0.86, blue: 0.45, alpha: 0.60).cgColor
            label.textColor = NSColor(red: 0.45, green: 0.98, blue: 0.65, alpha: 1.0)
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

// MARK: - 主控制器
final class RIFEConfigPanelController: NSWindowController {

    static let shared = RIFEConfigPanelController()

    // MARK: - 控件

    // 1. 目标速率与帧率
    private let rateModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let customFpsSlider = NSSlider(value: 60, minValue: 24, maxValue: 240, target: nil, action: nil)
    private let customFpsLabel = NSTextField(labelWithString: "60.0 FPS")
    private let customFpsRow = NSStackView()

    // 2. AI 模型与计算精度
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let precisionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelTipBadge = PanelInfoBadgeView()

    // 3. 模型专属高级定制容器
    private var customCardContainer: NSView?
    private let customCardTitleLabel = NSTextField(labelWithString: "模型专属高级定制")

    // 3.1 RIFE 专属控件
    private let rifeCustomStack = NSStackView()
    private let rifeSmoothSlider = NSSlider(value: 1.0, minValue: 0.5, maxValue: 2.0, target: nil, action: nil)
    private let rifeSmoothLabel = NSTextField(labelWithString: "1.00x")
    private let rifeLargeMotionCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let rifePyramidPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // 3.2 FLAVR 专属控件
    private let flavrCustomStack = NSStackView()
    private let flavrKernelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let flavrBackendPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let flavrGuardBadge = PanelInfoBadgeView()

    // 3.3 DistilDRBA 专属控件
    private let drbaCustomStack = NSStackView()
    private let drbaCadencePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let drbaLineSlider = NSSlider(value: 0.85, minValue: 0.0, maxValue: 1.0, target: nil, action: nil)
    private let drbaLineLabel = NSTextField(labelWithString: "85%")
    private let drbaExaggeratedCheck = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    // 4. 推理缩放与分辨率
    private let resPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scaleSlider = NSSlider(value: 1.0, minValue: 0.25, maxValue: 2.0, target: nil, action: nil)
    private let scaleLabel = NSTextField(labelWithString: "1.00x (原生)")

    // 5. 调度与性能
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let workerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let queueDepthPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    // 6. 画面保护与节能
    private let sceneDetectionCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let sceneThresholdSlider = NSSlider(value: 0.30, minValue: 0.05, maxValue: 0.80, target: nil, action: nil)
    private let sceneThresholdLabel = NSTextField(labelWithString: "30%")

    private let staticSkipCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let staticThresholdSlider = NSSlider(value: 0.02, minValue: 0.005, maxValue: 0.10, target: nil, action: nil)
    private let staticThresholdLabel = NSTextField(labelWithString: "2.0%")

    // 7. 广播级隔行反交错 (MTS / 1080 50i/60i)
    private let deinterlacePopup = NSPopUpButton(frame: .zero, pullsDown: false)


    // 底部工具条
    private let statusIndicator = NSTextField(labelWithString: "● 所有参数已实时生效")
    private let resetButton = NSButton(title: "恢复默认", target: nil, action: nil)
    private let doneButton = NSButton(title: "完成", target: nil, action: nil)

    private var isUpdatingUI = false

    // MARK: - 初始化

    private init() {
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
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 呈现与定位

    func show(relativeTo parentWindow: NSWindow? = nil) {
        guard let window = self.window else { return }
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

        let scrollDocView = NSView()
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
        let modelCard = makeCardView(title: "AI 补帧模型架构与计算精度")
        let modelStack = NSStackView()
        modelStack.orientation = .vertical
        modelStack.alignment = .leading
        modelStack.spacing = 8

        modelPopup.addItems(withTitles: [
            "RIFE v4.26 (新一代高画质 · 通用物理光流)",
            "RIFE v4.26 Heavy (大位移重度光流 · 动作大片)",
            "RIFE v4.25 (高画质经典标准模型)",
            "RIFE v4.25 Lite (超轻量 · 极速低功耗)",
            "FLAVR 2X (3D 时空卷积 · 无光流 · ANE 硬件加速)",
            "FLAVR-Fast (极速纯 ANE · 低能耗静音)",
            "DistilDRBA (动漫二次元专属 · 距离比例调整)"
        ])
        modelPopup.target = self
        modelPopup.action = #selector(onModelChanged(_:))
        modelStack.addArrangedSubview(makeRow(label: "模型内核:", control: modelPopup))

        precisionPopup.addItems(withTitles: [
            "FP16 半精度 (推荐 · Metal & Neural Engine 硬件加速)",
            "FP32 单精度 (完整浮点精度)"
        ])
        precisionPopup.target = self
        precisionPopup.action = #selector(onPrecisionChanged(_:))
        modelStack.addArrangedSubview(makeRow(label: "计算精度:", control: precisionPopup))

        // 模型专属高对比提示徽章
        modelStack.addArrangedSubview(modelTipBadge)
        modelTipBadge.translatesAutoresizingMaskIntoConstraints = false
        modelTipBadge.widthAnchor.constraint(equalTo: modelStack.widthAnchor).isActive = true

        modelCard.contentView.addSubview(modelStack)
        modelStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(modelStack, in: modelCard.contentView)
        rootStack.addArrangedSubview(modelCard.container)
        modelCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        // 3. 卡片：模型专属高级定制设置（动态联动）
        setupCustomSettingsCard(in: rootStack)

        // 4. 卡片：推理分辨率与画面缩放
        let resCard = makeCardView(title: "推理分辨率与画面缩放")
        let resStack = NSStackView()
        resStack.orientation = .vertical
        resStack.alignment = .leading
        resStack.spacing = 7

        resPopup.addItems(withTitles: [
            "甜点 (Sweet 0.5x · 极速流畅)",
            "标准 (Normal 1.0x · 原生画质)",
            "高质 (Quality 1.5x · 细节丰富)",
            "极致 (Top 2.0x · 超高精细度)"
        ])
        resPopup.target = self
        resPopup.action = #selector(onResolutionChanged(_:))
        resStack.addArrangedSubview(makeRow(label: "预设档位:", control: resPopup))

        scaleSlider.target = self
        scaleSlider.action = #selector(onScaleFactorChanged(_:))
        scaleSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        scaleLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        scaleLabel.textColor = NSColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0)
        let scaleRow = makeRow(label: "细粒度缩放:", control: scaleSlider)
        scaleRow.addArrangedSubview(scaleLabel)
        resStack.addArrangedSubview(scaleRow)

        resCard.contentView.addSubview(resStack)
        resStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(resStack, in: resCard.contentView)
        rootStack.addArrangedSubview(resCard.container)
        resCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        // 5. 卡片：调度策略与并发核心
        let perfCard = makeCardView(title: "调度策略与并发核心")
        let perfStack = NSStackView()
        perfStack.orientation = .vertical
        perfStack.alignment = .leading
        perfStack.spacing = 7

        qualityPopup.addItems(withTitles: [
            "稳定平滑 (推荐 · 帧间隔均匀抗抖动)",
            "低延迟模式 (快速响应 · 适合交互预览)",
            "极致画质模式 (最大吞吐保障)"
        ])
        qualityPopup.target = self
        qualityPopup.action = #selector(onQualityChanged(_:))
        perfStack.addArrangedSubview(makeRow(label: "调度模式:", control: qualityPopup))

        workerPopup.addItems(withTitles: [
            "4 核心 (轻载 · 省电静音)",
            "6 核心 (平衡推荐)",
            "8 核心 (满速高刷)",
            "10 核心 (高负载)",
            "12 核心 (极致吞吐)"
        ])
        workerPopup.target = self
        workerPopup.action = #selector(onWorkerChanged(_:))
        perfStack.addArrangedSubview(makeRow(label: "Worker 核心:", control: workerPopup))

        queueDepthPopup.addItems(withTitles: [
            "2 帧 (超低延迟)",
            "4 帧 (标准平衡)",
            "8 帧 (高抗抖动)",
            "12 帧 (超深缓冲)"
        ])
        queueDepthPopup.target = self
        queueDepthPopup.action = #selector(onQueueDepthChanged(_:))
        perfStack.addArrangedSubview(makeRow(label: "预缓冲队列:", control: queueDepthPopup))

        perfCard.contentView.addSubview(perfStack)
        perfStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(perfStack, in: perfCard.contentView)
        rootStack.addArrangedSubview(perfCard.container)
        perfCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

        // 6. 卡片：智能保护与节能
        let protCard = makeCardView(title: "智能保护与节能")
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

        // 隔行反交错 (针对摄像机 MTS / 50i / 60i 广播级视频)
        deinterlacePopup.addItems(withTitles: DeinterlaceMode.allCases.map { $0.title })
        deinterlacePopup.target = self
        deinterlacePopup.action = #selector(onDeinterlaceModeChanged(_:))
        let deintRow = makeRow(label: "隔行反交错:", control: deinterlacePopup)
        protStack.addArrangedSubview(deintRow)

        let deintTip = NSTextField(labelWithString: "💡 识别 .mts/.m2ts 50i/60i 隔行视频，自适应双场拆解消除横向拉丝，直接输出 50/60 FPS。")
        deintTip.font = .systemFont(ofSize: 11, weight: .regular)
        deintTip.textColor = NSColor(white: 0.65, alpha: 1.0)
        protStack.addArrangedSubview(deintTip)

        protCard.contentView.addSubview(protStack)
        protStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(protStack, in: protCard.contentView)
        rootStack.addArrangedSubview(protCard.container)
        protCard.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true

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

    // MARK: - 构建模型专属高级定制卡片

    private func setupCustomSettingsCard(in rootStack: NSStackView) {
        let card = makeCardView(title: "模型专属高级定制")
        customCardContainer = card.container

        let parentStack = NSStackView()
        parentStack.orientation = .vertical
        parentStack.alignment = .leading
        parentStack.spacing = 8
        card.contentView.addSubview(parentStack)
        parentStack.translatesAutoresizingMaskIntoConstraints = false
        pinToEdges(parentStack, in: card.contentView)

        // 1. RIFE 专属布局
        rifeCustomStack.orientation = .vertical
        rifeCustomStack.alignment = .leading
        rifeCustomStack.spacing = 7

        rifeSmoothSlider.target = self
        rifeSmoothSlider.action = #selector(onRifeSmoothChanged(_:))
        rifeSmoothSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        rifeSmoothLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        rifeSmoothLabel.textColor = NSColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0)
        let smoothRow = makeRow(label: "光流平滑度:", control: rifeSmoothSlider)
        smoothRow.addArrangedSubview(rifeSmoothLabel)
        rifeCustomStack.addArrangedSubview(smoothRow)

        configureCheckbox(rifeLargeMotionCheck, title: "大位移剧烈运动补偿 (动作大片强化)")
        rifeLargeMotionCheck.target = self
        rifeLargeMotionCheck.action = #selector(onRifeLargeMotionChanged(_:))
        rifeCustomStack.addArrangedSubview(rifeLargeMotionCheck)

        rifePyramidPopup.addItems(withTitles: [
            "1 阶段 (快速 · 适合低分辨率)",
            "2 阶段 (均衡 · 1080p 推荐)",
            "3 阶段 (精细 · 4K/2K 超高清首选)"
        ])
        rifePyramidPopup.target = self
        rifePyramidPopup.action = #selector(onRifePyramidChanged(_:))
        rifeCustomStack.addArrangedSubview(makeRow(label: "金字塔阶段:", control: rifePyramidPopup))

        parentStack.addArrangedSubview(rifeCustomStack)

        // 2. FLAVR 专属布局
        flavrCustomStack.orientation = .vertical
        flavrCustomStack.alignment = .leading
        flavrCustomStack.spacing = 7

        flavrKernelPopup.removeAllItems()
        for k in FLAVRKernelMode.allCases {
            flavrKernelPopup.addItem(withTitle: k.title)
        }
        flavrKernelPopup.target = self
        flavrKernelPopup.action = #selector(onFlavrKernelChanged(_:))
        flavrCustomStack.addArrangedSubview(makeRow(label: "时空卷积核:", control: flavrKernelPopup))

        flavrBackendPopup.removeAllItems()
        for b in FLAVRBackend.allCases {
            flavrBackendPopup.addItem(withTitle: b.title)
        }
        flavrBackendPopup.target = self
        flavrBackendPopup.action = #selector(onFlavrBackendChanged(_:))
        flavrCustomStack.addArrangedSubview(makeRow(label: "硬件加速器:", control: flavrBackendPopup))

        flavrGuardBadge.configure(
            text: "🛡️ 纯 3D 时空卷积（Flow-Agnostic · 无光流），水波、半透明、粒子反光天然抗撕裂。",
            theme: .emerald
        )
        flavrCustomStack.addArrangedSubview(flavrGuardBadge)
        flavrGuardBadge.translatesAutoresizingMaskIntoConstraints = false
        flavrGuardBadge.widthAnchor.constraint(equalTo: flavrCustomStack.widthAnchor).isActive = true

        parentStack.addArrangedSubview(flavrCustomStack)

        // 3. DistilDRBA 专属布局
        drbaCustomStack.orientation = .vertical
        drbaCustomStack.alignment = .leading
        drbaCustomStack.spacing = 7

        drbaCadencePopup.removeAllItems()
        for c in DRBACadence.allCases {
            drbaCadencePopup.addItem(withTitle: c.title)
        }
        drbaCadencePopup.target = self
        drbaCadencePopup.action = #selector(onDrbaCadenceChanged(_:))
        drbaCustomStack.addArrangedSubview(makeRow(label: "抽帧检测:", control: drbaCadencePopup))

        drbaLineSlider.target = self
        drbaLineSlider.action = #selector(onDrbaLineChanged(_:))
        drbaLineSlider.widthAnchor.constraint(equalToConstant: 180).isActive = true
        drbaLineLabel.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        drbaLineLabel.textColor = NSColor(red: 0.35, green: 0.82, blue: 1.0, alpha: 1.0)
        let lineRow = makeRow(label: "线稿保真度:", control: drbaLineSlider)
        lineRow.addArrangedSubview(drbaLineLabel)
        drbaCustomStack.addArrangedSubview(lineRow)

        configureCheckbox(drbaExaggeratedCheck, title: "动漫夸张瞬移与表情变形保护")
        drbaExaggeratedCheck.target = self
        drbaExaggeratedCheck.action = #selector(onDrbaExaggeratedChanged(_:))
        drbaCustomStack.addArrangedSubview(drbaExaggeratedCheck)

        parentStack.addArrangedSubview(drbaCustomStack)

        rootStack.addArrangedSubview(card.container)
        card.container.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -36).isActive = true
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
        isUpdatingUI = true
        let s = PlaybackSettings.shared

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

        // 2. 模型与精度
        switch s.rifeModel {
        case .v426:      modelPopup.selectItem(at: 0)
        case .heavy426:  modelPopup.selectItem(at: 1)
        case .full425:   modelPopup.selectItem(at: 2)
        case .lite425:   modelPopup.selectItem(at: 3)
        case .flavr2x:   modelPopup.selectItem(at: 4)
        case .flavrFast: modelPopup.selectItem(at: 5)
        case .distilDRBA: modelPopup.selectItem(at: 6)
        }
        updateModelTip(s.rifeModel)
        updateCustomCardVisibility(for: s.rifeModel)
        precisionPopup.selectItem(at: s.rifePrecision == .fp16 ? 0 : 1)

        // 3. 模型专属参数
        // RIFE
        rifeSmoothSlider.doubleValue = s.rifeFlowSmoothness
        updateRifeSmoothLabel(s.rifeFlowSmoothness)
        rifeLargeMotionCheck.state = s.rifeLargeMotionAssist ? .on : .off
        rifePyramidPopup.selectItem(at: max(0, min(2, s.rifePyramidStages - 1)))

        // FLAVR
        if let idx = FLAVRKernelMode.allCases.firstIndex(of: s.flavrKernelMode) {
            flavrKernelPopup.selectItem(at: idx)
        }
        if let idx = FLAVRBackend.allCases.firstIndex(of: s.flavrBackend) {
            flavrBackendPopup.selectItem(at: idx)
        }

        // DRBA
        if let idx = DRBACadence.allCases.firstIndex(of: s.drbaCadence) {
            drbaCadencePopup.selectItem(at: idx)
        }
        drbaLineSlider.doubleValue = s.drbaLineArtPreservation
        updateDrbaLineLabel(s.drbaLineArtPreservation)
        drbaExaggeratedCheck.state = s.drbaExaggeratedMotionGuard ? .on : .off

        // 4. 分辨率与缩放
        switch s.rifeResolution {
        case .sweet:   resPopup.selectItem(at: 0)
        case .normal:  resPopup.selectItem(at: 1)
        case .quality: resPopup.selectItem(at: 2)
        case .top:     resPopup.selectItem(at: 3)
        }
        scaleSlider.doubleValue = s.rifeScaleFactor
        updateScaleLabel(s.rifeScaleFactor)

        // 5. 调度与核心
        switch s.rifeQualityMode {
        case .stable:      qualityPopup.selectItem(at: 0)
        case .lowLatency:  qualityPopup.selectItem(at: 1)
        case .highQuality: qualityPopup.selectItem(at: 2)
        }

        switch s.rifeWorkerCount {
        case 4:  workerPopup.selectItem(at: 0)
        case 6:  workerPopup.selectItem(at: 1)
        case 8:  workerPopup.selectItem(at: 2)
        case 10: workerPopup.selectItem(at: 3)
        case 12: workerPopup.selectItem(at: 4)
        default: workerPopup.selectItem(at: 2)
        }

        switch s.rifeQueueDepth {
        case 2:  queueDepthPopup.selectItem(at: 0)
        case 4:  queueDepthPopup.selectItem(at: 1)
        case 8:  queueDepthPopup.selectItem(at: 2)
        case 12: queueDepthPopup.selectItem(at: 3)
        default: queueDepthPopup.selectItem(at: 1)
        }

        // 6. 画面保护
        sceneDetectionCheckbox.state = s.rifeTransitionDetection ? .on : .off
        sceneThresholdSlider.isEnabled = s.rifeTransitionDetection
        sceneThresholdSlider.doubleValue = s.rifeSceneThreshold
        sceneThresholdLabel.stringValue = String(format: "%.0f%%", s.rifeSceneThreshold * 100)

        staticSkipCheckbox.state = s.rifeStaticFrameSkip ? .on : .off
        staticThresholdSlider.isEnabled = s.rifeStaticFrameSkip
        staticThresholdSlider.doubleValue = s.rifeStaticThreshold
        staticThresholdLabel.stringValue = String(format: "%.1f%%", s.rifeStaticThreshold * 100)

        // 7. 隔行反交错
        if let deintIdx = DeinterlaceMode.allCases.firstIndex(of: s.deinterlaceMode) {
            deinterlacePopup.selectItem(at: deintIdx)
        }


        isUpdatingUI = false
    }

    private func updateCustomCardVisibility(for model: RIFEModelChoice) {
        rifeCustomStack.isHidden = (model.family != .rife)
        flavrCustomStack.isHidden = (model.family != .flavr)
        drbaCustomStack.isHidden = (model.family != .drba)
    }

    private func updateScaleLabel(_ val: Double) {
        let tag: String
        if abs(val - 0.5) < 0.04 { tag = "(甜点)" }
        else if abs(val - 1.0) < 0.04 { tag = "(原生)" }
        else if abs(val - 1.5) < 0.04 { tag = "(高画质)" }
        else if abs(val - 2.0) < 0.04 { tag = "(极致)" }
        else { tag = "" }
        scaleLabel.stringValue = String(format: "%.2fx %@", val, tag)
    }

    private func updateRifeSmoothLabel(_ val: Double) {
        rifeSmoothLabel.stringValue = String(format: "%.2fx", val)
    }

    private func updateDrbaLineLabel(_ val: Double) {
        drbaLineLabel.stringValue = String(format: "%.0f%%", val * 100)
    }

    // MARK: - 事件监听与触发

    @objc private func handleSettingsChanged(_ note: Notification) {
        guard !isUpdatingUI else { return }
        loadFromSettings()
    }

    @objc private func onRateModeChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = rateModePopup.indexOfSelectedItem
        let s = PlaybackSettings.shared
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
        PlaybackSettings.shared.rifeCustomTargetFps = val
    }

    @objc private func onModelChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let s = PlaybackSettings.shared
        switch modelPopup.indexOfSelectedItem {
        case 0: s.rifeModel = .v426
        case 1: s.rifeModel = .heavy426
        case 2: s.rifeModel = .full425
        case 3: s.rifeModel = .lite425
        case 4: s.rifeModel = .flavr2x
        case 5: s.rifeModel = .flavrFast
        case 6: s.rifeModel = .distilDRBA
        default: break
        }
        updateModelTip(s.rifeModel)
        updateCustomCardVisibility(for: s.rifeModel)
    }

    private func updateModelTip(_ model: RIFEModelChoice) {
        switch model {
        case .flavr2x:
            modelTipBadge.configure(
                text: "💡 FLAVR 2X：采用 3D 时空卷积抛弃光流，100% 满血由 Apple Neural Engine 硬件驱动，零 CPU/GPU 采样回退，水波/烟雾/透明反光极佳。",
                theme: .emerald
            )
        case .flavrFast:
            modelTipBadge.configure(
                text: "💡 FLAVR-Fast：超轻量 3D-CNN，极低算力开销，纯 ANE 静音低能耗，MacBook 电池播放首选。",
                theme: .emerald
            )
        case .distilDRBA:
            modelTipBadge.configure(
                text: "💡 DistilDRBA：专攻动漫手绘有限动画（一拍二/一拍三），距离比例图锁定人物五官与线稿，杜绝拉扯融化。",
                theme: .amber
            )
        case .v426, .heavy426:
            modelTipBadge.configure(
                text: "💡 RIFE v4.26：基于残差光流金字塔（IFNet），擅长物理世界连续运动与实拍电影大动作。",
                theme: .cyan
            )
        case .full425, .lite425:
            modelTipBadge.configure(
                text: "💡 RIFE v4.25：经典稳定光流架构，兼顾通用兼容性。",
                theme: .neutral
            )
        }
    }

    // RIFE 专属事件
    @objc private func onRifeSmoothChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(rifeSmoothSlider.doubleValue * 20) / 20
        updateRifeSmoothLabel(val)
        PlaybackSettings.shared.rifeFlowSmoothness = val
    }

    @objc private func onRifeLargeMotionChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        PlaybackSettings.shared.rifeLargeMotionAssist = (rifeLargeMotionCheck.state == .on)
    }

    @objc private func onRifePyramidChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        PlaybackSettings.shared.rifePyramidStages = rifePyramidPopup.indexOfSelectedItem + 1
    }

    // FLAVR 专属事件
    @objc private func onFlavrKernelChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = flavrKernelPopup.indexOfSelectedItem
        if idx >= 0 && idx < FLAVRKernelMode.allCases.count {
            PlaybackSettings.shared.flavrKernelMode = FLAVRKernelMode.allCases[idx]
        }
    }

    @objc private func onFlavrBackendChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = flavrBackendPopup.indexOfSelectedItem
        if idx >= 0 && idx < FLAVRBackend.allCases.count {
            PlaybackSettings.shared.flavrBackend = FLAVRBackend.allCases[idx]
        }
    }

    // DistilDRBA 专属事件
    @objc private func onDrbaCadenceChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = drbaCadencePopup.indexOfSelectedItem
        if idx >= 0 && idx < DRBACadence.allCases.count {
            PlaybackSettings.shared.drbaCadence = DRBACadence.allCases[idx]
        }
    }

    @objc private func onDrbaLineChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(drbaLineSlider.doubleValue * 20) / 20
        updateDrbaLineLabel(val)
        PlaybackSettings.shared.drbaLineArtPreservation = val
    }

    @objc private func onDrbaExaggeratedChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        PlaybackSettings.shared.drbaExaggeratedMotionGuard = (drbaExaggeratedCheck.state == .on)
    }

    @objc private func onPrecisionChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        PlaybackSettings.shared.rifePrecision = precisionPopup.indexOfSelectedItem == 0 ? .fp16 : .fp32
    }

    @objc private func onResolutionChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let s = PlaybackSettings.shared
        switch resPopup.indexOfSelectedItem {
        case 0:
            s.rifeResolution = .sweet
            s.rifeScaleFactor = 0.5
        case 1:
            s.rifeResolution = .normal
            s.rifeScaleFactor = 1.0
        case 2:
            s.rifeResolution = .quality
            s.rifeScaleFactor = 1.5
        case 3:
            s.rifeResolution = .top
            s.rifeScaleFactor = 2.0
        default: break
        }
        scaleSlider.doubleValue = s.rifeScaleFactor
        updateScaleLabel(s.rifeScaleFactor)
    }

    @objc private func onScaleFactorChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(scaleSlider.doubleValue * 20) / 20
        updateScaleLabel(val)
        PlaybackSettings.shared.rifeScaleFactor = val
    }

    @objc private func onQualityChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let s = PlaybackSettings.shared
        switch qualityPopup.indexOfSelectedItem {
        case 0: s.rifeQualityMode = .stable
        case 1: s.rifeQualityMode = .lowLatency
        case 2: s.rifeQualityMode = .highQuality
        default: break
        }
    }

    @objc private func onWorkerChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = workerPopup.indexOfSelectedItem
        if idx >= 0 && idx < PlaybackSettings.rifeWorkerChoices.count {
            PlaybackSettings.shared.rifeWorkerCount = PlaybackSettings.rifeWorkerChoices[idx]
        }
    }

    @objc private func onQueueDepthChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let choices = [2, 4, 8, 12]
        let idx = queueDepthPopup.indexOfSelectedItem
        if idx >= 0 && idx < choices.count {
            PlaybackSettings.shared.rifeQueueDepth = choices[idx]
        }
    }

    @objc private func onSceneDetectionToggled(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let on = (sceneDetectionCheckbox.state == .on)
        PlaybackSettings.shared.rifeTransitionDetection = on
        sceneThresholdSlider.isEnabled = on
    }

    @objc private func onSceneThresholdChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(sceneThresholdSlider.doubleValue * 20) / 20
        sceneThresholdLabel.stringValue = String(format: "%.0f%%", val * 100)
        PlaybackSettings.shared.rifeSceneThreshold = val
    }

    @objc private func onStaticSkipToggled(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let on = (staticSkipCheckbox.state == .on)
        PlaybackSettings.shared.rifeStaticFrameSkip = on
        staticThresholdSlider.isEnabled = on
    }

    @objc private func onStaticThresholdChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let val = round(staticThresholdSlider.doubleValue * 200) / 200
        staticThresholdLabel.stringValue = String(format: "%.1f%%", val * 100)
        PlaybackSettings.shared.rifeStaticThreshold = val
    }

    @objc private func onDeinterlaceModeChanged(_ sender: Any?) {
        guard !isUpdatingUI else { return }
        let idx = deinterlacePopup.indexOfSelectedItem
        if idx >= 0 && idx < DeinterlaceMode.allCases.count {
            PlaybackSettings.shared.deinterlaceMode = DeinterlaceMode.allCases[idx]
        }
    }


    @objc private func onResetDefaults(_ sender: Any?) {
        PlaybackSettings.shared.resetRIFEToDefaults()
        loadFromSettings()
    }

    @objc private func onDone(_ sender: Any?) {
        window?.orderOut(nil)
    }
}

