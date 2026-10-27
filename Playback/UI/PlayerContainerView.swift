//  PlayerContainerView.swift
//  MetalPlayer 重建工程 —— 播放容器（Phase 2）
//
//  这是窗口的 contentView，也是原版 UI 树的根：
//
//      PlayerWindowController → PlayerContainerView
//                                ├── VideoRenderView       画面（Metal，铺满）
//                                ├── ControlOverlayView    底部控制条
//                                └── PlaylistPanelView     播放列表（右侧浮层）
//
//  原版骨架观测到的成员方法（逐个都实现了语义）：
//      showOverlay() / scheduleHideOverlay(delay:hideCursorWhenDone:)
//      hideCursorIfNeeded() / showCursorIfNeeded()
//      showStatusPill(_:autoHideDelay:) / hideStatusPill()
//      beginOverlayInteraction()
//      layout() / updateTrackingAreas()
//      keyDown(with:) / mouseDown(with:)
//      draggingEntered(_:) / performDragOperation(_:)
//
//  反射段给出的成员名（都用上了）：
//      overlayView  containerView  trackingAreaRef
//      cursorHideWorkItem  cursorAutoHideSuspended  isCursorHidden
//      currentVideoViewport  onNotice  onPlayPause  onSeek  onVolumeChanged
//
//  与 Phase 1 的关系：Phase 1 的 `Playback/PlayerRootView.swift` 是本文件的雏形
//  （画面 + 简版控制条）。Phase 2 把它升级成原版的结构与命名，并把控制条拆成
//  独立的 `ControlOverlayView`。原文件已删除。

import Foundation
import AppKit
import AVFoundation

// MARK: - 无 FFmpeg 时的占位容器

#if !USE_FFMPEG

/// 关掉 `USE_FFMPEG` 时的同名类型：只保证**接口一致**，不提供播放能力。
///
/// 为什么不是「干脆不编这个类」：`PlayerWindowController` 与菜单都无条件引用它。
/// 让它在两种构建下都存在、接口一致，上层就不用满地写 `#if`。
/// 这也是 Phase 1 那条验收（「`-DUSE_FFMPEG` 关闭时回落到占位实现」）的延续。
final class PlayerContainerView: NSView {

    let overlay = ControlOverlayView(frame: .zero)
    let playlistPanel = PlaylistPanelView(frame: .zero)
    /// 性能监看面板（Tab 切换）。两种构建下都要有 —— 关掉 FFmpeg 时它仍然
    /// 有用：CPU/内存/GPU 与 FFmpeg 无关，三节里另外两节会如实显示「未打开文件」。
    let statsPanel = StatsPanelView(frame: .zero)

    // 与真实实现**逐条对应**的接口。少一条上层的 PlayerWindowController / AppDelegate
    // 就编不过 —— 这正是为什么这里要写全，而不是「随便留个空壳」。
    var onNotice: ((String) -> Void)?
    var onPlaybackStateChanged: ((Bool) -> Void)?
    var onCurrentURLChanged: ((URL?) -> Void)?
    var onToggleFullscreenRequested: (() -> Void)?

    var onPlaylistSelect: ((Int) -> Void)?
    var onPlaylistDelete: ((Int) -> Void)?
    var onPlaylistMove: ((Int, Int) -> Void)?
    var onPlaylistAppend: (([URL]) -> Void)?
    var onFileDrop: ((URL) -> Void)?

    var playlistPanelView: PlaylistPanelView { playlistPanel }

    var currentURL: URL? { nil }
    var isPlaying: Bool { false }
    var tracks: [TrackInfo] { [] }
    var audioTracks: [TrackInfo] { [] }
    var subtitleTracks: [TrackInfo] { [] }
    var currentAudioStreamIndex: Int? { nil }
    var selectedAudioStreamIndex: Int { -1 }
    var currentSubtitleStreamIndex: Int? { nil }
    var selectedSubtitleStreamIndex: Int { -1 }
    var externalSubtitleName: String? { nil }
    var currentTime: Double { 0 }
    var duration: Double { 0 }
    var isPlaylistVisible: Bool { playlistPanel.isShown }
    var isStatsVisible: Bool { statsPanel.isShown }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildPlaceholder()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildPlaceholder()
    }

    private func buildPlaceholder() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "Macrife Player · FFmpeg 未启用")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        // 性能面板在占位构建下同样可用：③ 性能参数（CPU/内存/GPU）与 FFmpeg 无关，
        // ①② 两节会显示「未打开文件」。这不是「顺手加的」，是「接口一致」的一部分 ——
        // 上层（AppDelegate 的菜单 / MP_DUMP_STATS）不该关心 FFmpeg 开没开。
        statsPanel.isHidden = true
        addSubview(statsPanel)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            statsPanel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            statsPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            statsPanel.widthAnchor.constraint(equalToConstant: Self.statsPanelWidth),
        ])
    }

    func open(url: URL) { onNotice?("FFmpeg 未启用，无法播放 \(url.lastPathComponent)") }
    func open(urls: [URL], startIndex: Int) { }
    func closeCurrent() { }
    func shutdownForTermination() { }
    func togglePlayPause() { }
    func seek(to seconds: Double) { }
    func seekRelative(_ delta: Double) { }
    func setVolume(_ v: Float) { }
    func showOverlay() { }
    func scheduleHideOverlay(delay: Double, hideCursorWhenDone: Bool) { }
    func showStatusPill(_ text: String, autoHideDelay: Double?) { onNotice?(text) }
    func hideStatusPill() { }
    func setPlaylistVisible(_ visible: Bool) { }
    func setPlaylist(_ items: [PlaylistItem], currentIndex: Int) { }
    func togglePlaylist() { }
    /// 性能监看面板：占位构建下**真的能用**（Tab 切换）。
    func setStatsVisible(_ visible: Bool) { visible ? statsPanel.show() : statsPanel.hide() }
    func toggleStatsPanel() { statsPanel.toggle() }
    @objc func openDocumentAction(_ sender: Any?) { }
    func openLaunchFileIfNeeded() { }
    /// 与真实实现逐条对应（`MP_DUMP_UI` 用）。
    func dumpOverlayState() -> String { overlay.dumpState() }
    /// 字幕控制：占位构建下都是空实现，但必须**逐条存在** ——
    /// 两套同名类型的接口少一条就编不过（这是 Phase 2 立下的规矩）。
    func selectAudioTrack(_ index: Int) { }
    func selectSubtitleTrack(_ index: Int) { }
    func disableSubtitles() { }
    func loadExternalSubtitle(url: URL) { }
    func subtitleDumpText() -> String { "（未启用 FFmpeg，没有字幕管线）" }
    /// dev：导出字幕层用。占位构建没有管线，恒为 nil。
    func subtitleSnapshotForExport() -> (bitmap: SubtitleBitmap, width: Int, height: Int)? { nil }
    /// dev：导出性能面板位图（`--stats-png`）。占位构建里面板本身是能显示的
    /// （CPU/内存那节与 FFmpeg 无关），所以这里**照实返回**，不是空实现。
    func statsPanelSnapshotForExport() -> CGImage? { statsPanel.snapshotForExport() }
    /// dev：面板与六个文本控件的真实 frame（`--stats-png` 一并打出）。
    /// 两套构建都要有 —— 面板在占位构建下同样能显示，诊断也该一致。
    func statsPanelFramesText() -> String { statsPanel.framesDebugText() }
    /// dev：底部控制条上每个控件的真实 frame（`--dump-frames` 用）。
    func overlayFramesText() -> String { overlay.framesDebugText() }
    /// dev：导出底部控制条位图（`--overlay-png`）。占位构建下控制条同样显示，
    /// 所以这里照实返回，不是空实现。
    ///
    /// ⚠️ 导出前必须先把 alpha 拉回 1：控制条会**自动隐藏**（鼠标不动
    /// `overlayHideDelay` 秒后 `alphaValue → 0`），而 alpha 为 0 的图层
    /// `CALayer.render` 一个像素都画不出来 —— 实测导出的是 3024x104 的
    /// **全透明 PNG**（0 个非透明像素），看起来像「渲染坏了」，
    /// 其实只是那次 dump 时它恰好是隐藏状态。
    func overlaySnapshotForExport() -> CGImage? {
        overlay.alphaValue = 1
        return ViewSnapshot.layerImage(of: overlay)
    }
    /// dev：控制条配色证据（白画面下看不看得清）。
    func overlayAppearanceText() -> String { overlay.appearanceDebugText() }
    /// 与真实实现逐条对应（`MP_DUMP_STATS` 用）。
    func dumpStatsState() -> String { statsPanel.dumpText() }
    func refreshStatsPanel() { statsPanel.refreshNow() }
    /// 与真实实现逐条对应：换文件后清掉 FPS 采样历史。
    func resetStatsSampling() { statsPanel.resetSampling() }
    func openRIFEConfig() { RIFEConfigPanelController.shared.show(relativeTo: window) }
}

