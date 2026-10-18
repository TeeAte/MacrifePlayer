//  ControlOverlayView.swift
//  MetalPlayer 重建工程 —— 底部控制条（Phase 2）
//
//  原版（`MetalPlayer/UI/ControlOverlayView.swift` 骨架）观测到的成员：
//
//      成员方法（签名来自 demangled 符号）
//        setupBlur()                铺毛玻璃背景
//        setupControls()            建控件
//        setupSymbolImages()        填 SF Symbol 图标
//        setupActions()             接动作
//        showRIFEMenu()             弹出「补帧」档位菜单
//        showMetalFXMenu()          弹出「MetalFX」档位菜单
//        selectRIFEMenuItem(NSMenuItem)
//        selectMetalFXMenuItem(NSMenuItem)
//        setTime(current:duration:)
//        updateTrackingAreas()
//
//  反射段（`__swift5_reflstr`）另外给出了它的**控件名与回调名**，逐个都用上了：
//
//      playButton  backButton  forwardButton  playlistButton  fullscreenButton
//      rifeButton  metalFXButton  anime4KButton
//      progressSlider  timeLabel  volumeIcon  volumeSlider
//      decodePathPill  decodePathTitle  decodePathLabel
//      blurView  overlayView
//      onPlayPause  onSeek  onSeekRelative  onVolumeChanged  onTogglePlaylist
//      onFullscreen  onToggleRIFE  onSelectRIFERateMode
//      onSelectMetalFXTargetMode  onCycleMetalFXTarget  onSelectAnime4K
//      onDecodePathChanged  onNotice
//
//  也就是说这条控制条上有**四个档位按钮**（补帧 / MetalFX / Anime4K / 解码方式），
//  这与 REBUILD-PLAN.md 里从截图读到的「三个『关闭』按钮」对上了 ——
//  文案表里 `rife_off` / `metalfx_off` / `anime4k_off` 三条都是「XXX 关闭」，
//  再加一个 `decode_hw` / `decode_sw` 的解码按钮。
//
//  ⚠️ 后端接入状态（Phase 2 只是 UI 面对齐，四个按钮的真实效果分属后续阶段）：
//      · 补帧      → Phase 4（RIFE）
//      · MetalFX   → Phase 5
//      · Anime4K   → Phase 5
//      · 解码方式  → 硬解（VideoToolbox）尚未实现，当前只有软解
//    这四个的**状态、持久化、回显**在 Phase 2 是真的；点击后如果后端没接，
//    会通过 onNotice 弹一条如实的状态提示，不会假装已经切过去了。

import Foundation
import AppKit

// MARK: - 控制条上的胶囊按钮

/// 控制条上的小按钮：无边框 + 半透明圆角底。
///
/// 为什么要自定义而不是用 `NSButton` 的现成 bezelStyle：
/// 这条控制条是压在画面上的浮层，系统默认按钮的底色与边框在视频画面上很不协调。
/// 原版的按钮看起来也是这样（截图里是半透明胶囊）。
final class OverlayPillButton: NSButton {

