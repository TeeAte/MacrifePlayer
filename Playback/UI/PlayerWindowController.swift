//  PlayerWindowController.swift
//  MetalPlayer 重建工程 —— 窗口与播放列表控制器（Phase 2）
//
//  原版骨架观测到的成员方法（全部按原签名实现，行为是本工程自己的）：
//
//      setPlaylistURLs([URL], startIndex: Int, appendToRecent: Bool)
//      appendVideosToPlaylist([URL])
//      playPlaylistIndex(Int)          deletePlaylistIndex(Int)
//      movePlaylistItem(from:to:)
//      openVideo(URL)                  openVideos([URL])   openVideoWithPanel()
//      openPlaylistWithPanel()         savePlaylistWithPanel()
//      closeCurrentVideo()             toggleFullscreen()
//      setWindowChromeVisible(Bool)
//      openSubtitleFile(URL)           presentPlaybackFailureAlert(String)
//      openAnime4KPanel()              openNetworkStreamWithPanel()
//      openWindowCaptureWithPanel()    openNetworkStream(url:options:)
//      openWindowCapture(ScreenCaptureSource)
//
//  从这串清单可以读出原版的**职责划分**：
//  菜单项的名字（`open_video` / `show_playlist` / `save_playlist` / …）属于 AppDelegate，
//  而「打开面板 → 拿到 URL → 处理」这一层在 PlayerWindowController。
//  本工程照这个切法实现，所以 AppDelegate 里全是菜单，这个类里全是「干活」。
//
//  ⚠️ 分阶段状态：
//      Phase 2 已实现：打开/关闭/播放列表增删排序/存读/全屏/最近打开的落库
//      Phase 3 起：字幕（`openSubtitleFile`）
//      Phase 5 起：Anime4K 面板、网络流、采集（现在给如实的「未接入」提示）

import Foundation
import AppKit
import AVFoundation

final class PlayerWindowController: NSObject, NSWindowDelegate {

    // MARK: 组成

    private(set) var window: NSWindow
    let container: PlayerContainerView

    // MARK: 播放列表

    private(set) var playlistItems: [PlaylistItem] = []
    private(set) var currentPlaylistIndex = -1
    /// 当前播放列表对应的文件（用于「保存」时默认路径）。
    private var playlistFileURL: URL?

    /// 列表变化（增删排序/换曲）→ AppDelegate 刷新「最近打开」以外的东西（标题等）。
    var onPlaylistChanged: (() -> Void)?
    /// 当前曲目变化 → 窗口标题跟着改。
    var onCurrentChanged: ((URL?) -> Void)?

    // MARK: 窗口外框

    private var chromeVisible = true

    // MARK: - 构造

    /// 原版骨架的签名是 `init(startupChecked: ()) throws` —— 那个 `()` 是 demangle 出来的
    /// 参数类型，原始形态大概率是一个枚举（启动自检结果）。重建工程不需要它，
    /// 所以用一个无参 init，并在注释里留了这条观测。
    override init() {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 720)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        container = PlayerContainerView(frame: rect)
        super.init()

        window.title = "Macrife Player"
        // 最小尺寸从 720x440 提到 900x600 —— 这不是随手改的数，两个方向各有理由：
        //
        //  宽 900：控制条里**定宽**的部件合计约 664pt（左右内边距 24 + 播放/后退/前进
        //    88 + 三个档位按钮 274 + 解码胶囊 ≥58 + 音量图标 15 + 音量滑块 84 +
        //    播放列表/全屏 60 + 各处间距约 60）。720 宽时留给「时间标签 + 进度条」
        //    的只有 56pt，进度条会被压到十几像素 —— 虽然不再重叠（优先级改造见
        //    `ControlOverlayView.installLayout`），但那样已经没法拖了。
        //    900 宽能留出 236pt：时间标签 104 + 进度条 132，是个能用的最小值。
        //
        //  高 600：性能监看面板（Tab）在左上角，内容约 355pt 高，而它必须
        //    **让开底部控制条**（这条是 required 约束）。440 高时扣掉控制条只剩
        //    342pt，面板下沿会被裁掉两三行读数。600 高时可用约 502pt，够放。
        window.minSize = NSSize(width: 900, height: 600)
        window.contentView = container
        window.delegate = self
        window.setFrameAutosaveName("MPMainWindow")
        window.center()

        // 容器 → 控制器
        container.onToggleFullscreenRequested = { [weak self] in self?.toggleFullscreen() }
        container.onCurrentURLChanged = { [weak self] url in
            guard let self else { return }
            self.window.title = url?.lastPathComponent ?? "Macrife Player"
            self.onCurrentChanged?(url)
        }
        container.onPlaybackStateChanged = { [weak self] _ in
            self?.onPlaylistChanged?()
        }