#else

// MARK: - 真实播放容器

final class PlayerContainerView: NSView, PlaybackEngineDelegate {

    // MARK: 对外回调

    /// 需要往状态胶囊里放一句话。窗口控制器一般不用，容器自己就能显示。
    var onNotice: ((String) -> Void)?
    /// 播放/暂停状态变了（菜单的「播放」项要跟着改标题）。
    var onPlaybackStateChanged: ((Bool) -> Void)?
    /// 打开了新文件 / 关闭了文件。
    var onCurrentURLChanged: ((URL?) -> Void)?
    /// 用户点了全屏按钮。
    var onToggleFullscreenRequested: (() -> Void)?

    // MARK: 组件

    private let engine = PlaybackEngine()
    private let renderView = VideoRenderView(frame: .zero)
    let overlay = ControlOverlayView(frame: .zero)
    let playlistPanel = PlaylistPanelView(frame: .zero)
    /// 性能监看面板（Tab 切换）。默认隐藏，显示时**每 0.5s 反拉一次**引擎计数。
    let statsPanel = StatsPanelView(frame: .zero)

    /// 媒体打开串行调度队列：确保拖拽打开、菜单打开与重载按序排队，杜绝并发执行 engine.open
    private let mediaOpenQueue = DispatchQueue(label: "com.macrife.mediaOpenQueue", qos: .userInitiated)

    // 反射池里的名字：containerView / overlayView 在 ControlOverlayView 内部，
    // 这里对应「容器里装画面与浮层的那一层」。
    private let containerView = NSView()

    /// 居中偏下的状态胶囊（`showStatusPill`）。原版用它显示「未打开视频」「RIFE 引擎就绪」等。
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusPill = NSView()

    /// 左上角信息条。**只在 `MP_TRACE` 打开时显示** —— 原版没有这个东西，
    /// 它是本工程开发期的管线观察窗（Phase 1 起就有）。
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: 覆盖层自动隐藏（反射池：cursorHideWorkItem / cursorAutoHideSuspended / isCursorHidden）

    private var cursorHideWorkItem: DispatchWorkItem?
    private var statusHideWorkItem: DispatchWorkItem?
    private var cursorAutoHideSuspended = false
    private(set) var isCursorHidden = false
    private var trackingAreaRef: NSTrackingArea?

    /// 覆层停留时长。原版未给出数值，按「鼠标停下 2.5 秒后淡出」选。
    private var overlayHideDelay: TimeInterval = 2.5

    /// 是否显示信息条（开发期）。
    private let showsInfo = DevFlag.on("MP_TRACE", "--trace")

    // MARK: 播放进度保存节流
    private var lastProgressSaveTime: Double = 0
    private var lastProgressSaveWallClock: TimeInterval = 0