    /// 静止时的底色透明度。
    var idleAlpha: CGFloat = 0.16
    /// 悬停 / 按下时抬高一点，给出反馈。
    var hoverAlpha: CGFloat = 0.26

    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: idleAlpha).cgColor
        contentTintColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        font = .systemFont(ofSize: 11.5, weight: .medium)
        translatesAutoresizingMaskIntoConstraints = false
        // 让文字居中且不贴边：NSButton 默认会留一点，这里统一由外部约束给宽度。
        alignment = .center
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: hoverAlpha).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: idleAlpha).cgColor
    }

    /// 只显示图标时的尺寸更紧凑。
    var usesSymbolOnly: Bool {
        get { imagePosition == .imageOnly }
        set { imagePosition = newValue ? .imageOnly : .imageLeading }
    }

    /// 右键菜单/动作回调
    var onRightMouseDown: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        if let onRightMouseDown {
            onRightMouseDown()
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

// MARK: - 控制条

final class ControlOverlayView: NSView {

    // MARK: 对外回调（名字取自反射池）

    var onPlayPause: (() -> Void)?
    /// 松手后的精确定位，单位秒。
    var onSeek: ((Double) -> Void)?
    /// 拖动中的限流预览，单位秒。
    var onSeekPreview: ((Double) -> Void)?
    /// 快退 / 快进（参数是秒，负数为后退）。
    var onSeekRelative: ((Double) -> Void)?
    var onVolumeChanged: ((Float) -> Void)?
    var onTogglePlaylist: (() -> Void)?
    var onFullscreen: (() -> Void)?
    /// 点「补帧」按钮本体（循环下一档）。
    var onToggleRIFE: (() -> Void)?
    var onSelectRIFERateMode: ((RIFERateMode) -> Void)?
    /// 打开 RIFE 进阶详细配置面板
    var onOpenRIFEConfig: (() -> Void)?
    var onSelectMetalFXTargetMode: ((MetalFXOption) -> Void)?
    var onCycleMetalFXTarget: (() -> Void)?
    var onSelectAnime4K: ((Anime4KOption) -> Void)?
    var onDecodePathChanged: ((DecodeMode) -> Void)?
    /// 需要提示给用户的一句话（后端未接入、设置已保存等）。由容器弹状态胶囊。
    var onNotice: ((String) -> Void)?

    // MARK: 子视图（名字取自反射池）

    private let blurView = NSVisualEffectView()
    private let overlayView = NSView()

    let playButton = OverlayPillButton()
    let backButton = OverlayPillButton()
    let forwardButton = OverlayPillButton()
    let progressSlider = SeekSlider()
    let timeLabel = NSTextField(labelWithString: "--:-- / --:--")
    let rifeButton = OverlayPillButton()
    let metalFXButton = OverlayPillButton()
    let anime4KButton = OverlayPillButton()

    /// 解码方式的显示容器：`decodePathTitle` 是固定的说明字，`decodePathLabel` 是当前值。
    let decodePathPill = NSView()
    let decodePathTitle = NSTextField(labelWithString: "")
    let decodePathLabel = NSTextField(labelWithString: "")
    /// 把上面两行文字竖着摞起来，并给胶囊提供**内容尺寸**。
    ///
    /// 为什么要这个 stack：`decodePathPill` 是个裸 `NSView`，它**没有 intrinsicContentSize**。
    /// 第一版给胶囊写死了 58pt 宽 + 28pt 高，于是：
    ///   · 「硬解（待接入）」这种长文案被截字；
    ///   · 两行字（9.5pt + 11.5pt）加起来比 28pt 还高，字会溢出胶囊下沿。
    /// 改成用 stack 撑出真实尺寸后，宽度和高度都跟着内容走，两个毛病一起没了。
    private let decodePillStack = NSStackView()

    let volumeIcon = NSImageView()
    let volumeSlider = NSSlider()
    let playlistButton = OverlayPillButton()
    let fullscreenButton = OverlayPillButton()

    // MARK: 状态

    /// 控制条只有「有东西可播」时才允许交互。
    private(set) var isEnabled = false

    /// 毛玻璃材质。与 `ControlOverlayView` 同源：原版有 `setupBlur()`。
    private static let barHeight: CGFloat = 52

    // MARK: - 构造

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupBlur()
        setupControls()
        setupSymbolImages()
        setupActions()
        refreshFromSettings()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBlur()
        setupControls()
        setupSymbolImages()
        setupActions()
        refreshFromSettings()
    }

    // MARK: - setupBlur（观测方法）

    private func setupBlur() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // **恒定深色**，不跟系统外观走 —— 这是「白色视频下看不见字」的根因修复。
        //
        // 原来写的是 `.titlebar` 材质且不指定 `appearance`，于是它跟随**系统外观**：
        // 浅色系统下就是一条浅灰条。而这条控制条上的图标与文字全是近白色
        //（`0.96 / 0.88 / 0.82` 白）—— 浅灰条 + 白字 = 基本看不见；
        // 播到白画面时更糟，整条和画面糊成一片（实测裁剪图里图标几乎消失）。
        //
        // 视频播放器的控制条必须对**内容**适配，而不是对系统外观适配：
        //   · 材质换 `.hudWindow`（HUD 面板的标准材质，本身就是深色取向）；
        //   · `appearance` 显式给 `.vibrantDark`，锁死深色活力，
        //     不再受「用户开了浅色模式」影响。
        blurView.material = .hudWindow
        blurView.appearance = NSAppearance(named: .vibrantDark)
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        // 再垫一层 22% 的黑，把对比度**兜死**。
        //
        // 为什么不只靠材质：材质是「半透明 + 采样背后内容」，最终亮度取决于
        // 背后的画面 —— 播纯白视频时它仍然会偏亮，白字就又开始糊。
        // 这层黑夹在「材质」与「控件」之间（`overlayView` 正是所有控件的父视图，
        // 所以它画在材质之上、控件之下），即使背后是纯白，白色图标也有足够反差。
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor =
            NSColor(calibratedWhite: 0, alpha: 0.22).cgColor

        overlayView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlayView)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    // MARK: - setupControls（观测方法）

    private func setupControls() {
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        timeLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        volumeIcon.contentTintColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        volumeIcon.translatesAutoresizingMaskIntoConstraints = false

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.doubleValue = 1
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        volumeSlider.translatesAutoresizingMaskIntoConstraints = false

        decodePathPill.wantsLayer = true
        decodePathPill.layer?.cornerRadius = 6
        decodePathPill.layer?.backgroundColor =
            NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        decodePathPill.translatesAutoresizingMaskIntoConstraints = false

        decodePathTitle.isHidden = true
        decodePathLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        decodePathLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 1)
        decodePathLabel.alignment = .center
        decodePathLabel.translatesAutoresizingMaskIntoConstraints = false

        decodePathPill.addSubview(decodePathLabel)
        decodePathPill.addSubview(decodePathTitle)
        NSLayoutConstraint.activate([
            decodePathLabel.centerXAnchor.constraint(equalTo: decodePathPill.centerXAnchor),
            decodePathLabel.centerYAnchor.constraint(equalTo: decodePathPill.centerYAnchor),
        ])

        for v in [playButton, backButton, forwardButton, progressSlider, timeLabel,
                  rifeButton, metalFXButton, anime4KButton, decodePathPill,
                  volumeIcon, volumeSlider, playlistButton, fullscreenButton] {
            overlayView.addSubview(v)
        }
    }

    // MARK: - setupSymbolImages（观测方法）

    private func setupSymbolImages() {
        func symbol(_ name: String, _ description: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: description)
        }

        for (button, name, label) in [
            (playButton,        "play.fill",         "播放"),
            (backButton,        "gobackward.5",      "后退 5 秒"),
            (forwardButton,     "goforward.5",       "前进 5 秒"),
            (playlistButton,    "list.bullet",       L10n.t("playlist")),
            (fullscreenButton,  "arrow.up.left.and.arrow.down.right", "全屏"),
        ] {
            button.image = symbol(name, label)
            button.toolTip = label
            button.usesSymbolOnly = true
        }

        volumeIcon.image = symbol("speaker.wave.2.fill", "音量")

        // 四个档位按钮是文字胶囊，不是图标 —— 它们要显示当前档位（"补帧 OFF" 之类）。
        for b in [rifeButton, metalFXButton, anime4KButton] {
            b.usesSymbolOnly = false
        }
        rifeButton.toolTip = "点击下拉快速切换：补帧 ON / 补帧 OFF / 60FPS / 120FPS"
        metalFXButton.toolTip = "MetalFX 空间上采样（Phase 5 接入）"
        anime4KButton.toolTip = "Anime4K 滤镜（Phase 5 接入）"
        decodePathPill.toolTip = "解码方式（硬解 / 软解）"
    }

    // MARK: - setupActions（观测方法）

    private func setupActions() {
        playButton.target = self
        playButton.action = #selector(clickPlayPause(_:))

        backButton.target = self
        backButton.action = #selector(clickBackward(_:))

        forwardButton.target = self
        forwardButton.action = #selector(clickForward(_:))

        playlistButton.target = self
        playlistButton.action = #selector(clickPlaylist(_:))

        fullscreenButton.target = self
        fullscreenButton.action = #selector(clickFullscreen(_:))

        // 进度条三段回调（见 SeekSlider 文件头）
        progressSlider.onBeginTracking = { }
        progressSlider.onPreviewValueChanged = { [weak self] normalized in
            guard let self, self.isEnabled else { return }
            self.onSeekPreview?(normalized * self.knownDuration)
        }
        progressSlider.onEndTracking = { [weak self] normalized in
            guard let self, self.isEnabled else { return }
            self.onSeek?(normalized * self.knownDuration)
        }

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged(_:))

        rifeButton.target = self
        rifeButton.action = #selector(clickRIFE(_:))
        rifeButton.onRightMouseDown = { [weak self] in
            self?.showRIFEMenu()
        }
        metalFXButton.target = self
        metalFXButton.action = #selector(clickMetalFX(_:))
        anime4KButton.target = self
        anime4KButton.action = #selector(clickAnime4K(_:))

        // 解码胶囊点击 → 弹菜单（用按钮的点击手势不方便，直接用一个透明的按键覆盖）
        let decodeClick = NSClickGestureRecognizer(target: self, action: #selector(clickDecode(_:)))
        decodePathPill.addGestureRecognizer(decodeClick)
    }

    // MARK: - 布局（Auto Layout）

    override func updateConstraints() {
        // 只在第一次铺约束；后续容器尺寸变化由约束自己处理。
        if overlayView.subviews.count > 0, !didLayOutOnce {
            didLayOutOnce = true
            installLayout()
        }
        super.updateConstraints()
    }

    private var didLayOutOnce = false

    private func installLayout() {
        let pad: CGFloat = 12
        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(equalToConstant: Self.barHeight),

            playButton.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: pad),
            playButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 28),
            playButton.heightAnchor.constraint(equalToConstant: 24),

            backButton.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 4),
            backButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 26),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            forwardButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            forwardButton.widthAnchor.constraint(equalToConstant: 26),
            forwardButton.heightAnchor.constraint(equalToConstant: 24),

            timeLabel.leadingAnchor.constraint(equalTo: forwardButton.trailingAnchor, constant: 10),
            timeLabel.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),

            progressSlider.leadingAnchor.constraint(equalTo: timeLabel.trailingAnchor, constant: 6),
            progressSlider.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),

            rifeButton.leadingAnchor.constraint(equalTo: progressSlider.trailingAnchor, constant: 12),
            rifeButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            rifeButton.widthAnchor.constraint(equalToConstant: 82),
            rifeButton.heightAnchor.constraint(equalToConstant: 24),

            metalFXButton.leadingAnchor.constraint(equalTo: rifeButton.trailingAnchor, constant: 6),
            metalFXButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            metalFXButton.widthAnchor.constraint(equalToConstant: 92),
            metalFXButton.heightAnchor.constraint(equalToConstant: 24),

            anime4KButton.leadingAnchor.constraint(equalTo: metalFXButton.trailingAnchor, constant: 6),
            anime4KButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            anime4KButton.widthAnchor.constraint(equalToConstant: 92),
            anime4KButton.heightAnchor.constraint(equalToConstant: 24),

            decodePathPill.leadingAnchor.constraint(equalTo: anime4KButton.trailingAnchor, constant: 6),
            decodePathPill.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            decodePathPill.widthAnchor.constraint(equalToConstant: 52),
            decodePathPill.heightAnchor.constraint(equalToConstant: 24),

            volumeIcon.leadingAnchor.constraint(equalTo: decodePathPill.trailingAnchor, constant: 12),
            volumeIcon.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            volumeIcon.widthAnchor.constraint(equalToConstant: 15),
            volumeIcon.heightAnchor.constraint(equalToConstant: 15),

            volumeSlider.leadingAnchor.constraint(equalTo: volumeIcon.trailingAnchor, constant: 5),
            volumeSlider.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            volumeSlider.widthAnchor.constraint(equalToConstant: 84),

            playlistButton.leadingAnchor.constraint(equalTo: volumeSlider.trailingAnchor, constant: 10),
            playlistButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            playlistButton.widthAnchor.constraint(equalToConstant: 28),
            playlistButton.heightAnchor.constraint(equalToConstant: 24),

            fullscreenButton.leadingAnchor.constraint(equalTo: playlistButton.trailingAnchor, constant: 4),
            fullscreenButton.centerYAnchor.constraint(equalTo: overlayView.centerYAnchor),
            fullscreenButton.widthAnchor.constraint(equalToConstant: 28),
            fullscreenButton.heightAnchor.constraint(equalToConstant: 24),
            fullscreenButton.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor,
                                                       constant: -pad),
        ]

        // ── 这一堆约束加起来是**定宽**的，而窗口可以自由缩放 ────────────────────
        //
        // 踩过的坑（本轮修的就是它）：上面每条都是 **required** 优先级。
        // 当窗口窄到装不下（左侧固定件 + 右侧固定件 > 可用宽度）时，Auto Layout
        // 无法同时满足，就会**打破其中一条**，结果是左下角的播放按钮 /
        // 时间标签互相压在一起（视觉上就是「重叠」）。
        //
        // 修法：把「不能被压缩」的（时间标签的宽度下限、滑块的宽度）降级成
        // 可打破的，并把滑块设成唯一的弹性元素 —— 空间不够时先让它变窄，
        // 而不是去动按钮的位置。顺序：滑块 → 时间标签 → 才轮到别的。
        //
        // 时间标签：只需要撑得住 "00:00 / 00:03"，下限 88pt，且**可被压缩**
        // （compression resistance 调低），这样它是第二顺位让位的。
        let timeMin = timeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 88)
        timeMin.priority = .defaultHigh                       // 750
        constraints.append(timeMin)
        timeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        timeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // 滑块：唯一真正的弹性件。给它一个很低的宽度下限（40pt），
        // 让它在窗口变窄时优先被压。它没有 trailing 约束 —— 被
        // `fullscreenButton.trailing == overlayView.trailing` 那条链间接夹住。
        let sliderMin = progressSlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 40)
        sliderMin.priority = .defaultLow                      // 250
        constraints.append(sliderMin)
        progressSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // 档位按钮与音量滑块同样允许在极端窄窗口下被压缩（正常情况下用不到，
        // 但比让 Auto Layout 去打破一条**位置**约束要好 —— 那才会重叠）。
        for b in [rifeButton, metalFXButton, anime4KButton] {
            b.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        }

        NSLayoutConstraint.activate(constraints)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
    }

    // MARK: - setTime（观测方法）

    /// 已知总时长。seek 的比例换算要用它，滑块本身只存 0...1。
    private var knownDuration: Double = 0
    private var isScrubbing = false

    func setTime(current: Double, duration: Double) {
        knownDuration = duration > 0 ? duration : 0
        timeLabel.stringValue = TimeFormat.progress(current: current, duration: duration)
        guard !progressSlider.isScrubbing, duration > 0 else { return }
        progressSlider.doubleValue = max(0, min(1, current / duration))
    }

    // MARK: - 回显

    /// 从 `PlaybackSettings` 重读一遍所有档位并写回界面。
    ///
    /// 这是「开关状态正确回显」那条验收标准的落点：
    /// 菜单里改了档位 → 发通知 → 控制条调这里 → 按钮文字跟着变。
    func refreshFromSettings() {
        let s = PlaybackSettings.shared

        switch s.rifeRateMode {
        case .off:
            rifeButton.title = "补帧 OFF"
            rifeButton.state = .off
        case .fps60:
            rifeButton.title = "60FPS"
            rifeButton.state = .on
        case .fps120:
            rifeButton.title = "120FPS"
            rifeButton.state = .on
        default:
            rifeButton.title = "补帧 ON"
            rifeButton.state = .on
        }

        metalFXButton.title = s.metalFX.barTitle
        anime4KButton.title = s.anime4k.barTitle

        decodePathLabel.stringValue = s.decodeMode.title

        volumeSlider.doubleValue = Double(s.volume)
        volumeIcon.image = NSImage(systemSymbolName: s.volume <= 0.001
                                   ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   accessibilityDescription: "音量")
    }

    /// 播放/暂停按钮的图标。
    func setPlaying(_ playing: Bool) {
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                   accessibilityDescription: playing ? "暂停" : "播放")
        playButton.toolTip = playing ? "暂停" : "播放"
    }

    /// 没有打开文件时整条置灰 —— 原版文案 `no_video_opened` = "未打开视频" 就是这个状态。
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        for v in [playButton, backButton, forwardButton, progressSlider, rifeButton,
                  metalFXButton, anime4KButton, volumeSlider, playlistButton, fullscreenButton] {
            v.isEnabled = enabled
        }
        alphaValue = enabled ? 1 : 0.65
        if !enabled {
            timeLabel.stringValue = "--:-- / --:--"
            progressSlider.doubleValue = 0
            knownDuration = 0
        }
    }

    // MARK: - 开发期：状态快照（MP_DUMP_UI）

    /// 把这条控制条上所有控件的当前状态打成多行文本。
    ///
    /// 为什么需要它：Phase 2 的验收有一条「开关状态正确回显」。菜单那边靠
    /// `MP_DUMP_MENU`（见 AppDelegate.dumpMenuTree）拿到了程序化证据；控制条这边
    /// 原本只能靠眼睛看 —— 这份快照就是给它配的同类证据：档位按钮的 title/state
    /// 全在里面，改档位前后各 dump 一次，逐字比对即可。
    func dumpState() -> String {
        var lines: [String] = []
        func button(_ name: String, _ b: OverlayPillButton) {
            let title = b.title.isEmpty ? "«仅图标»" : b.title
            let state = b.state == .on ? "on" : "off"
            lines.append("  \(name): title=\"\(title)\" state=\(state) enabled=\(b.isEnabled)")
        }

        lines.append("ControlOverlayView: enabled=\(isEnabled) "
                     + "alpha=\(String(format: "%.2f", alphaValue))")
        // 四个档位按钮 —— 验收关心的就是这四个的回显
        button("rifeButton", rifeButton)
        button("metalFXButton", metalFXButton)
        button("anime4KButton", anime4KButton)
        lines.append("  decodePathPill: \"\(decodePathTitle.stringValue) "
                     + "\(decodePathLabel.stringValue)\"")
        // 传输控件
        button("playButton", playButton)
        button("backButton", backButton)
        button("forwardButton", forwardButton)
        button("playlistButton", playlistButton)
        button("fullscreenButton", fullscreenButton)
        lines.append("  timeLabel: \"\(timeLabel.stringValue)\"")
        lines.append("  progressSlider: value=\(String(format: "%.3f", progressSlider.doubleValue)) "
                     + "enabled=\(progressSlider.isEnabled) "
                     + "scrubbing=\(progressSlider.isScrubbing)")
        lines.append("  volumeSlider: value=\(String(format: "%.2f", volumeSlider.doubleValue))")
        return lines.joined(separator: "\n")
    }

    // MARK: - 开发期：控件 frame 快照（MP_DUMP_FRAMES）

    /// 控制条上每个控件的**真实 frame**。
    ///
    /// 为什么需要：`dumpState()` 只能证明「档位回显对不对」，证明不了「排得开排不开」。
    /// 而「控件挤在一起 / 压到别的控件上」这类毛病，肉眼从截图上看是小图、
    /// 看不清到底是哪两条约束打架 —— 把 frame 摊成数字，一眼就能算出
    /// 「谁的右边缘越过了谁的左边缘」。
    ///
    /// 坐标是**父视图（overlayView）坐标**，横向也自左向右。
    func framesDebugText() -> String {
        // 同 `StatsPanelView.framesDebugText`：先强制布局再读 frame。
        // 不跑这一步的话，`refreshFromSettings()` 刚改过按钮 title、
        // 布局还没重算，读到的宽度/高度就是旧值（实测出现
        // `宽 28.5` 对不上 `width == 28`、`高 28` 对不上 `height == 24`
        // 这种「约束明明 active 却对不上」的假象）。
        window?.layoutIfNeeded()
        layoutSubtreeIfNeeded()

        var lines: [String] = []
        lines.append(String(format: "控制条   %@  (边界 %.0fx%.0f pt)",
                            NSStringFromRect(frame), bounds.width, bounds.height))
        lines.append(String(format: "浮层     %@", NSStringFromRect(overlayView.frame)))

        // 按**从左到右**的顺序列，方便直接对着找重叠。
        let named: [(String, NSView)] = [
            ("播放    ", playButton), ("后退    ", backButton), ("前进    ", forwardButton),
            ("时间    ", timeLabel), ("进度条  ", progressSlider), ("补帧    ", rifeButton),
            ("MetalFX ", metalFXButton), ("Anime4K ", anime4KButton),
            ("解码胶囊", decodePathPill),
            ("音量图标", volumeIcon), ("音量条  ", volumeSlider),
            ("列表    ", playlistButton), ("全屏    ", fullscreenButton),
        ]
        for (name, v) in named {
            lines.append(String(format: "%@  x %7.1f … %7.1f   宽 %6.1f   高 %5.1f",
                                name, v.frame.minX, v.frame.maxX,
                                v.frame.width, v.frame.height))
        }

        // 光看 frame 只能知道「没按约束排」，不知道「约束到底在不在」。
        // 这里把几个关键控件身上的约束直接摊开：一条 `width == 28` 如果
        // 压根没生效（isActive=false）或根本不存在，答案就写在这里。
        for probe in [playButton, timeLabel, progressSlider] {
            lines.append("── \(probe) 身上的约束 ──")
            let pool = probe.constraints + (probe.superview?.constraints ?? [])
            var found = false
            for c in pool where (c.firstItem as? NSView) === probe
                             || (c.secondItem as? NSView) === probe {
                found = true
                lines.append("  \(c)")
            }
            if !found { lines.append("  （一条都没有）") }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 开发期：配色证据（MP_DUMP_FRAMES 一并打出）

    /// 控制条的**配色构成**：底色来自哪几层、文字/图标是什么颜色、
    /// 以及它们在「纯白视频」和「纯黑视频」两种极端下的对比度。
    ///
    /// 为什么需要：这条控制条原来是跟随**系统外观**的（`.titlebar` 材质），
    /// 浅色系统下就是浅灰条 + 近白图标 —— 白色视频上基本看不见。改成恒定深色后，
    /// 「到底深到什么程度、够不够看清」这件事**用文本是证明不了的**，
    /// 除非把颜色值本身摊出来算对比度。这里就把这一步做掉：
    /// 视频画面只能透过来 `blurView` 那一层，所以「白画面」时
    /// 控件实际压在的亮度 = 白 × (1 - 不透明度) 再叠加我们垫的黑层。
    /// 只要这个合成结果离文字亮度足够远，白画面下就必然看得清。
    func appearanceDebugText() -> String {
        // ⚠️ 只用 `redComponent/greenComponent/blueComponent` 取通道值，
        // **绝不要碰 `whiteComponent`** —— 那是灰度色彩空间专用的，
        // 对 RGB 颜色访问它会直接抛 `NSInternalInconsistencyException` 把进程带走
        //（实测：本方法第一版就是这么把 app 崩在 SIGABRT 上的，exit=134）。
        // 所有颜色先 `usingColorSpace(.deviceRGB)` 归一化再取通道。
        func rgb(_ c: NSColor?) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)? {
            guard let c = c?.usingColorSpace(.deviceRGB) else { return nil }
            return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        }
        /// Rec.709 感知亮度。判「看不看得见」靠亮度差，不是 RGB 平均值。
        func luma(_ t: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat)) -> CGFloat {
            0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b
        }

        var lines: [String] = []

        let matName: String
        switch blurView.material {
        case .hudWindow:  matName = ".hudWindow"
        case .titlebar:   matName = ".titlebar"
        case .sidebar:    matName = ".sidebar"
        case .menu:       matName = ".menu"
        case .popover:    matName = ".popover"
        case .fullScreenUI: matName = ".fullScreenUI"
        case .underWindowBackground: matName = ".underWindowBackground"
        case .contentBackground: matName = ".contentBackground"
        default:          matName = "«其它»"
        }
        lines.append("材质    \(matName) · appearance=\(blurView.appearance?.name.rawValue ?? "«继承»")")
        lines.append("状态    blending=\(blurView.blendingMode == .withinWindow ? "withinWindow" : "behindWindow")"
                     + " · state=\(blurView.state == .active ? "active" : "inactive")"
                     + " · 父视图 appearance=\(effectiveAppearance.name.rawValue)")

        // 垫在控件与材质之间的那层黑 —— 这是「白画面下兜住对比度」的关键一层。
        let pad = rgb(overlayView.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
        if let pad {
            lines.append(String(format: "垫层    overlayView 背景 亮度%.2f α%.2f",
                                luma(pad), pad.a))
        } else {
            lines.append("垫层    overlayView 没有背景色（**白画面下会糊**）")
        }

        // 控件自己的颜色。
        let probes: [(String, NSColor?)] = [
            ("播放图标", playButton.contentTintColor),
            ("档位文字", rifeButton.contentTintColor),
            ("时间文字", timeLabel.textColor),
            ("音量图标", volumeIcon.contentTintColor),
            ("胶囊小字", decodePathTitle.textColor),
            ("胶囊大字", decodePathLabel.textColor),
        ]
        var minLuma: CGFloat = 1
        for (name, color) in probes {
            guard let t = rgb(color) else {
                lines.append("　　\(name)  «无颜色»"); continue
            }
            minLuma = min(minLuma, luma(t))
            lines.append(String(format: "　　%@  亮度 %.2f · α%.2f", name, luma(t), t.a))
        }

        // 最坏情况：背后是纯白。`blurView` 是半透明材质，白画面会透上来一部分，
        // 挡住它的只有垫层那点黑。所以「白画面下控件压在的亮度上界」
        // = 白 × (1 - 垫层不透明度)。只要这个上界离最暗的文字亮度足够远就看得清。
        let bgUpper = 1.0 * (1 - (pad?.a ?? 0))
        let diff = minLuma - bgUpper
        lines.append(String(format: "白画面  背景亮度上界 %.2f · 最暗文字亮度 %.2f · 差 %.2f %@",
                            bgUpper, minLuma, diff,
                            diff > 0.25 ? "（够）" : "（**偏小，可能糊**）"))
        return lines.joined(separator: "\n")
    }

    // MARK: - 四个档位按钮

    @objc private func clickPlayPause(_ sender: Any?) { onPlayPause?() }

    @objc private func clickBackward(_ sender: Any?) { onSeekRelative?(-5) }

    @objc private func clickForward(_ sender: Any?) { onSeekRelative?(5) }

    @objc private func clickPlaylist(_ sender: Any?) { onTogglePlaylist?() }

    @objc private func clickFullscreen(_ sender: Any?) { onFullscreen?() }

    /// 补帧按钮：点击直接弹出快速切换下拉菜单（补帧 ON / 补帧 OFF / 60FPS / 120FPS）。
    @objc private func clickRIFE(_ sender: Any?) {
        showRIFEMenu()
    }

    /// showRIFEMenu（观测方法）：弹出补帧下拉快速切换菜单。
    func showRIFEMenu() {
        let menu = NSMenu()
        let s = PlaybackSettings.shared
        let mode = s.rifeRateMode

        // 1. 补帧 ON
        let onItem = NSMenuItem(title: "补帧 ON",
                                action: #selector(onQuickRIFEOption(_:)),
                                keyEquivalent: "")
        onItem.target = self
        onItem.representedObject = "on"
        let isStandardOn = (mode != .off && mode != .fps60 && mode != .fps120)
        onItem.state = isStandardOn ? .on : .off
        menu.addItem(onItem)

        // 2. 补帧 OFF
        let offItem = NSMenuItem(title: "补帧 OFF",
                                 action: #selector(onQuickRIFEOption(_:)),
                                 keyEquivalent: "")
        offItem.target = self
        offItem.representedObject = "off"
        offItem.state = (mode == .off) ? .on : .off
        menu.addItem(offItem)

        // 3. 60FPS
        let fps60Item = NSMenuItem(title: "60FPS",
                                   action: #selector(onQuickRIFEOption(_:)),
                                   keyEquivalent: "")
        fps60Item.target = self
        fps60Item.representedObject = "60fps"
        fps60Item.state = (mode == .fps60) ? .on : .off
        menu.addItem(fps60Item)

        // 4. 120FPS
        let fps120Item = NSMenuItem(title: "120FPS",
                                    action: #selector(onQuickRIFEOption(_:)),
                                    keyEquivalent: "")
        fps120Item.target = self
        fps120Item.representedObject = "120fps"
        fps120Item.state = (mode == .fps120) ? .on : .off
        menu.addItem(fps120Item)

        menu.addItem(NSMenuItem.separator())

        // 5. 详细配置与模型专属定制
        let configItem = NSMenuItem(title: "⚙️ 详细配置与模型专属定制...",
                                    action: #selector(openRIFEConfigAction(_:)),
                                    keyEquivalent: "r")
        configItem.keyEquivalentModifierMask = [.command, .shift]
        configItem.target = self
        menu.addItem(configItem)

        popUp(menu, anchor: rifeButton)
    }

    @objc private func onQuickRIFEOption(_ item: NSMenuItem) {
        guard let tag = item.representedObject as? String else { return }
        switch tag {
        case "on":
            // 如果原本是 off、60fps 或 120fps，切换至 2X 双倍插帧；如果已经是倍率插帧则保持
            let current = PlaybackSettings.shared.rifeRateMode
            if current == .off || current == .fps60 || current == .fps120 {
                onSelectRIFERateMode?(.x2)
            }
        case "off":
            onSelectRIFERateMode?(.off)
        case "60fps":
            onSelectRIFERateMode?(.fps60)
        case "120fps":
            onSelectRIFERateMode?(.fps120)
        default:
            break
        }
    }

    @objc private func openRIFEConfigAction(_ sender: Any?) {
        onOpenRIFEConfig?()
    }

    /// selectRIFEMenuItem（观测方法保留，保证兼容）。
    @objc func selectRIFEMenuItem(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let mode = RIFERateMode(rawValue: raw) else { return }
        onSelectRIFERateMode?(mode)
    }

    /// MetalFX 按钮：普通点击 = 循环（观测到 `onCycleMetalFXTarget`）；
    /// Alt / 右键 = 弹菜单（观测到 `showMetalFXMenu`）。
    @objc private func clickMetalFX(_ sender: Any?) {
        let alt = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if alt {
            showMetalFXMenu()
        } else {
            onCycleMetalFXTarget?()
        }
    }

    /// showMetalFXMenu（观测方法）。
    func showMetalFXMenu() {
        let menu = NSMenu()
        for option in MetalFXOption.allCases {
            let item = NSMenuItem(title: option.title,
                                  action: #selector(selectMetalFXMenuItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = (PlaybackSettings.shared.metalFX == option) ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, anchor: metalFXButton)
    }

    /// selectMetalFXMenuItem（观测方法）。
    @objc func selectMetalFXMenuItem(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let option = MetalFXOption(rawValue: raw) else { return }
        onSelectMetalFXTargetMode?(option)
    }

    @objc private func clickAnime4K(_ sender: Any?) {
        let menu = NSMenu()
        for option in Anime4KOption.allCases {
            let item = NSMenuItem(title: option == .off
                                  ? L10n.t("anime4k_off_detail")   // "关闭 Anime4K"
                                  : L10n.t("anime4k_panel_title"), // "Anime4K 滤镜"
                                  action: #selector(selectAnime4KItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = (PlaybackSettings.shared.anime4k == option) ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, anchor: anime4KButton)
    }

    @objc private func selectAnime4KItem(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let option = Anime4KOption(rawValue: raw) else { return }
        onSelectAnime4K?(option)
    }

    @objc private func clickDecode(_ sender: Any?) {
        let menu = NSMenu()
        for mode in DecodeMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(selectDecodeItem(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (PlaybackSettings.shared.decodeMode == mode) ? .on : .off
            menu.addItem(item)
        }
        popUp(menu, anchor: decodePathPill)
    }

    @objc private func selectDecodeItem(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let mode = DecodeMode(rawValue: raw) else { return }
        onDecodePathChanged?(mode)
    }

    @objc private func volumeChanged(_ sender: Any?) {
        onVolumeChanged?(Float(volumeSlider.doubleValue))
    }

    // MARK: - 弹出菜单

    /// 在按钮下方弹菜单。
    ///
    /// `NSMenu.popUp(positioning:at:in:)` 的坐标是**视图坐标**，y 轴向上为正。
    /// 所以「在按钮下方」= `-menuHeight`。菜单高度得先量一次（`menu.size`）。
    private func popUp(_ menu: NSMenu, anchor: NSView? = nil) {
        let host = anchor ?? rifeButton
        let size = menu.size
        let origin = NSPoint(x: host.frame.minX,
                             y: host.frame.minY - size.height - 4)
        menu.popUp(positioning: nil, at: origin, in: host.superview)
    }
}