        // 播放列表 → 控制器
        container.onPlaylistSelect = { [weak self] index in self?.playPlaylistIndex(index) }
        container.onPlaylistDelete = { [weak self] index in self?.deletePlaylistIndex(index) }
        container.onPlaylistMove = { [weak self] from, to in
            self?.movePlaylistItem(from: from, to: to)
        }
        container.onPlaylistAppend = { [weak self] urls in
            self?.appendVideosToPlaylist(urls)
        }

        pushPlaylistToContainer()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: - 播放列表（观测方法）

    /// 设定整个播放列表。
    /// - Parameter appendToRecent: 是否写进「最近打开」。打开单个视频时为 true；
    ///   从「最近打开」里点回来时为 false（否则会把顺序搅乱）。
    func setPlaylistURLs(_ urls: [URL], startIndex: Int, appendToRecent: Bool) {
        // 目录会被展开成里面的媒体文件 —— 原版支持「打开文件夹当播放列表」，
        // 依据是 `openPlaylistWithPanel` 与 `openPlaylist`（无省略号）两条文案并存。
        var flat: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                flat.append(contentsOf: Self.mediaFiles(in: url))
            } else {
                flat.append(url)
            }
        }
        guard !flat.isEmpty else { return }

        playlistItems = flat.map { PlaylistItem(url: $0) }
        currentPlaylistIndex = max(0, min(startIndex, playlistItems.count - 1))

        if appendToRecent {
            PlaybackSettings.shared.noteRecent(flat[currentPlaylistIndex])
        }
        pushPlaylistToContainer()

        let target = flat[currentPlaylistIndex]
        container.open(url: target)
        onPlaylistChanged?()
        onCurrentChanged?(target)
    }

    func appendVideosToPlaylist(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var flat: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                flat.append(contentsOf: Self.mediaFiles(in: url))
            } else {
                flat.append(url)
            }
        }
        playlistItems.append(contentsOf: flat.map { PlaylistItem(url: $0) })
        if currentPlaylistIndex < 0, !playlistItems.isEmpty {
            currentPlaylistIndex = 0
        }
        pushPlaylistToContainer()
        onPlaylistChanged?()
    }

    func playPlaylistIndex(_ index: Int) {
        guard index >= 0, index < playlistItems.count else { return }
        currentPlaylistIndex = index
        let url = playlistItems[index].url
        PlaybackSettings.shared.noteRecent(url)
        pushPlaylistToContainer()
        container.open(url: url)
        onCurrentChanged?(url)
    }

    func deletePlaylistIndex(_ index: Int) {
        guard index >= 0, index < playlistItems.count else { return }
        playlistItems.remove(at: index)

        if playlistItems.isEmpty {
            currentPlaylistIndex = -1
        } else if index < currentPlaylistIndex {
            currentPlaylistIndex -= 1
        } else if index == currentPlaylistIndex {
            // 删掉的是当前曲：索引原地不动（原来的下一首顶上来）；
            // 如果删的是最后一首，则回退一格。
            currentPlaylistIndex = min(currentPlaylistIndex, playlistItems.count - 1)
        }
        pushPlaylistToContainer()
        onPlaylistChanged?()
    }

    func movePlaylistItem(from: Int, to: Int) {
        guard from >= 0, from < playlistItems.count,
              to >= 0, to < playlistItems.count, from != to else { return }
        let item = playlistItems.remove(at: from)
        playlistItems.insert(item, at: to)

        // 当前曲的位置跟着走，否则拖一下就「换歌」了
        if currentPlaylistIndex == from {
            currentPlaylistIndex = to
        } else if from < currentPlaylistIndex, to >= currentPlaylistIndex {
            currentPlaylistIndex -= 1
        } else if from > currentPlaylistIndex, to <= currentPlaylistIndex {
            currentPlaylistIndex += 1
        }
        pushPlaylistToContainer()
        onPlaylistChanged?()
    }

    private func pushPlaylistToContainer() {
        container.setPlaylist(playlistItems, currentIndex: currentPlaylistIndex)
    }

    /// 目录里的媒体文件（按名字排序，不递归 —— 递归会把整块硬盘拉进来）。
    private static func mediaFiles(in directory: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return [] }
        return list
            .filter { PlayerContainerView.mediaExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - 打开（观测方法）

    func openVideo(_ url: URL) {
        setPlaylistURLs([url], startIndex: 0, appendToRecent: true)
    }

    func openVideos(_ urls: [URL]) {
        setPlaylistURLs(urls, startIndex: 0, appendToRecent: true)
    }

    func openVideoWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true     // 允许选文件夹 → 当播放列表
        panel.canChooseFiles = true
        panel.title = L10n.t("open_video")
        panel.message = L10n.t("choose_video_file")
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK else { return }
        openVideos(panel.urls)
    }

    func openPlaylistWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L10n.t("open_playlist")
        if panel.runModal() == .OK, let url = panel.url {
            loadPlaylist(from: url)
        }
    }

    func savePlaylistWithPanel() {
        guard !playlistItems.isEmpty else {
            presentPlaybackFailureAlert("播放列表是空的，没有可保存的内容。")
            return
        }
        let panel = NSSavePanel()
        panel.title = L10n.t("save_playlist")
        panel.nameFieldStringValue = playlistFileURL?.lastPathComponent ?? "playlist.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try JSONEncoder().encode(playlistItems)
            try data.write(to: url)
            playlistFileURL = url
            container.showStatusPill("已保存播放列表：\(url.lastPathComponent)", autoHideDelay: 2.4)
        } catch {
            presentPlaybackFailureAlert("保存播放列表失败：\(error.localizedDescription)")
        }
    }

    private func loadPlaylist(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let items = try JSONDecoder().decode([PlaylistItem].self, from: data)
            guard !items.isEmpty else {
                presentPlaybackFailureAlert("这个播放列表是空的。")
                return
            }
            playlistItems = items
            currentPlaylistIndex = 0
            playlistFileURL = url
            pushPlaylistToContainer()
            onPlaylistChanged?()
            container.open(url: items[0].url)
            onCurrentChanged?(items[0].url)
        } catch {
            presentPlaybackFailureAlert("打开播放列表失败：\(error.localizedDescription)")
        }
    }

    func closeCurrentVideo() {
        container.closeCurrent()
        currentPlaylistIndex = -1
        pushPlaylistToContainer()
        onPlaylistChanged?()
        onCurrentChanged?(nil)
    }

    // MARK: - 窗口（观测方法）

    func toggleFullscreen() {
        window.toggleFullScreen(nil)
    }

    /// 观测到 `setWindowChromeVisible(Bool)`：进入全屏时把标题栏那三个按钮藏掉。
    /// 注意不是改 `styleMask` —— 那在窗口已显示后改会出各种怪事，
    /// 藏按钮 + 透明标题栏在视觉上等价，且安全。
    func setWindowChromeVisible(_ visible: Bool) {
        chromeVisible = visible
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = !visible
        }
        window.titlebarAppearsTransparent = !visible
        window.titleVisibility = visible ? .visible : .hidden
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗即结束播放，避免后台线程继续跑（Phase 1 的管线有 demux/decode 三条线程）。
        container.closeCurrent()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        setWindowChromeVisible(false)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        setWindowChromeVisible(true)
    }

    // MARK: - 后续阶段（观测到的签名先摆在这里，行为如实说明）

    /// 打开 RIFE 进阶详细配置面板
    func openRIFEConfigPanel() {
        container.openRIFEConfig()
    }

    func openSubtitleFile(_ url: URL) {
        showStageNotice("字幕",
                        detail: "外挂字幕加载与 libass 渲染属 Phase 3。")
    }

    func openAnime4KPanel() {
        Anime4KPanelController.shared.togglePanel()
    }

    func openCaptureDeviceWithPanel() {
        CaptureDevicePanelController.shared.show(parentWindow: self.window) { [weak self] videoDev, audioDev, fmt, fps, dur in
            self?.container.openCapture(videoDevice: videoDev, audioDevice: audioDev,
                                        format: fmt, fps: fps, frameDuration: dur)
        }
    }

    func openNetworkStreamWithPanel() {
        showStageNotice(L10n.t("network_panel_title"),
                        detail: "网络流属 Phase 5。")
    }

    func openWindowCaptureWithPanel() {
        showStageNotice(L10n.t("window_capture_panel_title"),
                        detail: "窗口采集属 Phase 5。")
    }

    /// 观测到 `openNetworkStream(url:options:)`。参数类型 `NetworkStreamOptions`
    /// 是骨架里已有的类型，签名照留，行为等 Phase 5。
    func openNetworkStream(url: URL, options: NetworkStreamOptions) {
        showStageNotice(L10n.t("network_panel_title"),
                        detail: "网络流属 Phase 5。")
    }

    /// 观测到 `openWindowCapture(_:)`。同上。
    func openWindowCapture(_ source: ScreenCaptureSource) {
        showStageNotice(L10n.t("window_capture_panel_title"),
                        detail: "窗口采集属 Phase 5。")
    }

    func presentPlaybackFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "播放失败"
        alert.informativeText = message
        alert.addButton(withTitle: L10n.t("ok"))
        if window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func showStageNotice(_ title: String, detail: String) {
        container.showStatusPill("\(title)：\(detail)", autoHideDelay: 3.0)
    }

    // MARK: - 供 AppDelegate 用

    var isFullscreen: Bool {
        window.styleMask.contains(.fullScreen)
    }

    var chromeIsVisible: Bool { chromeVisible }
}