    // MARK: - 构造

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        wire()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
        wire()
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }

    // MARK: - UI

    private func buildUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        containerView.wantsLayer = true
        containerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(containerView)

        renderView.translatesAutoresizingMaskIntoConstraints = false
        renderView.videoSizeProvider = { [weak self] in self?.engine.videoSize ?? .zero }
        renderView.frameProvider = { [weak self] in self?.engine.nextFrameForDisplay() }
        // 字幕层：按**视频原始尺寸**渲染，之后与画面共用同一组 letterbox 顶点。
        //
        // 时间取播放时钟（`engine.currentTime`）而不是「最后上屏那一帧的 pts」——
        // 丢帧时后者会落后于真实播放位置，字幕会跟着慢半拍。
        // 字幕本来就该跟着 audible 的时间走。
        renderView.subtitleProvider = { [weak self] width, height in
            guard let self else { return nil }
            return self.engine.renderSubtitle(at: self.engine.currentTime,
                                              width: width, height: height)
        }
        containerView.addSubview(renderView)

        containerView.addSubview(overlay)

        // ---- 状态胶囊
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = 11
        statusPill.layer?.backgroundColor =
            NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        statusPill.alphaValue = 0
        statusPill.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusPill.addSubview(statusLabel)
        containerView.addSubview(statusPill)

        // ---- 信息条（dev only）
        infoLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        infoLabel.isHidden = !showsInfo
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(infoLabel)

        // ---- 播放列表（右侧浮层，默认隐藏）
        playlistPanel.isHidden = true
        containerView.addSubview(playlistPanel)

        // ---- 性能监看面板（左上浮层，默认隐藏；Tab 切换）
        // 放在左上而不是右上：右边留给播放列表，两者同开时互不遮挡。
        statsPanel.isHidden = true
        containerView.addSubview(statsPanel)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: topAnchor),
            containerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            renderView.topAnchor.constraint(equalTo: containerView.topAnchor),
            renderView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            renderView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            renderView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),

            overlay.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

            statusPill.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusPill.bottomAnchor.constraint(equalTo: overlay.topAnchor, constant: -14),
            statusPill.heightAnchor.constraint(equalToConstant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),

            infoLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 14),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor,
                                                constant: -14),

            playlistPanel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            playlistPanel.bottomAnchor.constraint(equalTo: overlay.topAnchor, constant: -10),
            playlistPanel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor,
                                                    constant: -10),

            // 性能面板：定宽 + 贴左上。高度由内容（六段文本）撑开，
            // 但**必须**让在控制条上方 —— 盖住控制条就没法操作了。
            // 这条 `lessThanOrEqualTo` 是 required，而撑高约束是 999：
            // 窗口太矮时先放弃「完整显示」，由面板自身的 masksToBounds 裁掉下沿，
            // 而不是打破一条 required 约束导致整块布局乱掉。
            statsPanel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 14),
            statsPanel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 14),
            statsPanel.widthAnchor.constraint(equalToConstant: Self.statsPanelWidth),
            statsPanel.bottomAnchor.constraint(lessThanOrEqualTo: overlay.topAnchor, constant: -8),
        ])
        // 「至少留出 96pt」是**建议**而不是硬要求：极端窄窗口下宁可把它压扁，
        // 也不能和上面那条 required 的 `<= 控制条顶部` 打架（打架就会有一条被打破，
        // 表现出来就是面板跑到控制条身上）。
        let statsMinHeight = statsPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        statsMinHeight.priority = .defaultHigh
        statsMinHeight.isActive = true
    }

    private func wire() {
        engine.delegate = self
        overlay.onPlayPause = { [weak self] in self?.togglePlayPause() }
        overlay.onSeek = { [weak self] seconds in self?.seek(to: seconds) }
        overlay.onSeekPreview = { [weak self] seconds in
            guard let self else { return }
            self.overlay.setTime(current: seconds, duration: self.engine.duration)
        }
        overlay.onSeekRelative = { [weak self] delta in self?.seekRelative(delta) }
        overlay.onReload = { [weak self] in self?.reloadCurrentMedia() }
        overlay.onVolumeChanged = { [weak self] v in self?.setVolume(v) }
        overlay.onTogglePlaylist = { [weak self] in self?.togglePlaylist() }
        overlay.onFullscreen = { [weak self] in self?.onToggleFullscreenRequested?() }
        overlay.onToggleRIFE = { [weak self] in self?.cycleRIFERate() }
        overlay.onSelectRIFERateMode = { [weak self] mode in self?.applyRIFERate(mode) }
        overlay.onOpenRIFEConfig = { [weak self] in self?.openRIFEConfig() }
        overlay.onSelectMetalFXTargetMode = { [weak self] option in self?.applyMetalFX(option) }
        overlay.onCycleMetalFXTarget = { [weak self] in self?.cycleMetalFX() }
        overlay.onSelectAnime4K = { [weak self] option in self?.applyAnime4K(option) }
        overlay.onDecodePathChanged = { [weak self] mode in self?.applyDecodeMode(mode) }
        overlay.onNotice = { [weak self] text in self?.showStatusPill(text, autoHideDelay: 2.4) }

        playlistPanel.onSelectIndex = { [weak self] index in self?.onPlaylistSelect?(index) }
        playlistPanel.onDeleteIndex = { [weak self] index in self?.onPlaylistDelete?(index) }
        playlistPanel.onMoveItem = { [weak self] from, to in self?.onPlaylistMove?(from, to) }
        playlistPanel.onAppendPlaylistURLs = { [weak self] urls in self?.onPlaylistAppend?(urls) }
        playlistPanel.onClosePanel = { [weak self] in self?.setPlaylistVisible(false) }

        // 性能面板自己按 0.5s 反拉数据（面板不可见时一次都不拉）。
        // 这两个闭包都在主线程被调用 —— 采样定时器挂在 main runloop 上，
        // 而 `snapshotCounters()` 读的都是快照/原子标量，不碰解码器。
        statsPanel.configure(
            counters: { [weak self] in self?.engine.snapshotCounters() ?? PlaybackCounters.empty },
            detail: { [weak self] in self?.engine.detail ?? MediaDetail() })

        // ① 里那一行字幕说明（Phase 3）。
        //
        // 为什么不直接塞进 MediaDetail：`MediaDetail` 是「FFmpeg 对文件读出来的客观参数」，
        // 而这里要表达的是**当前选中了哪条轨 / 有没有加载外挂** —— 那是引擎的运行时状态，
        // 会随用户点菜单而变，不属于「文件的参数」。
        statsPanel.setSubtitleLineProvider { [weak self] in
            guard let self else { return nil }
            let tracks = self.engine.subtitleTracks
            guard !tracks.isEmpty || self.engine.externalSubtitleName != nil else { return nil }
            if let name = self.engine.externalSubtitleName { return "外挂 \(name)" }
            let selected = self.engine.selectedSubtitleStreamIndex
            guard selected >= 0,
                  let t = tracks.first(where: { $0.index == selected }) else {
                return "\(tracks.count) 条 · 已关闭"
            }
            return "\(tracks.count) 条 · 当前 \(t.menuTitle)"
        }

        // ① 里那一行音轨说明（Phase 3.5）。
        statsPanel.setAudioLineProvider { [weak self] in
            guard let self else { return nil }
            let tracks = self.engine.audioTracks
            guard !tracks.isEmpty else { return nil }
            let selected = self.engine.selectedAudioStreamIndex
            if let t = tracks.first(where: { $0.index == selected }) {
                if tracks.count > 1 {
                    return "\(tracks.count) 条 · 当前 \(t.menuTitle)"
                } else {
                    return t.menuTitle
                }
            }
            return "\(tracks.count) 条"
        }

        overlay.setEnabled(false)
        showStatusPill(L10n.t("no_video_opened"), autoHideDelay: nil)

        // 设置变化（菜单改的档位）→ 控制条重读
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)),
            name: .playbackSettingsDidChange, object: nil)

        // 应用将要退出时保存当前播放进度
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)

        applyVolumeFromSettings()
        registerForDraggedTypes([.fileURL])

        installTabMonitor()
        installRenderTickIfRequested()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        removeTabMonitor()
        renderTickTimer?.invalidate()
    }

    @objc private func handleAppWillTerminate() {
        saveCurrentProgressIfNeeded()
    }

    // MARK: - dev：无窗口环境下的「渲染取帧」驱动（MP_RENDER_TICK）

    /// 画面是靠 `VideoRenderView.draw(in:)` 里的 `frameProvider?()` 拉的，
    /// 而 MTKView 的 draw 由显示链路驱动 —— 在没有**可见/合成**窗口的环境里
    /// （无头跑、屏幕锁定、CI 机）它一次都不跑。后果是 `nextFrameForDisplay()`
    /// 永远不被调用：帧队列会一直满着（视频包队列随之堵死），性能面板里
    /// 「渲染 FPS / 已上屏」恒为 0。
    ///
    /// ⚠️ 那不是逻辑坏，是**没人拉**。所以要验证「已上屏 / 丢帧 / 渲染 FPS」
    /// 这三个读数在真实管线里是活的，就得有个东西去拉。
    ///
    /// 这个开关按 60Hz 手动调**渲染视图用的同一个闭包**（不是另写一条取帧路径，
    /// 否则验的就不是真东西了）。仅在 `MP_RENDER_TICK` / `--render-tick` 下启用，
    /// 正常启动时这段完全不存在。
    private var renderTickTimer: Timer?

    private func installRenderTickIfRequested() {
        guard DevFlag.on("MP_RENDER_TICK", "--render-tick") else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            _ = self?.renderView.frameProvider?()
        }
        // .common：拖进度条时 runloop 会切到 event tracking 模式，
        // 不挂这个 mode 定时器会被挂起（和面板刷新定时器同一个理由）。
        RunLoop.main.add(timer, forMode: .common)
        renderTickTimer = timer
        FileHandle.standardError.write(
            Data("[PlayerContainerView] dev: MP_RENDER_TICK 已接管渲染取帧（60Hz）\n".utf8))
    }

    // MARK: 播放列表回调（由窗口控制器接管）

    var onPlaylistSelect: ((Int) -> Void)?
    var onPlaylistDelete: ((Int) -> Void)?
    var onPlaylistMove: ((Int, Int) -> Void)?
    var onPlaylistAppend: (([URL]) -> Void)?
    var onFileDrop: ((URL) -> Void)?

    /// 反射池里的 `playlistPanelView` 在窗口控制器那侧；这里给一个只读入口。
    var playlistPanelView: PlaylistPanelView { playlistPanel }

    func setPlaylistVisible(_ visible: Bool) {
        visible ? playlistPanel.show() : playlistPanel.hide()
    }

    func togglePlaylist() { playlistPanel.toggle() }

    var isPlaylistVisible: Bool { playlistPanel.isShown }
    var isStatsVisible: Bool { statsPanel.isShown }

    func setPlaylist(_ items: [PlaylistItem], currentIndex: Int) {
        playlistPanel.setItems(items, currentIndex: currentIndex)
    }

    // MARK: - 性能监看面板（Tab）

    func setStatsVisible(_ visible: Bool) {
        visible ? statsPanel.show() : statsPanel.hide()
    }

    func toggleStatsPanel() {
        statsPanel.toggle()
        // 打开的那一刻立刻拉一次，而不是等 0.5s 后的第一拍 ——
        // 面板刚弹出来时是空的（六个 label 的初值都是 ""）看着像坏了。
        if statsPanel.isShown { statsPanel.refreshNow() }
    }

    /// `MP_DUMP_STATS` 用：把面板当前文本原样导出（不要求面板可见）。
    func dumpStatsState() -> String { statsPanel.dumpText() }

    func refreshStatsPanel() { statsPanel.refreshNow() }
    /// 与真实实现逐条对应：换文件后清掉 FPS 采样历史。
    func resetStatsSampling() { statsPanel.resetSampling() }

    // MARK: - 对外只读状态

    var currentURL: URL? { engine.url }
    var isCaptureMode: Bool { engine.isCaptureMode }

    /// dev：采集链路的**实测**诊断（`MP_CAPTURE_GO` 用）。
    /// 面板上已经能看到这些值，但文本形式更适合在日志里做前后对比。
    func captureDiagnosticsText() -> String {
        guard engine.isCaptureMode else { return "\n[采集诊断] 当前不在采集模式\n" }
        let stats = statsPanel.currentRuntimeStats()
        return String(format: "\n[采集诊断] 实测投递 %.2f fps | 渲染 %.2f fps | 上屏 %d 帧 | 丢帧 %d\n  色彩: %@\n  队列: %@\n",
                      stats.captureDeliveredFPS, stats.renderFPS,
                      stats.presentedFrames, stats.droppedFrames,
                      stats.captureColorInfo,
                      String(describing: stats.queues))
    }
    var isPlaying: Bool { engine.isPlaying }
    var tracks: [TrackInfo] { engine.tracks }
    var audioTracks: [TrackInfo] { engine.audioTracks }
    var subtitleTracks: [TrackInfo] { engine.subtitleTracks }
    var currentAudioStreamIndex: Int? { engine.currentAudioStreamIndex }
    var selectedAudioStreamIndex: Int { engine.selectedAudioStreamIndex }
    var currentSubtitleStreamIndex: Int? { engine.currentSubtitleStreamIndex }
    /// 选中的字幕流索引（-1 = 关闭）。菜单回显勾选状态用这个而不是上面那个 ——
    /// 「关闭字幕」也是一种被选中的状态，只是它的索引是 -1。
    var selectedSubtitleStreamIndex: Int { engine.selectedSubtitleStreamIndex }
    /// 当前加载的外挂字幕文件名（没有则为 nil）。菜单里要显示「外挂：xxx」，
    /// 否则外挂生效时所有内封轨都不带勾，看起来像字幕坏了。
    var externalSubtitleName: String? { engine.externalSubtitleName }
    var currentTime: Double { engine.currentTime }
    var duration: Double { engine.duration }

    /// 控制条状态快照（`MP_DUMP_UI`）。转发给 ControlOverlayView 自己那份。
    func dumpOverlayState() -> String { overlay.dumpState() }

    // MARK: - 音轨控制（Phase 3.5）

    /// 选一条内封音轨。
    func selectAudioTrack(_ index: Int) { engine.selectAudioTrack(index) }

    // MARK: - 字幕控制（Phase 3）

    /// 选一条内封字幕轨。`-1` = 关闭字幕。
    func selectSubtitleTrack(_ index: Int) { engine.selectSubtitleTrack(index) }
    func disableSubtitles() { engine.disableSubtitles() }
    func loadExternalSubtitle(url: URL) { engine.loadExternalSubtitle(url: url) }

    /// dev：把「此刻的字幕层」取出来（`--subtitle-png` 用）。渲染循环不走这里。
    func subtitleSnapshotForExport() -> (bitmap: SubtitleBitmap, width: Int, height: Int)? {
        let size = engine.videoSize
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0,
              let bmp = engine.subtitleSnapshot(at: engine.currentTime,
                                                width: width, height: height)
        else { return nil }
        return (bmp, width, height)
    }

    /// dev：导出性能面板位图（`--stats-png` 用）。
    func statsPanelSnapshotForExport() -> CGImage? { statsPanel.snapshotForExport() }
    /// dev：面板与六个文本控件的真实 frame（`--stats-png` 一并打出）。
    /// 两套构建都要有 —— 面板在占位构建下同样能显示，诊断也该一致。
    func statsPanelFramesText() -> String { statsPanel.framesDebugText() }
    /// dev：底部控制条上每个控件的真实 frame（`--dump-frames` 用）。
    func overlayFramesText() -> String { overlay.framesDebugText() }
    /// dev：导出底部控制条位图（`--overlay-png`）。
    /// 导出前先把 alpha 拉回 1 —— 理由见占位构建里同名方法的注释
    ///（控制条会自动隐藏，alpha 为 0 时渲染不出任何像素）。
    func overlaySnapshotForExport() -> CGImage? {
        overlay.alphaValue = 1
        return ViewSnapshot.layerImage(of: overlay)
    }
    /// dev：控制条配色证据（白画面下看不看得清）。
    func overlayAppearanceText() -> String { overlay.appearanceDebugText() }

    /// 字幕层状态快照（`MP_DUMP_STATS`）。
    ///
    /// 分三行，因为这三行回答的是不同的问题：
    ///   · 引擎 —— 字幕轨接上了没有、libass 可不可用、track 里攒了几条事件
    ///   · 已上传 —— **渲染循环真实走过的那条路**产出了什么（这是可信证据）
    ///   · 主动 —— 强制再合成一次当前时刻，拿到像素级数字（叠了几张图、
    ///     多少不透明像素、峰值颜色）
    ///
    /// 「主动」那一行刻意走 `subtitleSnapshot` 而不是 `renderSubtitle`：
    /// 后者在「本帧与上一帧相同」时返回 nil（那是渲染循环要的语义），
    /// 而 dump 时这一帧往往已被循环消费过，会拿到 nil、什么证据都没有。
    ///
    /// 峰值颜色是刻意加的：测试片里三句字幕分别是白 / 纯红 / 纯绿，
    /// 于是「现在显示的是第几句」可以被程序化地判定，不必靠人眼看截图。
    func subtitleDumpText() -> String {
        var lines: [String] = []
        lines.append("引擎    \(engine.subtitleDebugSummary)")
        lines.append("已上传  \(renderView.lastSubtitleStats)")

        let size = engine.videoSize
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())
        guard width > 0, height > 0 else { return lines.joined(separator: "\n") }

        guard let bmp = engine.subtitleSnapshot(at: engine.currentTime,
                                                width: width, height: height) else {
            // 没有渲染器。可能是字幕被关掉了、这个文件根本没有字幕轨，
            // 也可能是 libass 初始化失败 —— 具体是哪种，上一行的「引擎」已经写清楚了，
            // 这里不猜，只如实说「拿不到位图」。
            lines.append(String(format: "主动     %.3fs · 没有渲染器，取不到位图", engine.currentTime))
            return lines.joined(separator: "\n")
        }

        var opaque = 0
        var peakR = 0, peakG = 0, peakB = 0
        var i = 0
        while i + 3 < bmp.pixels.count {
            // BGRA 顺序
            if bmp.pixels[i + 3] != 0 {
                opaque += 1
                peakB = max(peakB, Int(bmp.pixels[i]))
                peakG = max(peakG, Int(bmp.pixels[i + 1]))
                peakR = max(peakR, Int(bmp.pixels[i + 2]))
            }
            i += 4
        }
        // 叠图数为 0 = 这一时刻本来就没有字幕（时间轴的空档），这是**合法结果**，
        // 不是失败 —— 与「有字幕但没画出来」是两件事，故单独标出来。
        let verdict = bmp.imageCount == 0 ? " · 此刻无字幕（时间轴空档）" : ""
        lines.append(String(format: "主动     %.3fs · %dx%d · 叠图 %d 张 · 不透明像素 %d · 峰值 RGB(%d,%d,%d) → %@%@",
                            engine.currentTime, bmp.width, bmp.height,
                            bmp.imageCount, opaque, peakR, peakG, peakB,
                            Self.describePeakColor(peakR, peakG, peakB), verdict))
        return lines.joined(separator: "\n")
    }

    /// 把峰值颜色说成一个人能读的色名。
    ///
    /// **只为 dump 的可读性**：判定「第几句」仍以原始 RGB 为准，
    /// 这样这个函数即使判断粗糙，也不会把结论带跑。
    private static func describePeakColor(_ r: Int, _ g: Int, _ b: Int) -> String {
        guard max(r, g, b) > 0 else { return "无彩色" }
        if abs(r - g) < 24 && abs(g - b) < 24 { return r > 180 ? "白" : "灰" }
        if r > g && r > b { return "红" }
        if g > r && g > b { return "绿" }
        if b > r && b > g { return "蓝" }
        return "混色"
    }

    // MARK: - 打开

    /// 由 AppDelegate 在窗口就绪后调用。优先级：`MP_OPEN_FILE` → 命令行参数。
    func openLaunchFileIfNeeded() {
        let env = ProcessInfo.processInfo.environment["MP_OPEN_FILE"]
        var candidate: String? = (env?.isEmpty == false) ? env : nil
        if candidate == nil {
            candidate = CommandLine.arguments.dropFirst().first { argument in
                !argument.hasPrefix("-")
                    && Self.mediaExtensions.contains(
                        (argument as NSString).pathExtension.lowercased())
            }
        }
        guard let path = candidate else { return }
        open(url: URL(fileURLWithPath: path))
    }

    /// 「文件 → 打开视频…」以及 ⌘O。走响应链，target 留空即可。
    @objc func openDocumentAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = L10n.t("open_video")
        panel.message = L10n.t("choose_video_file")
        // 不限制类型：能播什么由 FFmpeg 决定。用系统 UTType 过滤反而会把
        // mkv / rmvb / m2ts 这类挡在外面（Phase 1 踩过）。
        panel.allowedContentTypes = []
        panel.begin { [weak self] response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            self?.open(urls: panel.urls, startIndex: 0)
        }
    }

    func open(urls: [URL], startIndex: Int) {
        guard !urls.isEmpty else { return }
        let index = max(0, min(startIndex, urls.count - 1))
        open(url: urls[index])
    }

    func open(url: URL) {
        saveCurrentProgressIfNeeded()
        let isSwitchingMedia = (engine.url != nil)
        if engine.isPlaying {
            engine.pause()
        }
        isReloadingPipeline = false
        showStatusPill(isSwitchingMedia ? "正在重载并切换视频 \(url.lastPathComponent) …" : "正在打开 \(url.lastPathComponent) …", autoHideDelay: nil)
        renderView.clearFrame()
        overlay.setTime(current: 0, duration: 0)
        overlay.setPlaying(false)
        resetStatsSampling()
        updateInfoLabel()

        mediaOpenQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.engine.open(url: url)
                let saved = PlaybackProgressManager.shared.progress(for: url.lastPathComponent)
                let shouldResume = (saved != nil && saved! > 5.0 && (self.engine.duration <= 0 || saved! < self.engine.duration - 10.0))
                if shouldResume, let resumeTime = saved {
                    self.engine.seek(to: resumeTime)
                }
                DispatchQueue.main.async {
                    // ⚠️ noteRecent 必须在这里（主线程）调，不能在上面那行后面直接调。
                    //
                    // 踩过的坑（真崩溃，P0）：它内部会写 UserDefaults 并发
                    // `.playbackSettingsDidChange` → AppDelegate 去重建主菜单。
                    // 在后台线程动主菜单，AppKit 直接抛
                    //     "modification of a menu's items on a non-main thread
                    //      when the menu is part of the main menu"
                    // 然后整个 app 挂掉。只有真的打开文件才会走到这一行，所以
                    // 「不打开文件的冒烟测试」全都测不出来。
                    PlaybackSettings.shared.noteRecent(url)
                    self.hideStatusPill()
                    self.overlay.setEnabled(true)
                    self.overlay.setPlaying(true)
                    let currentPos = (shouldResume && saved != nil) ? saved! : 0
                    self.overlay.setTime(current: currentPos, duration: self.engine.duration)
                    self.updateInfoLabel()
                    let s = PlaybackSettings.shared
                    self.renderView.updatePreferredFPS(for: s.rifeRateMode, sourceFPS: self.engine.detail.video?.frameRate ?? 24)
                    self.onCurrentURLChanged?(url)
                    self.onPlaybackStateChanged?(true)
                    self.applyVolumeFromSettings()
                    // 换源了：性能面板的采样历史作废，参数快照也换了新的
                    self.resetStatsSampling()
                    if shouldResume, let resumeTime = saved {
                        let timeStr = PlaybackProgressManager.formatTime(resumeTime)
                        self.showStatusPill("已恢复上次播放进度 \(timeStr)", autoHideDelay: 2.5)
                    } else if isSwitchingMedia {
                        self.showStatusPill("已自动重载并切换到：\(url.lastPathComponent)", autoHideDelay: 2.0)
                    }
                    // 原版打开后会自动让控制条淡出，把画面让出来
                    self.showOverlay()
                    self.scheduleHideOverlay(delay: self.overlayHideDelay,
                                             hideCursorWhenDone: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.overlay.setEnabled(false)
                    self.onCurrentURLChanged?(nil)
                    self.showStatusPill(error.localizedDescription, autoHideDelay: nil)
                    self.presentError(error, url: url)
                }
            }
        }
    }

    func openCapture(videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice?,
                     format: AVCaptureDevice.Format?, fps: Double, frameDuration: CMTime?) {
        showStatusPill("正在连接采集卡 \(videoDevice.localizedName) …", autoHideDelay: nil)
        renderView.clearFrame()

        mediaOpenQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.engine.openCapture(videoDevice: videoDevice, audioDevice: audioDevice,
                                            format: format, fps: fps, frameDuration: frameDuration)
                DispatchQueue.main.async {
                    self.hideStatusPill()
                    self.overlay.setEnabled(true)
                    self.overlay.setPlaying(true)
                    self.overlay.setTime(current: 0, duration: 0)
                    self.updateInfoLabel()
                    self.onPlaybackStateChanged?(true)
                    self.resetStatsSampling()
                    self.showOverlay()
                    self.scheduleHideOverlay(delay: self.overlayHideDelay, hideCursorWhenDone: true)
                    let fakeMode = PlaybackSettings.shared.fake60FPSOptimization.title
                    let latencyMode = PlaybackSettings.shared.captureLowLatencyMode.title
                    self.showStatusPill("🟢 采集卡已启动: \(videoDevice.localizedName) · \(latencyMode) · 假60重构[\(fakeMode)]", autoHideDelay: 3.5)
                }
            } catch {
                DispatchQueue.main.async {
                    self.overlay.setEnabled(false)
                    self.showStatusPill("采集卡启动失败: \(error.localizedDescription)", autoHideDelay: 3.0)
                }
            }
        }
    }

    /// 退出前的收尾：只做「进度落盘 + 停引擎 + 清帧」，**不碰 UI、不发回调**。
    ///
    /// 为什么不直接复用 `closeCurrent()`：`applicationWillTerminate` 触发时，
    /// 窗口往往已经被关窗流程走过一遍了（用户点红点 → AppKit 收尾 → 才走到 terminate）。
    /// 这时 `showStatusPill` / `overlay.setEnabled` / `playlistPanel.setItems` 是在给一棵
    /// 正在拆的视图树发消息，而 `onCurrentURLChanged?(nil)` 会一路走到
    /// `PlayerWindowController` 里设窗口标题 —— 那正是崩溃点（见 2026-10-27 崩溃报告）。
    ///
    /// 退出真正需要的只有三件事：进度别丢、线程别留着、Metal 帧别挂着。
    func shutdownForTermination() {
        saveCurrentProgressIfNeeded()
        engine.shutdown()
        renderView.clearFrame()
    }

    func closeCurrent() {
        saveCurrentProgressIfNeeded()
        engine.shutdown()
        renderView.clearFrame()
        overlay.setEnabled(false)
        overlay.setPlaying(false)
        playlistPanel.setItems([], currentIndex: -1)
        updateInfoLabel()
        resetStatsSampling()
        showStatusPill(L10n.t("no_video_opened"), autoHideDelay: nil)
        onCurrentURLChanged?(nil)
        onPlaybackStateChanged?(false)
    }

    private func presentError(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法打开 \(url.lastPathComponent)"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L10n.t("ok"))
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    // MARK: - 播放控制

    func togglePlayPause() {
        guard engine.url != nil else { return }
        engine.togglePlayPause()
        overlay.setPlaying(engine.isPlaying)
        onPlaybackStateChanged?(engine.isPlaying)
    }

    func seek(to seconds: Double) {
        guard engine.url != nil else { return }
        let target = max(0, min(engine.duration > 0 ? engine.duration : seconds, seconds))
        engine.seek(to: target)
        saveCurrentProgressIfNeeded(overrideTime: target)
    }

    func seekRelative(_ delta: Double) {
        guard engine.url != nil else { return }
        let target = max(0, min(engine.duration, engine.currentTime + delta))
        seek(to: target)
    }

    // MARK: - 播放进度持久化

    private func saveCurrentProgressIfNeeded(overrideTime: Double? = nil) {
        guard let url = engine.url, !engine.isCaptureMode else { return }
        if engine.state == .ended {
            PlaybackProgressManager.shared.clearProgress(for: url.lastPathComponent)
            return
        }
        let time = overrideTime ?? engine.currentTime
        let duration = engine.duration
        PlaybackProgressManager.shared.saveProgress(for: url.lastPathComponent, time: time, duration: duration)
        lastProgressSaveTime = time
        lastProgressSaveWallClock = Date().timeIntervalSinceReferenceDate
    }

    /// 重新载入当前视频并恢复进度（对应重载按钮与 Cmd+R）
    func reloadCurrentMedia() {
        guard engine.url != nil else { return }
        guard !isReloadingPipeline else { return }
        isReloadingPipeline = true
        showStatusPill("正在重新载入视频并恢复进度…", autoHideDelay: 2.0)

        mediaOpenQueue.async { [weak self] in
            guard let self else { return }
            let ok = self.engine.reloadInPlace()
            DispatchQueue.main.async {
                self.isReloadingPipeline = false
                guard ok else {
                    self.showStatusPill("重载视频失败", autoHideDelay: 2.0)
                    return
                }
                self.resetStatsSampling()
                self.overlay.setPlaying(self.engine.isPlaying)
                self.overlay.setTime(current: self.engine.currentTime,
                                     duration: self.engine.duration)
                self.updateInfoLabel()
                self.showStatusPill("已重新载入视频 (恢复进度)", autoHideDelay: 2.0)
            }
        }
    }

    func setVolume(_ v: Float) {
        let clamped = max(0, min(1, v))
        engine.volume = clamped
        PlaybackSettings.shared.volume = clamped
    }

    /// 增量调整音量（方向键上下、滚轮驱动），并弹出音量 HUD 提示
    func adjustVolume(by delta: Float) {
        let current = PlaybackSettings.shared.volume
        let newVolume = max(0, min(1, current + delta))
        setVolume(newVolume)
        showVolumeStatusPill(newVolume)
        showOverlay()
        scheduleHideOverlay(delay: overlayHideDelay, hideCursorWhenDone: false)
    }

    private func showVolumeStatusPill(_ v: Float) {
        let pct = Int(round(v * 100))
        let icon: String
        if pct <= 0 {
            icon = "🔇"
        } else if pct < 33 {
            icon = "🔈"
        } else if pct < 66 {
            icon = "🔉"
        } else {
            icon = "🔊"
        }
        showStatusPill("\(icon) 音量: \(pct)%", autoHideDelay: 1.2)
    }

    private func applyVolumeFromSettings() {
        let v = PlaybackSettings.shared.volume
        engine.volume = v
        overlay.refreshFromSettings()
    }

    // MARK: - 四个档位（Phase 2：状态 + 回显；后端分属 Phase 4/5）

    private func cycleRIFERate() {
        applyRIFERate(PlaybackSettings.shared.rifeRateMode.next)
    }

    private func applyRIFERate(_ mode: RIFERateMode) {
        PlaybackSettings.shared.rifeRateMode = mode
        let srcFPS = engine.detail.video?.frameRate ?? 24.0
        renderView.updatePreferredFPS(for: mode, sourceFPS: srcFPS)
        refreshStatsPanel()
        if mode == .off {
            showStatusPill(mode.statusTitle, autoHideDelay: 1.8)
        } else {
            showStatusPill("\(mode.statusTitle) · AI 补帧已生效", autoHideDelay: 2.0)
        }
    }

    /// 弹出 RIFE AI 补帧详细配置面板
    func openRIFEConfig() {
        RIFEConfigPanelController.shared.show(relativeTo: window)
    }

    private func cycleMetalFX() {
        let all = MetalFXOption.allCases
        let cur = PlaybackSettings.shared.metalFX
        let next = all[(all.firstIndex(of: cur).map { $0 + 1 } ?? 0) % all.count]
        applyMetalFX(next)
    }

    private func applyMetalFX(_ option: MetalFXOption) {
        PlaybackSettings.shared.metalFX = option
        showStatusPill(option == .off
                       ? option.title
                       : "\(option.title) · 已启用",
                       autoHideDelay: 2.0)
    }

    private func applyAnime4K(_ option: Anime4KOption) {
        PlaybackSettings.shared.anime4k = option
        showStatusPill(option == .off
                       ? L10n.t("anime4k_off")
                       : "\(L10n.t("anime4k_panel_title")) · 已启用",
                       autoHideDelay: 2.0)
    }

    private func applyDecodeMode(_ mode: DecodeMode) {
        PlaybackSettings.shared.decodeMode = mode
        showStatusPill(mode.title, autoHideDelay: 1.6)
    }

    @objc private func settingsDidChange(_ note: Notification) {
        // 同 AppDelegate.settingsDidChange：改的是 UI，必须在主线程。
        // 后台线程写设置是允许的，所以这道守卫不能省。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.settingsDidChange(note) }
            return
        }
        overlay.refreshFromSettings()
        // ② 那一节直接读设置，改完当场就要反映出来 —— 否则面板上还写着旧档位
        refreshStatsPanel()

        let s = PlaybackSettings.shared
        renderView.updatePreferredFPS(for: s.rifeRateMode, sourceFPS: engine.detail.video?.frameRate ?? 24)

        // ---- 热切换：影响管线的设置就地重建，不再弹「下次重启生效」
        guard let key = note.userInfo?["key"] as? PlaybackSettings.Key,
              key.affectsPipeline else { return }
        reloadPipeline(for: key)
    }

    /// 正在重建管线的标记。
    ///
    /// 为什么需要：用户可能连着点菜单（RIFE 档位 + 模型 + 核心数），每一次都触发
    /// 一遍「拆管线 → 重开文件」。上一次还没建完就再来一次，两拨线程会同时操作
    /// 同一个 `AVFormatContext` —— 那是 `av_assert0` 级别的崩。所以同一时刻只允许一次，
    /// 后来者直接丢掉（不是排队：排队也只是把同一件事连做 N 遍，没有意义）。
    private var isReloadingPipeline = false

    /// 把管线就地重建一遍。
    ///
    /// 三件必须做对的事：
    ///  1. **在后台线程做** —— `reloadInPlace()` 内部要重新建解封装/解码线程、
    ///     重开文件，同步做会把主线程卡住（打开大文件时是肉眼可见的卡顿）。
    ///  2. **并发去重** —— 见 `isReloadingPipeline`。
    ///  3. **回到主线程收尾** —— 控制条与面板都是 AppKit 对象，只能在主线程碰。
    private func reloadPipeline(for key: PlaybackSettings.Key) {
        // 没开文件时「影响管线」的设置也只是存了个档位，下次打开才生效 —— 不用重建。
        guard engine.url != nil else { return }
        guard !isReloadingPipeline else { return }
        isReloadingPipeline = true
        showStatusPill(MPText.t("正在就地应用：\(key.humanTitle) …",
                                "Applying in place: \(key.humanTitle) …"),
                       autoHideDelay: 1.4)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ok = self.engine.reloadInPlace()
            DispatchQueue.main.async {
                self.isReloadingPipeline = false
                guard ok else { return }
                // 计数器在新管线里从零开始，采样历史必须跟着清
                self.resetStatsSampling()
                self.overlay.setPlaying(self.engine.isPlaying)
                self.overlay.setTime(current: self.engine.currentTime,
                                     duration: self.engine.duration)
                self.updateInfoLabel()
                self.showStatusPill(MPText.t("已就地生效：\(key.humanTitle)（未重启 APP）",
                                             "Applied in place: \(key.humanTitle) (no restart)"),
                                    autoHideDelay: 2.0)
            }
        }
    }

    // MARK: - 覆盖层与状态胶囊

    /// showOverlay（观测方法）。
    func showOverlay() {
        cursorHideWorkItem?.cancel()
        cursorHideWorkItem = nil
        showCursorIfNeeded()
        guard overlay.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            overlay.animator().alphaValue = 1
        }
    }

    /// scheduleHideOverlay（观测方法）。
    func scheduleHideOverlay(delay: Double, hideCursorWhenDone: Bool) {
        cursorHideWorkItem?.cancel()
        guard !cursorAutoHideSuspended else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.cursorAutoHideSuspended else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                self.overlay.animator().alphaValue = 0
            }
            if hideCursorWhenDone { self.hideCursorIfNeeded() }
        }
        cursorHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 开始与覆盖层交互（鼠标进到控制条上）：暂停自动隐藏。
    func beginOverlayInteraction() {
        cursorAutoHideSuspended = true
        showOverlay()
    }

    func endOverlayInteraction() {
        cursorAutoHideSuspended = false
        scheduleHideOverlay(delay: overlayHideDelay, hideCursorWhenDone: true)
    }

    func hideCursorIfNeeded() {
        guard !isCursorHidden else { return }
        isCursorHidden = true
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func showCursorIfNeeded() {
        guard isCursorHidden else { return }
        isCursorHidden = false
        NSCursor.unhide()
    }

    /// showStatusPill（观测方法）。
    /// - Parameter autoHideDelay: 传 nil 表示常驻（例如「未打开视频」）。
    func showStatusPill(_ text: String, autoHideDelay: Double?) {        statusHideWorkItem?.cancel()
        statusHideWorkItem = nil
        statusLabel.stringValue = text
        statusPill.alphaValue = 1
        guard let delay = autoHideDelay else { return }
        let work = DispatchWorkItem { [weak self] in self?.hideStatusPill() }
        statusHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// hideStatusPill（观测方法）。
    func hideStatusPill() {
        statusHideWorkItem?.cancel()
        statusHideWorkItem = nil
        statusPill.alphaValue = 0
    }

    // MARK: - 鼠标 / 键盘 / 拖放

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreaRef { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .mouseMoved,
                                         .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingAreaRef = t
    }

    override func mouseMoved(with event: NSEvent) {
        showOverlay()
        scheduleHideOverlay(delay: overlayHideDelay, hideCursorWhenDone: true)
    }

    override func mouseExited(with event: NSEvent) {
        scheduleHideOverlay(delay: 0.8, hideCursorWhenDone: true)
    }

    override func mouseDown(with event: NSEvent) {
        // 点画面：切换播放/暂停（原版按 `mouseDown(with:)` 的观测签名有此成员）
        if event.clickCount == 2 {
            onToggleFullscreenRequested?()
        } else {
            togglePlayPause()
        }
    }

    override func keyDown(with event: NSEvent) {
        // 注意：**Tab 不在这里处理**。窗口里只要存在别的可聚焦控件（控制条上的
        // 滑块与按钮都算），NSWindow 会在事件送到 `keyDown` 之前就把 Tab 截走、
        // 拿去做 key view loop 的焦点切换 —— 写在这里的 `case 48:` 永远收不到。
        // Tab 走 `installTabMonitor()` 装的那条本地事件监视器。
        switch event.keyCode {
        case 49:                    // space
            togglePlayPause()
        case 123:                   // ←
            seekRelative(-5)
        case 124:                   // →
            seekRelative(5)
        case 125:                   // ↓ 方向键下：降低音量
            adjustVolume(by: -0.05)
        case 126:                   // ↑ 方向键上：增加音量
            adjustVolume(by: 0.05)
        case 53:                    // esc
            window?.toggleFullScreen(nil)
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - 滚轮与手势调整音量

    override func scrollWheel(with event: NSEvent) {
        // 若鼠标在播放列表面板或性能监看面板内且处于显示状态，交由面板原生滚动
        let mouseInView = convert(event.locationInWindow, from: nil)
        if playlistPanel.isShown && playlistPanel.frame.contains(mouseInView) {
            super.scrollWheel(with: event)
            return
        }
        if statsPanel.isShown && statsPanel.frame.contains(mouseInView) {
            super.scrollWheel(with: event)
            return
        }
        // 滚轮调整音量：支持高精度触控板平滑滑动与传统带刻度鼠标滚轮
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        guard abs(deltaY) > 0.01 else { return }
        let step: Float = event.hasPreciseScrollingDeltas
            ? Float(deltaY) * 0.0025
            : (deltaY > 0 ? 0.05 : -0.05)
        adjustVolume(by: step)
    }

    // MARK: - Tab：性能监看面板与上下方向键监看

    /// Tab 键与方向键的本地事件监视器令牌（`deinit` 里要还回去，否则闭包长期持有 self）。
    private var tabMonitor: Any?

    /// 装 Tab 监视器与上下键音量监视器。
    ///
    /// 为什么不用 `keyDown(with:)`：见上面那段注释 —— NSWindow 先吃 Tab。
    /// 监视器在**事件分发之前**拦截，所以与「谁是 first responder」彻底无关。
    /// 返回 `nil` = 「这条我吃了」，事件不再往下发（也就不会触发焦点切换）。
    private func installTabMonitor() {
        tabMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 只认「本窗口的裸按键」。⌘/⌥/⌃ 是系统与菜单的快捷键，抢掉会打架。
            guard event.window === self.window,
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            else { return event }

            if event.keyCode == 48 { // Tab
                self.toggleStatsPanel()
                return nil
            } else if event.keyCode == 126 { // ↑ 方向键上：增加音量
                self.adjustVolume(by: 0.05)
                return nil
            } else if event.keyCode == 125 { // ↓ 方向键下：降低音量
                self.adjustVolume(by: -0.05)
                return nil
            }
            return event
        }
    }

    private func removeTabMonitor() {
        if let monitor = tabMonitor {
            NSEvent.removeMonitor(monitor)
            tabMonitor = nil
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard draggedURL(from: sender) != nil else { return [] }
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let url = draggedURL(from: sender) else { return false }
        let ext = url.pathExtension.lowercased()
        if SubtitleFormat.supportedExtensions.contains(ext) {
            loadExternalSubtitle(url: url)
            showStatusPill("已加载字幕: \(url.lastPathComponent)", autoHideDelay: 2.5)
        } else if Self.mediaExtensions.contains(ext) {
            if let onFileDrop {
                onFileDrop(url)
            } else {
                open(url: url)
            }
        } else if ext == "json" {
            // 丢进来一个播放列表文件 → 交给窗口控制器
            onPlaylistAppend?([url])
        } else {
            if let onFileDrop {
                onFileDrop(url)
            } else {
                open(url: url)      // 让 FFmpeg 去判，别用扩展名挡
            }
        }
        return true
    }

    private func draggedURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options) as? [URL] else { return nil }
        return urls.first
    }

    // MARK: - PlaybackEngineDelegate

    func playbackEngine(_ engine: PlaybackEngine, didChange state: PlaybackState) {
        overlay.setPlaying(engine.isPlaying)
        onPlaybackStateChanged?(engine.isPlaying)
        if state == .paused {
            saveCurrentProgressIfNeeded()
        } else if state == .ended {
            if let name = engine.url?.lastPathComponent {
                PlaybackProgressManager.shared.clearProgress(for: name)
            }
        }
        if case .failed(let message) = state {
            showStatusPill(message, autoHideDelay: nil)
        }
        updateInfoLabel()
    }

    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double, duration: Double) {
        overlay.setTime(current: time, duration: duration)
        updateInfoLabel()

        // 节流写入播放进度：播放中每 3 秒且时间前进超 1 秒更新一次
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastProgressSaveWallClock >= 3.0 && abs(time - lastProgressSaveTime) >= 1.0 {
            if let name = engine.url?.lastPathComponent, !engine.isCaptureMode, engine.state == .playing {
                PlaybackProgressManager.shared.saveProgress(for: name, time: time, duration: duration)
                lastProgressSaveTime = time
                lastProgressSaveWallClock = now
            }
        }
    }

    // MARK: - 信息条（dev only）

    private func updateInfoLabel() {
        guard showsInfo else { return }
        guard engine.url != nil || engine.isCaptureMode else { infoLabel.stringValue = ""; return }
        var lines: [String] = []
        if !engine.sourceInfo.isEmpty { lines.append(engine.sourceInfo) }
        switch engine.state {
        case .playing:             lines.append("状态：播放中（音频时钟同步）")
        case .paused:              lines.append("状态：已暂停")
        case .ended:               lines.append("状态：播放结束")
        case .opening:             lines.append("状态：打开中")
        case .idle:                lines.append("状态：空闲")
        case .failed(let message): lines.append("状态：失败 — \(message)")
        }
        let s = PlaybackSettings.shared
        lines.append("档位：\(s.rifeRateMode.statusTitle) · \(s.metalFX.title) · "
                     + "\(s.anime4k.title) · \(s.decodeMode.title)")
        infoLabel.stringValue = lines.joined(separator: "\n")
    }
}

#endif

// MARK: - 两种构建共用的媒体扩展名白名单
//
// 为什么放在 `#if` 之外：`PlayerContainerView` 在 `USE_FFMPEG` 开/关两套构建下
// 是**两个独立定义**，接口必须逐条一致。这份白名单两边都要用（打开面板、目录扫描、
// 拖放判定），写在 `#if` 里就得写两份、迟早写歪 —— 上一轮就是这么漏掉一条、
// 关 FFmpeg 时编不过的。用 extension 挂在同一个类型名上，两种构建共享同一份。
extension PlayerContainerView {

    /// 「什么算媒体文件」。**只用于面板初筛与目录扫描**，不作为「能不能播」的判据 ——
    /// 真判据是 FFmpeg 能不能解码（mkv / rmvb / m2ts 这类系统 UTType 不认，别挡）。
    static let mediaExtensions: Set<String> = [
        "mkv", "mp4", "mov", "m4v", "avi", "ts", "m2ts", "mts", "webm", "flv",
        "wmv", "mpg", "mpeg", "vob", "rmvb", "rm", "3gp", "ogv", "mxf",
    ]

    /// 性能监看面板的宽度。定宽而不是自适应，有两个原因：
    ///  1. 面板里一行一条读数，宽度会随数字位数变（`帧 99` → `帧 123456`），
    ///     自适应会让整块面板每 0.5s 抖一下；
    ///  2. 460pt 是按「最长的一行放得下」量出来的：`像素 yuv420p · 码率 3.50 Mb/s ·
    ///     色彩 bt709/bt709/bt709/tv` 在 11pt 等宽下约 62 列，减去左右各 12pt 内边距
    ///     还有 436pt ≈ 66 列，留一点余量。
    ///    （超过的话不要紧：正文按 `byTruncatingTail` 截断，不会把面板撑变形。）
    /// 两种构建共用同一个值 —— 它写在 `#if` 之外，就是为了两套定义不会各写一个数。
    static let statsPanelWidth: CGFloat = 460
}
