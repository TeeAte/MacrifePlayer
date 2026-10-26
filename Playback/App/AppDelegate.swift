//  AppDelegate.swift
//  MetalPlayer 重建工程 —— 应用委托（Phase 2，手写实现）
//
//  ── 为什么这个文件是手写的，而不再是 generate.py 生成的骨架 ──
//
//  二进制里的观测（符号表）：
//
//      MetalPlayer.delegate : MetalPlayer.AppDelegate
//      MetalPlayer.app      : __C.NSApplication
//      MetalPlayer.AppDelegate.applicationDidFinishLaunching(_:) 的全部调用点只有两个：
//          createMenu()
//          createMainWindow()
//
//  而 AppDelegate 上还有 17 个 fileprivate 方法，**全部是菜单动作**：
//
//      showAboutPanel                 togglePlaylistMenuAction
//      openRecentVideoMenuAction      refreshRecentMenu
//      refreshAudioTrackMenu          switchAudioTrackMenuAction
//      refreshSubtitleTrackMenu       switchSubtitleTrackMenuAction
//      disableSubtitlesMenuAction     refreshModelMenu
//      switchRIFEModelMenuAction      selectRIFEResolutionMenuAction
//      selectRIFEHeavyResolutionMenuAction
//      selectDRBAVersionMenuAction    selectDRBAResolutionMenuAction
//      refreshRIFEWorkerMenu          switchRIFEWorkerMenuAction
//      openCaptureDeviceMenuAction    windowWillClose
//
//  也就是说原版的**菜单栏逻辑就在 AppDelegate 里**，不在 PlayerWindowController。
//  所以 Phase 2 把 AppDelegate 从「骨架」升级为「实现」，并按上面这串名字
//  逐个补齐 —— 名字是观测的，行为是按文案表与既有实现推出来的。
//
//  于是 generate.py 不再生成它（见 `_reverse/generate.py` 的 HANDWRITTEN 表），
//  本文件归 `Playback/` 那棵「永不被重建覆盖」的源码树管。

import Foundation
import AppKit
import CoreMedia

// MARK: - 开发期开关：环境变量 **与** 命令行两套入口

/// 开发期开关的读取。
///
/// 为什么要多一份命令行入口（而不是只用现成的环境变量）：
/// `open -n MetalPlayer.app --args --dump-stats` 是**唯一**能在 GUI 会话里带参数
/// 启动的办法 —— `open` 走 LaunchServices，继承的是 per-user launchd 的环境，
/// **不传递调用者的环境变量**；而 `launchctl setenv` 又要特权。结果就是
/// 「窗口起来了、但 env 里什么都没有、dump 全是空」，验证做不下去。
/// 加一份命令行入口之后，任何启动方式（终端直跑 / `open` / 双击）都能出证据。
///
/// 优先级：环境变量 > 命令行。两者都没有 = 关闭，正常启动时这段是空转。
/// 与其它 dev 开关一样，**不参与任何生产路径**。
enum DevFlag {

    /// 有没有打开这个开关。`--dump-stats` / `--dump-stats=x` 两种写法都算打开。
    static func on(_ env: String, _ cli: String) -> Bool {
        if ProcessInfo.processInfo.environment[env] != nil { return true }
        return CommandLine.arguments.contains { $0 == cli || $0.hasPrefix(cli + "=") }
    }

    /// 取一个**带值**的开关：`MP_DUMP_DELAY=3` 或 `--dump-delay=3`。
    /// 两个都没有时返回 nil（调用方自己给默认值）。
    static func value(_ env: String, _ cli: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        let prefix = cli + "="
        return CommandLine.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowController: PlayerWindowController?

    // 菜单项需要被动态刷新，所以留住引用而不是每次去找
    private var recentMenu: NSMenu?
    private var audioTrackMenu: NSMenu?
    private var subtitleTrackMenu: NSMenu?
    private var modelMenu: NSMenu?
    private var rifeWorkerMenu: NSMenu?

    // MARK: - 「请求态」选择（勾选回显用）
    //
    // 为什么需要：验收里有一条「开关状态正确回显」。菜单项的**勾**必须跟着用户点的那一项走,
    // 否则点完菜单毫无反馈，看起来像坏了。
    //
    // nil = 「不指定」，此时退回引擎报告的实际值。
    //
    // 字幕在 Phase 3、音轨在 Phase 3.5 均已接上真实切轨。
    // 现在直接读 `container.selectedSubtitleStreamIndex` / `container.selectedAudioStreamIndex`（唯一真相源）。

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 开发期：按环境变量预置档位。必须在 createMenu/createMainWindow **之前** ——
        // 菜单与控制条都在构造时读一次设置，先改后建才不会漏。
        applyDebugSettingsFromEnvironment()

        // 观测：这两个是 applicationDidFinishLaunching 的**全部**调用点。
        // 顺序也照观测的写法：先菜单后窗口 —— 这样窗口一出现菜单就已经就位。
        createMenu()
        createMainWindow()

        // Phase 4: 后台预热与解密 models.dat (CoreML 模型权重)
        ModelPackageManager.prewarmAsync()

        // 开发期自检：本地化文案链路是否完好（缺 key 会静默显示成 key 本身）
        L10n.reportMissingKeys()

        // 开发期：把整棵菜单树 / 控制条状态打出来，便于自动化验收。
        //
        // 延时可通过 `MP_DUMP_DELAY=<秒>` 调整（默认 0.6）。需要它是因为
        // **打开文件是异步的**：默认 0.6 秒时文件往往还没打开完，音轨/字幕菜单是空的、
        // 控制条还是置灰的。想看「打开之后」的样子，就传个 3 之类的值。
        let dumpDelay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6
        if DevFlag.on("MP_DUMP_MENU", "--dump-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + dumpDelay) { [weak self] in
                self?.dumpMenuTree()
            }
        }
        if DevFlag.on("MP_DUMP_UI", "--dump-ui") {
            DispatchQueue.main.asyncAfter(deadline: .now() + dumpDelay) { [weak self] in
                self?.dumpOverlayState()
            }
        }
        // 性能监看面板（Tab 那个）。想看到非零的 FPS 得给足采样时间：
        // FPS 是「计数差 / 时间差」，第一拍永远是 0 —— 想要数就传 MP_DUMP_DELAY=3。
        if DevFlag.on("MP_DUMP_STATS", "--dump-stats") {
            // 先把面板**点亮**再等 dump 延时：面板不可见时刷新定时器是停的
            // （这是刻意的，见 `StatsPanelView.startTimer`），到点才点亮的话
            // 采样器没有历史、FPS 必为 0，等于白 dump 一场。
            container?.setStatsVisible(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + dumpDelay) { [weak self] in
                self?.dumpStatsState()
            }
        }

        // `--dump-exit`：dump 完就退出。
        // 为什么需要：通过 `open` 起的进程不归当前 shell 管，dump 完不退出就会
        // 一直在窗口里放着，下一次跑又多一个实例（还会抢窗口焦点）。
        if DevFlag.on("MP_DUMP_EXIT", "--dump-exit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + dumpDelay + 0.8) {
                NSApp.terminate(nil)
            }
        }

        installAutoOpenIfRequested()
        installReloadTestIfRequested()
        installSubtitleProbeIfRequested()
        installSubtitlePNGExportIfRequested()
        installStatsPanelPNGExportIfRequested()
        installWindowPNGExportIfRequested()
        installOverlayPNGExportIfRequested()
        installRIFEConfigPNGExportIfRequested()
        installAnime4KConfigPNGExportIfRequested()
        installCaptureConfigPNGExportIfRequested()
        installCaptureGoIfRequested()
        installCaptureDumpIfRequested()
        installFrameDumpIfRequested()
    }

    // MARK: - dev：控件 frame 快照（MP_DUMP_FRAMES）

    /// `--dump-frames`：把性能面板与控制条的**每个控件的真实 frame** 打出来。
    ///
    /// 为什么单独立一个开关，而不是并进 `--dump-stats`：那两个 dump 证明的是
    /// 「**内容**对不对」（读数、档位回显），这个证明的是「**排得开排不开**」。
    /// 两类问题、两种证据，混在一起会让调用方得多带一个无关参数。
    ///
    /// 「控件重叠」是这类问题的典型：从截图上只能看出「挤在一起」，
    /// 看不出是哪两条约束打架；frame 摊成数字后，只要比较
    /// 「甲的右边缘 > 乙的左边缘」就能直接定位。
    private func installFrameDumpIfRequested() {
        guard DevFlag.on("MP_DUMP_FRAMES", "--dump-frames") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let container = self.container else {
                self.emit("\n[FRAMES] 没有窗口控制器\n"); return
            }
            self.emit("\n---- 控件 frame（MP_DUMP_FRAMES）----\n"
                      + container.statsPanelFramesText() + "\n\n"
                      + container.overlayFramesText() + "\n\n"
                      + container.overlayAppearanceText() + "\n")
        }
    }

    // MARK: - dev：整窗截图（MP_WINDOW_PNG）

    /// `--window-png=<路径>`：把**整个窗口的内容视图**截下来。
    ///
    /// 与 `--stats-png` 的分工要说清楚，否则两张图会互相打脸：
    ///   · `--stats-png` 导的**只有面板本身** —— 上下左右都贴着面板边界，
    ///     背景透明，用来证「没有底板」；
    ///   · 这一个导的是**整窗** —— 面板在窗口里的真实位置、跟控制条的距离、
    ///     跟画面边缘的余量，都只有在这张图里才是真的。
    ///
    /// 抓不到的是视频画面：那块是 `CAMetalLayer`，`CALayer.render` 画不进去，
    /// 会是空的。这不是缺陷 —— 面板与控制条是 AppKit 画的，够用了。
    ///（为什么不用 `cacheDisplay`：实测它对本工程这套 layer-backed UI 返回纯黑，
    /// 见 `ViewSnapshot` 文件头。）
    private func installWindowPNGExportIfRequested() {
        guard let path = DevFlag.value("MP_WINDOW_PNG", "--window-png") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let content = self.windowController?.window.contentView else {
                self.emit("\n[窗口PNG] 没有窗口\n"); return
            }
            guard let image = ViewSnapshot.layerImage(of: content) else {
                self.emit("\n[窗口PNG] 取不到位图（窗口尺寸为零）→ 未导出\n")
                return
            }
            let ok = ViewSnapshot.writePNG(image, to: URL(fileURLWithPath: path))
            self.emit("\n[窗口PNG] \(ok ? "已导出" : "导出失败") \(path) · \(image.width)x\(image.height)\n")
        }
    }

    // MARK: - dev：底部控制条导出 PNG（MP_OVERLAY_PNG）

    /// `--overlay-png=<路径>`：把底部控制条导成一张 PNG。
    ///
    /// 单独给它开一个口子，是因为控制条**不透明地压在画面上** ——
    /// 混在整窗图里看不清它自己的配色与排布。用户报的两个问题
    ///（「白画面下文字看不见」「播放按钮与底部 UI 重叠」）都在这一条上，
    /// 需要一张只有它的、可以逐像素看的图。
    ///
    /// 背景是透明的（`ControlOverlayView` 自己只有材质层），所以导出的图
    /// 既能压在暗画面上看，也能压在亮画面上看 —— 正好用来验对比度。
    private func installOverlayPNGExportIfRequested() {
        guard let path = DevFlag.value("MP_OVERLAY_PNG", "--overlay-png") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let container = self.container else {
                self.emit("\n[控制条PNG] 没有窗口控制器\n"); return
            }
            guard let image = container.overlaySnapshotForExport() else {
                self.emit("\n[控制条PNG] 取不到位图（尺寸为零 / 没有图层）→ 未导出\n")
                return
            }
            let ok = ViewSnapshot.writePNG(image, to: URL(fileURLWithPath: path))
            self.emit("\n[控制条PNG] \(ok ? "已导出" : "导出失败") \(path) · \(image.width)x\(image.height)\n")
            self.emit(container.overlayAppearanceText() + "\n")
        }
    }

    // MARK: - dev：RIFE 详细配置面板导出 PNG（MP_RIFE_CONFIG_PNG）

    private func installRIFEConfigPNGExportIfRequested() {
        guard let path = DevFlag.value("MP_RIFE_CONFIG_PNG", "--rife-config-png") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.windowController?.openRIFEConfigPanel()
            guard let panel = RIFEConfigPanelController.shared.window,
                  let cv = panel.contentView else {
                self.emit("\n[RIFE配置PNG] 取不到面板视图\n")
                return
            }
            panel.layoutIfNeeded()
            cv.layoutSubtreeIfNeeded()
            let image = ViewSnapshot.image(of: cv) ?? ViewSnapshot.layerImage(of: cv)
            guard let image else {
                self.emit("\n[RIFE配置PNG] 渲染失败 (bounds: \(cv.bounds))\n")
                return
            }
            let ok = ViewSnapshot.writePNG(image, to: URL(fileURLWithPath: path))
            self.emit(String(format: "\n[RIFE配置PNG] %@ → %@ · %dx%d\n",
                             ok ? "已导出" : "导出失败", path, image.width, image.height))
        }
    }

    // MARK: - dev：Anime4K 配置面板导出 PNG（MP_ANIME4K_CONFIG_PNG）

    private func installAnime4KConfigPNGExportIfRequested() {
        guard let path = DevFlag.value("MP_ANIME4K_CONFIG_PNG", "--anime4k-config-png") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.windowController?.openAnime4KPanel()
            guard let panel = Anime4KPanelController.shared.window,
                  let cv = panel.contentView else {
                self.emit("\n[Anime4K配置PNG] 取不到面板视图\n")
                return
            }
            panel.layoutIfNeeded()
            cv.layoutSubtreeIfNeeded()
            let image = ViewSnapshot.image(of: cv) ?? ViewSnapshot.layerImage(of: cv)
            guard let image else {
                self.emit("\n[Anime4K配置PNG] 渲染失败 (bounds: \(cv.bounds))\n")
                return
            }
            let ok = ViewSnapshot.writePNG(image, to: URL(fileURLWithPath: path))
            self.emit(String(format: "\n[Anime4K配置PNG] %@ → %@ · %dx%d\n",
                             ok ? "已导出" : "导出失败", path, image.width, image.height))
        }
    }

    // MARK: - dev：采集卡配置面板导出 PNG（MP_CAPTURE_CONFIG_PNG / --capture-config-png）

    private func installCaptureConfigPNGExportIfRequested() {
        guard let path = DevFlag.value("MP_CAPTURE_CONFIG_PNG", "--capture-config-png") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            CaptureDevicePanelController.shared.show()
            guard let panel = CaptureDevicePanelController.shared.window,
                  let cv = panel.contentView else {
                self.emit("\n[采集卡配置PNG] 取不到面板视图\n")
                return
            }
            panel.layoutIfNeeded()
            cv.layoutSubtreeIfNeeded()
            let image = ViewSnapshot.image(of: cv) ?? ViewSnapshot.layerImage(of: cv)
            guard let image else {
                self.emit("\n[采集卡配置PNG] 渲染失败 (bounds: \(cv.bounds))\n")
                return
            }
            let ok = ViewSnapshot.writePNG(image, to: URL(fileURLWithPath: path))
            self.emit(String(format: "\n[采集卡配置PNG] %@ → %@ · %dx%d\n",
                             ok ? "已导出" : "导出失败", path, image.width, image.height))
        }
    }

    // MARK: - dev：采集卡真实能力转储（MP_CAPTURE_DUMP / --capture-dump）

    /// 把采集卡面板**实际枚举到**的设备能力打成文本。
    /// 与 `MP_CAPTURE_CONFIG_PNG` 的分工：PNG 证明「画出来什么样」，
    /// 这个证明「列表里每一项是不是设备真的支持」——采集卡换型号时，
    /// 光看截图无法判断某项是不是硬编码的假选项。
    private func installCaptureDumpIfRequested() {
        guard DevFlag.on("MP_CAPTURE_DUMP", "--capture-dump") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            CaptureDevicePanelController.shared.show()
            self.emit(CaptureDevicePanelController.shared.debugDumpText())

            // 只探测「交出去的参数」，不真的开采集 —— 开摄像头属于有副作用的操作，
            // 默认不做；要看实际采集帧率就让调用方自行点「开始采集」。
            guard DevFlag.on("MP_CAPTURE_START", "--capture-start") else { return }
            CaptureDevicePanelController.shared.show { v, a, f, fps, dur in
                let desc = f?.formatDescription ?? v.activeFormat.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let sub = CMFormatDescriptionGetMediaSubType(desc)
                self.emit(String(format: "\n[采集启动契约] 设备=%@\n  规格=%dx%d  像素格式=%@\n  上报帧率=%.2f FPS\n  锁定时长=%@\n  音频=%@\n",
                                 v.localizedName, Int(dims.width), Int(dims.height),
                                 CaptureFormatFourCC.text(sub), fps,
                                 dur.map { "\($0.value)/\($0.timescale)" } ?? "不锁定",
                                 a?.localizedName ?? "静音"))
            }
            CaptureDevicePanelController.shared.devStart()
        }
    }

    /// dev-only（`MP_CAPTURE_GO`）：**真的**启动一次采集，用来验证帧率是否真的
    /// 落到了设备与输出连接上。
    ///
    /// 与 `MP_CAPTURE_DUMP` 的分工：dump 只证明「交出去什么参数」，
    /// 这个证明「参数是否真的生效」—— 本轮踩到的坑正是
    /// 「参数交出去了、设备读回也对、启动后被驱动重置」，光看 dump 判断不出来。
    /// 跑完会打印设备/连接的读回值与实测投递帧率。
    private func installCaptureGoIfRequested() {
        guard DevFlag.on("MP_CAPTURE_GO", "--capture-go") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let wc = self.windowController else { return }
            self.container?.setStatsVisible(true)
            wc.openCaptureDeviceWithPanel()          // 真实回调（走引擎 openCapture）
            CaptureDevicePanelController.shared.devStart()
            // 采集跑一会儿后把实测值打出来
            let hold = Double(DevFlag.value("MP_CAPTURE_HOLD", "--capture-hold") ?? "") ?? 6.0
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
                self.emit(self.container?.captureDiagnosticsText() ?? "\n(无容器)\n")
            }
        }
    }

    // MARK: - dev：性能面板导出 PNG（MP_STATS_PNG）

    /// `--stats-png=<路径>`：把性能面板**视图**导成一张 PNG。
    ///
    /// 面板是纯视觉的东西（Phase 2 之后没再动过内容，本轮把底板换成了文字描边），
    /// 而「描边够不够清、背后还有没有那块矩形」在文本 dump 里是**看不出来**的 ——
    /// 两种实现的 dump 字符串逐字节相同。所以这里给它一个出图的口子，
    /// 与 `--subtitle-png` 同一个思路：文本用来断言，图片用来判好看。
    ///
    /// 面板默认不可见，快照前会自己 `show()` 一次（见 `StatsPanelView.snapshotForExport`）。
    private func installStatsPanelPNGExportIfRequested() {
        guard let path = DevFlag.value("MP_STATS_PNG", "--stats-png") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let container = self.container else {
                self.emit("\n[面板PNG] 没有窗口控制器\n"); return
            }
            guard let image = container.statsPanelSnapshotForExport() else {
                self.emit("\n[面板PNG] 取不到位图（面板尺寸为零 / 图层未建）→ 未导出\n")
                return
            }
            let ok = ViewSnapshot.writePNG(image, to: URL(fileURLWithPath: path))
            self.emit("\n[面板PNG] \(ok ? "已导出" : "导出失败") \(path) · \(image.width)x\(image.height)\n")
        }
    }

    // MARK: - dev：字幕层导出 PNG（MP_SUBTITLE_PNG）

    /// `--subtitle-png=<路径>`：把 dump 时刻的字幕层导成一张 PNG。
    ///
    /// 与 `--dump-stats` 的「主动」那一行是**同一份数据**，只是一个出文本一个出图片。
    /// 文本那行能断言（叠图数 / 峰值 RGB），图片那行能看出好不好看 ——
    /// 字体选对没有、描边粗细、`\N` 换行有没有真换、简繁字形到底一不一样。
    ///
    /// 与 `MP_DUMP_FRAME`（FrameDumper）的分工写在 `SubtitlePNGExport` 文件头：
    /// 那个导视频帧、这个导字幕层，两者合起来才是屏幕上那一格。
    private func installSubtitlePNGExportIfRequested() {
        guard let path = DevFlag.value("MP_SUBTITLE_PNG", "--subtitle-png") else { return }
        let delay = Double(DevFlag.value("MP_DUMP_DELAY", "--dump-delay") ?? "") ?? 0.6

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard let container = self.container else {
                self.emit("\n[字幕PNG] 没有窗口控制器\n"); return
            }
            guard let snap = container.subtitleSnapshotForExport() else {
                self.emit("\n[字幕PNG] 取不到位图（字幕已关闭 / 无字幕轨）→ 未导出\n")
                return
            }
            let ok = SubtitlePNGExport.write(snap.bitmap,
                                             to: URL(fileURLWithPath: path))
            self.emit(String(format: "\n[字幕PNG] %@ → %@ · %dx%d · 叠图 %d 张\n",
                             ok ? "已导出" : "导出失败", path,
                             snap.width, snap.height, snap.bitmap.imageCount))
        }
    }

    // MARK: - dev：libass 可用性探针（MP_SUBTITLE_PROBE）

    /// `--subtitle-probe`：不打开任何媒体文件，直接建一个 libass 渲染器，
    /// 渲染一句**已知为纯红**的字幕，把结果打出来。
    ///
    /// 为什么值得单独有一个探针：libass 是本工程里唯一一个「不是 FFmpeg、
    /// 但同样躺在 Frameworks/ 里」的依赖。它的 dylib 能否被 @rpath 解析、
    /// CoreText 字体 provider 在 app 进程里能不能建起来 ——
    /// **编译通过证明不了这两件事**，只有真跑一次才知道。
    ///
    /// 颜色那一项是刻意加的：它同时验了「颜色字节序对不对」——
    /// 纯红字幕若解出 R≠255，说明 R/B 通道搞反了（ASS_Image.color 是
    /// 反直觉的编码，实测才敢下结论，见 AssSubtitleRenderer.composite 的注释）。
    private func installSubtitleProbeIfRequested() {
        guard DevFlag.on("MP_SUBTITLE_PROBE", "--subtitle-probe") else { return }

        let script = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 640
        PlayResY: 360

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,64,&H000000FF,&H00000000,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,2,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.00,0:00:10.00,Default,,0,0,0,,PROBE
        """

        let renderer = AssSubtitleRenderer(script: script)
        var lines = ["\n===== 字幕探针（MP_SUBTITLE_PROBE）====="]
        lines.append("libass 可用: \(renderer.isAvailable)")

        if let bmp = renderer.render(at: 1.0, width: 640, height: 360) {
            var nonZero = 0
            var maxR = 0, maxG = 0, maxB = 0, maxA = 0
            var i = 0
            while i + 3 < bmp.pixels.count {
                // BGRA 顺序
                let b = Int(bmp.pixels[i]), g = Int(bmp.pixels[i + 1])
                let r = Int(bmp.pixels[i + 2]), a = Int(bmp.pixels[i + 3])
                if a != 0 {
                    nonZero += 1
                    maxR = max(maxR, r); maxG = max(maxG, g)
                    maxB = max(maxB, b); maxA = max(maxA, a)
                }
                i += 4
            }
            lines.append("位图 \(bmp.width)x\(bmp.height) · 叠图 \(bmp.imageCount) 张")
            lines.append("非零像素 \(nonZero) · 峰值通道 R=\(maxR) G=\(maxG) B=\(maxB) A=\(maxA)")
            lines.append("（纯红字幕应为 R=255 且 G=B=0；R/B 反了说明 color 字节序取错）")
        } else {
            lines.append("⚠️ render 返回 nil —— 没有渲染出任何东西")
        }
        lines.append(renderer.debugSummary())
        lines.append("===== 结束 =====")
        emit(lines.joined(separator: "\n") + "\n")
    }

    // MARK: - dev：热切换的触发开关（MP_RELOAD_TEST）

    /// `--reload-test=SEC` / `MP_RELOAD_TEST=SEC`：启动 SEC 秒后翻一次
    /// **影响管线**的设置（补帧档位 off ↔ x2）。
    ///
    /// 为什么需要它：「设置改了就就地重建管线、不重启 APP」这件事没法用
    /// 「跑一遍看日志」之外的办法验证 —— 它要的是**真的改一次设置**，
    /// 而改设置的入口要么是菜单（自动化点不了），要么是控制条按钮（同上）。
    /// 这个开关走的是**和菜单完全相同的通路**（写 `PlaybackSettings` →
    /// 发 `.playbackSettingsDidChange` → 容器判定 `affectsPipeline` → 重建），
    /// 不另开一条快捷键，所以验的就是真东西。
    ///
    /// 观察点（配合 `--trace --dump-stats`）：
    ///   · stderr 出现 `[PlaybackEngine] 热切换：已就地重建管线 — … 续播 X.XXs`
    ///   · 时间轴连续（续播位置 ≈ 触发时刻），没有归零
    ///   · 性能面板的「已解码/已上屏」重新起算（采样历史被清过）
    private func installReloadTestIfRequested() {
        guard let raw = DevFlag.value("MP_RELOAD_TEST", "--reload-test") else { return }
        let delay = Double(raw).flatMap { $0 > 0 ? $0 : nil } ?? 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let s = PlaybackSettings.shared
            let next: RIFERateMode = (s.rifeRateMode == .off) ? .x2 : .off
            FileHandle.standardError.write(
                Data(("[AppDelegate] dev: MP_RELOAD_TEST 改写补帧档位 "
                       + "\(s.rifeRateMode.rawValue) → \(next.rawValue)\n").utf8))
            s.rifeRateMode = next        // ← 这一行就是「用户点菜单」
        }
    }

    /// `MP_OPEN=<路径>` / `--open <路径>`：启动即打开指定文件（dev-only）。
    ///
    /// 存在理由：内存/性能类问题必须**本地可复现**才能定位 —— 靠人肉拖文件
    /// 试只能拿到「还会不会涨」，拿不到增长曲线与对象级证据。有了这个开关
    /// 就能脚本化起进程、用 `footprint <pid>` 采样内存、用 `leaks` 抓对象。
    private func installAutoOpenIfRequested() {
        guard let raw = DevFlag.value("MP_OPEN", "--open") else { return }
        let url = URL(fileURLWithPath: raw)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.container?.open(url: url)
            FileHandle.standardError.write(
                Data("[AppDelegate] dev: MP_OPEN 已打开 \(url.lastPathComponent)\n".utf8))
        }
    }

    /// dump 的输出去处。
    ///
    /// 默认 stderr（终端直跑时最直观）。给了 `--dump-file=PATH` / `MP_DUMP_FILE=PATH`
    /// 就追加写文件 —— 通过 `open` 启动时 stderr 是接在 launchd 上的（终端里什么都看不到、
    /// 统一日志里也未必有），写文件才是能拿回来读的那条路。
    private func emit(_ text: String) {
        guard let path = DevFlag.value("MP_DUMP_FILE", "--dump-file") else {
            FileHandle.standardError.write(Data(text.utf8))
            return
        }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            // 文件还不存在 → 直接建。`open` 启动时没法先 touch，所以这里必须能建。
            try? Data(text.utf8).write(to: url)
        }
    }

    // MARK: - 开发期：环境变量预置档位

    /// 按环境变量改档位，不改任何生产路径。
    ///
    ///      MP_SET_RIFE=off|x2|x3|x4|x5|fps60
    ///      MP_SET_METALFX=off|spatial
    ///      MP_SET_ANIME4K=off|on
    ///      MP_SET_DECODE=hardware|software
    ///      MP_SET_RIFE_MODEL=lite425|full425|v426|heavy426
    ///      MP_SET_RIFE_RES=sweet|normal|quality|top
    ///      MP_SET_WORKERS=6|8|10|12
    ///
    /// 这是「开关状态正确回显」那条验收的**证据生产器**：设成非默认值再 dump，
    /// 控制条/菜单的输出里就必须出现对应的档位文字与勾选。
    /// 全部走环境变量、且默认不存在 —— 正常启动时这段是空转，不污染任何行为。
    private func applyDebugSettingsFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        let s = PlaybackSettings.shared
        if let raw = env["MP_SET_RIFE"], let v = RIFERateMode(rawValue: raw) { s.rifeRateMode = v }
        if let raw = env["MP_SET_METALFX"], let v = MetalFXOption(rawValue: raw) { s.metalFX = v }
        if let raw = env["MP_SET_ANIME4K"], let v = Anime4KOption(rawValue: raw) { s.anime4k = v }
        if let raw = env["MP_SET_DECODE"], let v = DecodeMode(rawValue: raw) { s.decodeMode = v }
        if let raw = DevFlag.value("MP_DECODE", "--decode") {
            if raw == "hardware" || raw == "hw" { s.decodeMode = .hardware }
            else if raw == "software" || raw == "sw" { s.decodeMode = .software }
        }
        if let raw = DevFlag.value("MP_SET_RIFE_MODEL", "--rife-model"), let v = RIFEModelChoice(rawValue: raw) {
            s.rifeModel = v
        }
        if let raw = env["MP_SET_RIFE_RES"], let v = RIFEModelResolution(rawValue: raw) {
            s.rifeResolution = v
        }
        if let raw = env["MP_SET_WORKERS"], let v = Int(raw),
           PlaybackSettings.rifeWorkerChoices.contains(v) {
            s.rifeWorkerCount = v
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        container?.closeCurrent()
    }

    // MARK: - dev：字幕切轨 / 外挂加载 / 定位的无 GUI 入口

    /// `--subtitle-track=N` / `--external-subtitle=/path/to.ass` / `--hold-at=<秒>`
    ///
    /// 为什么需要：**切轨、选外挂文件、拖进度条都是纯 GUI 操作**，
    /// 而验收要的是可程序化复现的证据。把这三个动作变成启动参数，
    /// `--dump-stats` 拿到的就是「切轨 + 定位之后」的真实状态，不必人眼看截图。
    ///
    /// - Note: 三个动作都在**文件打开之后**投递（挂在 `onCurrentChanged` 上）。
    ///   引擎的 `applySubtitleRequest` 在没有 source 时会直接返回 ——
    ///   那是给「还没开文件用户就点了菜单」准备的防御，不能靠它兜住启动时序。
    private func applyAudioTrackSelectionFromEnvironment() {
        guard let container else { return }
        guard let trackRaw = DevFlag.value("MP_AUDIO_TRACK", "--audio-track"),
              let trackIndex = Int(trackRaw) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            container.selectAudioTrack(trackIndex)
            self?.refreshAudioMenuSoon()
        }
    }

    private func applySubtitleSelectionFromEnvironment() {
        guard let container else { return }

        let trackRaw = DevFlag.value("MP_SUBTITLE_TRACK", "--subtitle-track")
        let externalRaw = DevFlag.value("MP_EXTERNAL_SUBTITLE", "--external-subtitle")
        let holdRaw = DevFlag.value("MP_HOLD_AT", "--hold-at")
        guard trackRaw != nil || externalRaw != nil || holdRaw != nil else { return }
        let holdTarget = holdRaw.flatMap { Double($0) }

        // 顺序是**停住 → 切轨 → 定位**，每一步都有理由：
        //
        //   · **先停住**（只有给了 `--hold-at` 才停）：反过来的话，从「定位完成」
        //     到「停住」之间播放还会往前走一段（实测约 0.4s），dump 时刻就变成了
        //     「目标点 + 随机量」，而「此刻该显示哪一句字幕」是跟时间绑死的 ——
        //     差 0.4s 就可能跨到下一句或落进时间轴空档，断言直接失效。
        //     先停住时 `AVSyncClock.reset(to:)` 只改 `lastTime` 不动 `running`，
        //     于是时钟精确停在目标点（实测 1.500 / 5.000 / 9.000 分毫不差）。
        //   · **中途切轨**：切轨内部会重建 renderer/track，重建后 track 里没有事件，
        //     必须靠紧接着的定位触发的重新读包把事件灌进去。
        //   · **最后定位**：一步就把「新轨的事件」与「播放位置」同时摆好。
        if holdTarget != nil, container.isPlaying { container.togglePlayPause() }

        if let trackRaw, let index = Int(trackRaw) {
            container.selectSubtitleTrack(index)
        }
        if let externalRaw, !externalRaw.isEmpty {
            container.loadExternalSubtitle(url: URL(fileURLWithPath: externalRaw))
        }
        if let target = holdTarget {
            container.seek(to: target)
        }

        // 留一拍让解封装线程把上面几个请求消费掉（它按 20ms 左右的节拍轮询），
        // 再刷菜单 —— 否则菜单读到的还是切换前的旧状态。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshSubtitleTrackMenu()
        }
    }

    // MARK: - createMainWindow（观测方法）

    private func createMainWindow() {
        let wc = PlayerWindowController()
        windowController = wc

        wc.onCurrentChanged = { [weak self] _ in
            // 换了文件 → 音轨/字幕菜单要重建（它们的内容随文件变），
            // 播放列表菜单的可用性也会变。
            self?.refreshAudioTrackMenu()
            self?.refreshSubtitleTrackMenu()
            self?.refreshRecentMenu()
            // dev：把「点菜单切轨 / 选外挂文件」变成「带参数启动」，见方法注释。
            self?.applySubtitleSelectionFromEnvironment()
            self?.applyAudioTrackSelectionFromEnvironment()
        }
        wc.onPlaylistChanged = { [weak self] in
            self?.refreshRecentMenu()
        }

        wc.showWindow()
        wc.container.openLaunchFileIfNeeded()
    }

    private var container: PlayerContainerView? { windowController?.container }

    // MARK: - createMenu（观测方法）

    private func createMenu() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeAppMenu())
        mainMenu.addItem(makeFileMenu())
        mainMenu.addItem(makeAudioTrackMenu())
        mainMenu.addItem(makeSubtitleMenu())
        mainMenu.addItem(makeModelMenu())

        let workers = makeRIFEWorkerMenu()
        rifeWorkerMenu = workers.submenu
        mainMenu.addItem(workers)

        // 到这里为止，菜单栏就是完整的六个：应用 / 文件 / 音轨 / 字幕 / 模型 / RIFE核心。
        //
        // ── 为什么**没有**「窗口」菜单（第一版做错了，这里记一笔）──
        //
        // 第一版照着「macOS 应用都该有个窗口菜单」的直觉，自己造了一个（最小化/缩放/进入全屏），
        // 并用 `NSApp.windowsMenu = menu` 挂上。三处证据说明原版**没有**这个菜单：
        //
        //   1. 原版二进制的符号/字符串池里**没有 `windowsMenu`**，也没有 `arrangeInFront:`
        //      （前者是「装了窗口菜单」的标志，后者是标准项「全部置于顶层」）。
        //      也就是说原版根本没调用过 `NSApp.windowsMenu`。
        //   2. 原版 `zh-Hans/en` 的 Localizable.strings 里**没有**「最小化/缩放/进入全屏」
        //      这类 key —— 说明这些项不是它自己造的（自己造就必须有文案）。
        //   3. 本工程的验收基准（REBUILD-PLAN Phase 2）列的就是
        //      「文件 / 音轨 / 字幕 / 模型 / RIFE核心」五项，没有窗口菜单。
        //
        // 而全屏是能进的：控制条上那个 `fullscreenButton`（反射段里有这个控件名）
        // 接 `onFullscreen`，另外双击画面也走同一条路 —— 见 PlayerContainerView。
        // 原版字符串池里那个 `toggleFullScreen:` 就是这条路径里 `window.toggleFullScreen(nil)`
        // 的调用点，不是某个菜单项的 action。
        //
        // 顺带：`NSApp.windowsMenu` 一旦被赋值，AppKit 会往那个菜单里自动补
        // 「窗口列表」。这正是第一版菜单里冒出 `✓ MetalPlayer` 那一行的原因。

        NSApp.mainMenu = mainMenu

        // 动态部分先填一遍（此时还没打开文件，会显示「无…」）
        refreshRecentMenu()
        refreshAudioTrackMenu()
        refreshSubtitleTrackMenu()
        refreshModelMenu()
        refreshRIFEWorkerMenu()

        // 设置变化（控制条改了档位）→ 菜单勾选跟着变
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsDidChange(_:)),
            name: .playbackSettingsDidChange, object: nil)
    }

    // MARK: - 各菜单

    private func makeAppMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        item.submenu = menu

        let about = NSMenuItem(title: L10n.t("about_metalplayer"),
                               action: #selector(showAboutPanel(_:)),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let support = NSMenuItem(title: L10n.t("support_metalplayer"),
                                 action: #selector(showDonatePanel(_:)),
                                 keyEquivalent: "")
        support.target = self
        menu.addItem(support)

        menu.addItem(.separator())

        let hide = NSMenuItem(title: L10n.t("quit_metalplayer").isEmpty ? "隐藏" : "隐藏 Macrife Player",
                              action: #selector(NSApplication.hide(_:)),
                              keyEquivalent: "h")
        menu.addItem(hide)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("quit_metalplayer"),
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)
        return item
    }

    private func makeFileMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.t("file"))
        item.submenu = menu

        func add(_ title: String, _ action: Selector, _ key: String, _ target: AnyObject) {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.target = target
            menu.addItem(i)
        }

        add(L10n.t("open_video_ellipsis"), #selector(openVideoMenuAction(_:)), "o", self)
        add(L10n.t("open_playlist_ellipsis"), #selector(openPlaylistMenuAction(_:)), "", self)
        add(L10n.t("save_playlist_ellipsis"), #selector(savePlaylistMenuAction(_:)), "", self)

        menu.addItem(.separator())
        add(L10n.t("show_playlist"), #selector(togglePlaylistMenuAction(_:)), "l", self)
        // 性能监看。**刻意不设快捷键**：它的快捷键是裸 Tab，而 Tab 在 AppKit 里
        // 归 key view loop 管，写进 keyEquivalent 会和焦点切换打架
        // （菜单里挂一个 Tab 快捷键，等于把系统行为抢了）。
        // 真正处理 Tab 的是容器里那条本地事件监视器，见 PlayerContainerView.installTabMonitor()。
        add(MPText.t("性能监看", "Performance Monitor"),
            #selector(toggleStatsMenuAction(_:)), "", self)
        add(MPText.t("重新载入当前视频 (恢复进度)", "Reload Current Video"),
            #selector(reloadCurrentVideoMenuAction(_:)), "r", self)
        add(L10n.t("close_current_video"), #selector(closeCurrentVideoMenuAction(_:)), "w", self)

        menu.addItem(.separator())

        // ---- 最近打开（动态子菜单，观测方法 refreshRecentMenu / openRecentVideoMenuAction）
        let recent = NSMenuItem(title: L10n.t("recent_open"), action: nil, keyEquivalent: "")
        let recentSub = NSMenu(title: L10n.t("recent_open"))
        recent.submenu = recentSub
        recentMenu = recentSub
        menu.addItem(recent)

        menu.addItem(.separator())
        // 这三条的目标都在 Phase 5，但菜单项本身要在（「与截图一致」）
        add(L10n.t("open_capture_device_ellipsis"),
            #selector(openCaptureDeviceMenuAction(_:)), "", self)
        add(L10n.t("open_network_stream_ellipsis"),
            #selector(openNetworkStreamMenuAction(_:)), "", self)
        add(L10n.t("open_window_capture_ellipsis"),
            #selector(openWindowCaptureMenuAction(_:)), "", self)
        return item
    }

    private func makeAudioTrackMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.t("audio_tracks"))
        item.submenu = menu
        audioTrackMenu = menu
        return item
    }

    /// 只负责把菜单壳建出来 —— 内容交给 `refreshSubtitleTrackMenu()` 填。
    /// 和 `makeModelMenu()` 一样的分工（那边也是靠 `refreshModelMenu()` 填）。
    private func makeSubtitleMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.t("subtitles"))
        item.submenu = menu
        subtitleTrackMenu = menu
        return item
    }

    private func makeModelMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.t("model"))
        item.submenu = menu
        modelMenu = menu
        return item
    }

    private func makeRIFEWorkerMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L10n.t("rife_workers"))
        item.submenu = menu
        rifeWorkerMenu = menu
        return item
    }

    // 注：这里曾经有一个 `makeWindowMenu()`（最小化/缩放/进入全屏）。
    // 已删除 —— 原版没有窗口菜单，证据与理由写在 `createMenu()` 里那段注释。
    // 全屏走控制条的 `fullscreenButton` / 双击画面。

    // MARK: - 动态菜单刷新（观测方法）

    /// refreshRecentMenu（观测方法）。
    @objc private func refreshRecentMenu() {
        guard let menu = recentMenu else { return }
        menu.removeAllItems()

        let recents = PlaybackSettings.shared.recentFiles
        if recents.isEmpty {
            let empty = NSMenuItem(title: L10n.t("no_recent_open"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for url in recents {
            let item = NSMenuItem(title: url.lastPathComponent,
                                  action: #selector(openRecentVideoMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            // 文件被删了就别让点（点了也只是报错）
            item.isEnabled = FileManager.default.fileExists(atPath: url.path)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L10n.t("clear_recent_open"),
                               action: #selector(clearRecentMenuAction(_:)),
                               keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    /// refreshAudioTrackMenu（观测方法）。
    @objc private func refreshAudioTrackMenu() {
        guard let menu = audioTrackMenu else { return }
        menu.removeAllItems()

        let tracks = container?.audioTracks ?? []
        guard !tracks.isEmpty else {
            let empty = NSMenuItem(title: L10n.t("no_audio_tracks"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let selected = container?.selectedAudioStreamIndex ?? -1
        let current = selected >= 0 ? selected : container?.currentAudioStreamIndex
        for (i, track) in tracks.enumerated() {
            let item = NSMenuItem(title: track.menuTitle,
                                  action: #selector(switchAudioTrackMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = track.index
            item.representedObject = track.index
            item.state = (track.index == current) ? .on : .off
            item.toolTip = "第 \(i + 1) 条 · \(track.title.isEmpty ? track.menuTitle : track.title)"
            menu.addItem(item)
        }
    }

    /// refreshSubtitleTrackMenu（观测方法）—— 重建整个「字幕」菜单。
    ///
    /// 结构（扁平，和「音轨」菜单一个形状）：
    ///
    ///     禁用字幕          ← 单选列表的一员：关掉字幕也是一种选择，带勾
    ///     ---               ← 有内封轨时才有
    ///     <简体中文 · ass (1)>
    ///     ---
    ///     外挂字幕…
    ///
    /// 第一版这里是「菜单顶部一个『禁用字幕』+ 一个叫『字幕』的子菜单，子菜单里再放一条
    /// **禁用**的『禁用字幕』占位」。两个毛病：
    ///   1. 父菜单叫「字幕」、子菜单也叫「字幕」，同屏两个同名项；
    ///   2. 「禁用字幕」出现两次，其中一次还点不动 —— 关字幕任何时候都该点得动。
    /// 改成扁平单选列表后两个问题一起没了，且与「音轨」菜单对称。
    @objc private func refreshSubtitleTrackMenu() {
        guard let menu = subtitleTrackMenu else { return }
        menu.removeAllItems()

        // 唯一真相源是引擎的状态：`selectedSubtitleStreamIndex`，
        // 其中 -1 表示「关字幕」（不是一个合法流索引，所以能当哨兵值用）。
        // 这里不再有 pending 覆盖层 —— Phase 3 起菜单显示的就是引擎真正在用的那条轨。
        let selected = container?.selectedSubtitleStreamIndex ?? -1
        let current: Int? = selected >= 0 ? selected : nil

        let off = NSMenuItem(title: L10n.t("disable_subtitles"),
                             action: #selector(disableSubtitlesMenuAction(_:)),
                             keyEquivalent: "")
        off.target = self
        off.state = (current == nil) ? .on : .off
        menu.addItem(off)

        let tracks = container?.subtitleTracks ?? []
        if !tracks.isEmpty {
            menu.addItem(.separator())
            for track in tracks {
                let item = NSMenuItem(title: track.menuTitle,
                                      action: #selector(switchSubtitleTrackMenuAction(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = track.index
                item.state = (track.index == current) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let external = NSMenuItem(title: "\(L10n.t("external_subtitle"))…",
                                  action: #selector(openExternalSubtitleMenuAction(_:)),
                                  keyEquivalent: "")
        external.target = self
        menu.addItem(external)

        // 外挂字幕已经加载时，把「当前用的是外挂」这件事显示出来 ——
        // 否则菜单里所有内封轨都是未勾选状态，用户会以为字幕坏了。
        if let name = container?.externalSubtitleName {
            menu.addItem(.separator())
            let loaded = NSMenuItem(title: "外挂：\(name)", action: nil, keyEquivalent: "")
            loaded.isEnabled = false
            loaded.state = .on
            menu.addItem(loaded)
        }
    }

    /// refreshModelMenu（观测方法）。
    @objc private func refreshModelMenu() {
        guard let menu = modelMenu else { return }
        menu.removeAllItems()
        let s = PlaybackSettings.shared

        // ---- AI 补帧详细配置与模型定制（核心入口）
        let configItem = NSMenuItem(title: "AI 视频补帧 · 详细配置与模型定制...",
                                    action: #selector(openRIFEConfigMenuAction(_:)),
                                    keyEquivalent: "r")
        configItem.keyEquivalentModifierMask = [.command, .shift]
        configItem.target = self
        menu.addItem(configItem)

        // 状态项：显示当前模型内核，点击直接唤出配置面板
        let statusItem = NSMenuItem(title: "当前内核: \(s.rifeModel.title)",
                                    action: #selector(openRIFEConfigMenuAction(_:)),
                                    keyEquivalent: "")
        statusItem.target = self
        menu.addItem(statusItem)

        menu.addItem(.separator())

        // 快捷补帧开关状态
        let isInterpolationActive = (s.rifeRateMode != .off)
        let toggleTitle = isInterpolationActive ? "补帧状态: 运行中 (\(s.rifeRateMode.title))" : "补帧状态: 已关闭"
        let toggleItem = NSMenuItem(title: toggleTitle,
                                    action: #selector(toggleInterpolationMenuAction(_:)),
                                    keyEquivalent: "")
        toggleItem.target = self
        toggleItem.state = isInterpolationActive ? .on : .off
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        // ---- HDR 转 SDR 色调映射 (Tone Mapping)
        let hdrMenu = NSMenu(title: "HDR 转 SDR 色调映射")
        for mode in HDRToneMappingMode.allCases {
            let item = NSMenuItem(title: mode.title,
                                  action: #selector(switchHDRToneMappingMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            item.state = (s.hdrToneMapping == mode) ? .on : .off
            hdrMenu.addItem(item)
        }
        let hdrSubmenuItem = NSMenuItem(title: "HDR 转 SDR 色调映射", action: nil, keyEquivalent: "")
        hdrSubmenuItem.submenu = hdrMenu
        menu.addItem(hdrSubmenuItem)

        menu.addItem(.separator())

        let hintItem = NSMenuItem(title: "💡 模型架构 (RIFE / FLAVR / DRBA) 与专属参数统一在详细配置中调控",
                                  action: #selector(openRIFEConfigMenuAction(_:)),
                                  keyEquivalent: "")
        hintItem.target = self
        menu.addItem(hintItem)
    }

    @objc private func toggleInterpolationMenuAction(_ sender: NSMenuItem) {
        let s = PlaybackSettings.shared
        if s.rifeRateMode == .off {
            s.rifeRateMode = .x2
        } else {
            s.rifeRateMode = .off
        }
    }

    @objc private func switchHDRToneMappingMenuAction(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? HDRToneMappingMode else { return }
        PlaybackSettings.shared.hdrToneMapping = mode
    }

    /// refreshRIFEWorkerMenu（观测方法）。
    @objc private func refreshRIFEWorkerMenu() {
        guard let menu = rifeWorkerMenu else { return }
        menu.removeAllItems()
        let current = PlaybackSettings.shared.rifeWorkerCount

        for n in PlaybackSettings.rifeWorkerChoices {
            let item = NSMenuItem(title: Self.workerTitle(n),
                                  action: #selector(switchRIFEWorkerMenuAction(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = n
            item.representedObject = n
            item.state = (n == current) ? .on : .off
            menu.addItem(item)
        }
    }

    /// 观测到 `rife_worker_6 / 8 / 10 / 12` 四条文案。
    private static func workerTitle(_ n: Int) -> String {
        switch n {
        case 6:  return L10n.t("rife_worker_6")
        case 8:  return L10n.t("rife_worker_8")
        case 10: return L10n.t("rife_worker_10")
        case 12: return L10n.t("rife_worker_12")
        default: return L10n.Placeholders.workerCount(n)
        }
    }

    @objc private func settingsDidChange(_ note: Notification) {
        // 主线程守卫。为什么不是「调用方保证在主线程」就完事：
        // `PlaybackSettings` 是个全局单例，任何线程都能写它，写完就发通知。
        // 而这里要动的是**主菜单**，AppKit 明确禁止后台线程改它 ——
        // 违反就直接抛 NSInternalInconsistencyException 把进程带走。
        //
        // 这个坑真实发生过（见 PlayerContainerView.open(url:) 里那段注释）：
        // 打开文件时在后台线程调了 noteRecent → 通知 → 这里 → 崩。
        // 所以除了把那个调用点挪到主线程，这里再兜一道：
        // 万一以后又冒出个后台写设置的路径，最坏也只是晚一拍刷新，不会崩。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.settingsDidChange(note) }
            return
        }
        refreshModelMenu()
        refreshRIFEWorkerMenu()
    }

    // MARK: - 菜单动作（观测方法）

    @objc private func openVideoMenuAction(_ sender: Any?) {
        windowController?.openVideoWithPanel()
    }

    @objc private func openPlaylistMenuAction(_ sender: Any?) {
        windowController?.openPlaylistWithPanel()
    }

    @objc private func savePlaylistMenuAction(_ sender: Any?) {
        windowController?.savePlaylistWithPanel()
    }

    /// togglePlaylistMenuAction（观测方法）。
    @objc private func togglePlaylistMenuAction(_ sender: Any?) {
        container?.togglePlaylist()
    }

    /// 性能监看开关。**不是**观测方法 —— 这个面板是本工程新增的功能，
    /// 原版的符号表里没有对应成员（详见 `StatsPanelView` 文件头）。
    /// 主入口是裸 Tab，这条菜单项是给「不知道有 Tab 快捷键」的人留的。
    @objc private func toggleStatsMenuAction(_ sender: Any?) {
        container?.toggleStatsPanel()
    }

    /// 打开 RIFE 进阶详细配置面板
    @objc private func openRIFEConfigMenuAction(_ sender: Any?) {
        windowController?.openRIFEConfigPanel()
    }

    @objc private func closeCurrentVideoMenuAction(_ sender: Any?) {
        windowController?.closeCurrentVideo()
    }

    @objc private func reloadCurrentVideoMenuAction(_ sender: Any?) {
        windowController?.reloadCurrentVideo()
    }

    /// openRecentVideoMenuAction（观测方法）。
    @objc private func openRecentVideoMenuAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        windowController?.openVideo(url)
    }

    @objc private func clearRecentMenuAction(_ sender: Any?) {
        PlaybackSettings.shared.clearRecent()
    }

    /// switchAudioTrackMenuAction（观测方法）。
    @objc private func switchAudioTrackMenuAction(_ sender: NSMenuItem) {
        let index = (sender.representedObject as? Int) ?? sender.tag
        container?.selectAudioTrack(index)
        refreshAudioMenuSoon()

        let title = container?.audioTracks.first(where: { $0.index == index })?.menuTitle
        container?.showStatusPill("音轨 \(title ?? "#\(index)")", autoHideDelay: 2.0)
    }

    /// 切轨是异步的（要等解封装线程处理请求），两拍刷新让勾选状态落地。
    private func refreshAudioMenuSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshAudioTrackMenu()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshAudioTrackMenu()
        }
    }

    /// disableSubtitlesMenuAction（观测方法）。
    ///
    /// 关字幕也是「选一条轨」，只是选的是一条不存在的轨 —— 所以它和其他轨**平级**
    /// 出现在同一个单选列表里。Phase 3 起真的会把字幕层停掉（`disableSubtitles`
    /// 往引擎投一个 `internalTrack(-1)` 请求）。
    @objc private func disableSubtitlesMenuAction(_ sender: Any?) {
        container?.disableSubtitles()
        // 引擎的切换在解封装线程异步完成，这里立刻重画会显示出**旧**的勾。
        // 延一小会儿再刷，让状态先落地 —— 纯 UI 时序问题，不影响正确性。
        refreshSubtitleMenuSoon()
        container?.showStatusPill(L10n.t("disable_subtitles"), autoHideDelay: 2.0)
    }

    /// switchSubtitleTrackMenuAction（观测方法）。
    @objc private func switchSubtitleTrackMenuAction(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        container?.selectSubtitleTrack(index)
        refreshSubtitleMenuSoon()

        let title = container?.subtitleTracks.first(where: { $0.index == index })?.menuTitle
        container?.showStatusPill("字幕 \(title ?? "#\(index)")", autoHideDelay: 2.0)
    }

    /// 切轨是异步的（要等解封装线程处理请求），所以勾选状态不能同步读。
    /// 两拍：一拍让请求被消费，一拍让引擎的状态刷新出来。
    private func refreshSubtitleMenuSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshSubtitleTrackMenu()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshSubtitleTrackMenu()
        }
    }

    @objc private func openExternalSubtitleMenuAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L10n.t("external_subtitle")
        // 刻意**不**设扩展名过滤：支持清单（ass/ssa/srt/vtt/txt）在
        // `SubtitleFormat` 里，而那个类型只在 `USE_FFMPEG` 分支编译 ——
        // AppDelegate 两套构建都要编，引用它会让占位分支编不过。
        // 与其在这里复制一份会走样的清单，不如放开过滤：选了不支持的格式，
        // 引擎会给出明确的日志（"外挂格式不支持或解析失败"），比"文件灰着选不了"好排查。
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        windowController?.openSubtitleFile(url)
        refreshSubtitleMenuSoon()
    }

    @objc private func openCaptureDeviceMenuAction(_ sender: Any?) {
        windowController?.openCaptureDeviceWithPanel()
    }

    @objc private func openNetworkStreamMenuAction(_ sender: Any?) {
        windowController?.openNetworkStreamWithPanel()
    }

    @objc private func openWindowCaptureMenuAction(_ sender: Any?) {
        windowController?.openWindowCaptureWithPanel()
    }

    /// switchRIFEModelMenuAction（观测方法）。
    @objc private func switchRIFEModelMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = RIFEModelChoice(rawValue: raw) else { return }
        PlaybackSettings.shared.rifeModel = choice
        // 原版这里弹 `rife_model_selected_restart`（"已选择：%@\n下次重启播放器后生效。"）。
        // Phase 2 起管线是热切换的 —— 管线会就地重建，所以弹窗取消，见 noteSettingApplied。
        noteSettingApplied("RIFE 模型：\(choice.title)")
    }

    /// selectRIFEResolutionMenuAction（观测方法）。
    @objc private func selectRIFEResolutionMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let r = RIFEModelResolution(rawValue: raw) else { return }
        PlaybackSettings.shared.rifeResolution = r
        noteSettingApplied("模型分辨率：\(r.title)")
    }

    /// selectRIFEHeavyResolutionMenuAction（观测方法）。
    @objc private func selectRIFEHeavyResolutionMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let r = RIFEModelResolution(rawValue: raw) else { return }
        PlaybackSettings.shared.rifeResolution = r
        noteSettingApplied("\(L10n.t("rife_heavy_model")) · \(r.title)")
    }

    /// selectDRBAVersionMenuAction（观测方法）。
    ///
    /// 注意：DRBA（超分）与 RIFE（补帧）是**两套模型家族**，`PlaybackSettings` 里
    /// 目前只有 RIFE 那一组档位。所以这里跟 Phase 2 之前一样**不落库**，
    /// 只是把选择回显出来 —— 不为了一句提示去编造一个不存在的设置项。
    /// 原版的「下次重启生效」弹窗按本轮要求取消。
    @objc private func selectDRBAVersionMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let v = DistilDRBAModelVersion(rawValue: raw) else { return }
        container?.showStatusPill(MPText.t("DRBA 版本：\(v.title) · 该模型后端尚未接入",
                                           "DRBA version: \(v.title) · backend not wired up yet"),
                                  autoHideDelay: 2.2)
    }

    /// selectDRBAResolutionMenuAction（观测方法）。同样不落库，理由见上。
    @objc private func selectDRBAResolutionMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let r = DistilDRBAModelResolution(rawValue: raw) else { return }
        container?.showStatusPill(MPText.t("DRBA 档位：\(r.title) · 该模型后端尚未接入",
                                           "DRBA preset: \(r.title) · backend not wired up yet"),
                                  autoHideDelay: 2.2)
    }

    @objc private func toggleTransitionDetectionAction(_ sender: Any?) {
        let s = PlaybackSettings.shared
        s.rifeTransitionDetection.toggle()
        container?.showStatusPill(s.rifeTransitionDetection
                                  ? L10n.t("frame_transition_detection_enabled")
                                  : L10n.t("frame_transition_detection_disabled"),
                                  autoHideDelay: 1.8)
    }

    /// switchRIFEWorkerMenuAction（观测方法）。
    @objc private func switchRIFEWorkerMenuAction(_ sender: NSMenuItem) {
        let n = (sender.representedObject as? Int) ?? sender.tag
        PlaybackSettings.shared.rifeWorkerCount = n
        noteSettingApplied(L10n.Placeholders.workerCount(n))
    }

    // MARK: - 设置改完的反馈（热切换的配套）

    /// 设置改完给一句人话。
    ///
    /// 这是本轮改掉的那件事：原版对 RIFE 模型 / 档位 / 核心数一律弹
    /// `rife_settings_saved` + 「下次重启播放器后生效」（`restart_next_launch_with_mode`），
    /// 因为管线是开文件时按当时设置搭好、之后不再动的。
    /// Phase 2 的引擎加了 `reloadInPlace()`（就地拆了重建），所以：
    ///
    ///   · **有文件在放** → 容器监听到变更后会自己走热切换，并显示
    ///     「正在就地应用：xxx …」→「已就地生效：xxx（未重启 APP）」。
    ///     这里**不插话**，否则两条提示会互相盖掉，用户看到的是消息乱闪。
    ///   · **没开文件** → 没什么可重建的，容器不会出声；由这里给一句话，
    ///     否则点完菜单毫无反应，看着像坏了。
    private func noteSettingApplied(_ text: String) {
        guard container?.currentURL == nil else { return }
        container?.showStatusPill(MPText.t("\(text) · 打开视频后生效",
                                           "\(text) · takes effect when a video is opened"),
                                  autoHideDelay: 2.2)
    }

    /// showAboutPanel（观测方法）。
    @objc private func showAboutPanel(_ sender: Any?) {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        var lines = [
            L10n.t("app_description").trimmingCharacters(in: .whitespacesAndNewlines),
            L10n.Placeholders.version(version),
            "",
            L10n.t("developer_info"),
            "",
            L10n.Placeholders.copyright(Calendar.current.component(.year, from: Date())),
            "",
            "重建工程：类型名/签名/字段名/调用面从符号表还原，函数体按 REBUILD-PLAN.md 逐阶段重写。",
        ]
        lines = lines.filter { !$0.isEmpty || true }
        alert(title: L10n.t("about_metalplayer"), body: lines.joined(separator: "\n"))
    }

    @objc private func showDonatePanel(_ sender: Any?) {
        alert(title: L10n.t("support_metalplayer"),
              body: L10n.t("donate_about_text") + "\n\n" + L10n.t("wechat_alipay")
                    + "：付款码展示与 SHA256 校验属后续阶段。")
    }

    /// 观测方法 windowWillClose —— 在 PlayerWindowController 上也有一个（NSWindowDelegate）。
    /// AppDelegate 这个的签名是 `(Notification)`，观测里属于 AppDelegate 自身。
    @objc private func windowWillClose(_ notification: Notification) {
        windowController?.closeCurrentVideo()
    }

    // MARK: - 菜单可用性

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasVideo = container?.currentURL != nil || (container?.isCaptureMode ?? false)
        switch item.action {
        case #selector(closeCurrentVideoMenuAction(_:)),
             #selector(reloadCurrentVideoMenuAction(_:)),
             #selector(savePlaylistMenuAction(_:)):
            return hasVideo
        case #selector(togglePlaylistMenuAction(_:)):
            item.state = (container?.isPlaylistVisible ?? false) ? .on : .off
            return true
        case #selector(toggleStatsMenuAction(_:)):
            item.state = (container?.isStatsVisible ?? false) ? .on : .off
            return true
        case #selector(switchAudioTrackMenuAction(_:)),
             #selector(switchSubtitleTrackMenuAction(_:)),
             #selector(disableSubtitlesMenuAction(_:)):
            return hasVideo
        default:
            return true
        }
    }

    // MARK: - 工具

    private func alert(title: String, body: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: L10n.t("ok"))
        if let window = windowController?.window, window.isVisible {
            a.beginSheetModal(for: window, completionHandler: nil)
        } else {
            a.runModal()
        }
    }

    // MARK: - 开发期：菜单树导出（自动化验收用）

    /// `MP_DUMP_MENU=1` 时把整棵菜单树打到 stderr。
    ///
    /// 为什么需要它：菜单是纯 UI，没法用「跑一遍看日志」验证。
    /// 把标题、勾选状态、启用状态全打出来，就能对着预期结果做**程序化**比对 ——
    /// 包括「开关状态正确回显」那条验收（勾选状态就在这份输出里）。
    func dumpMenuTree() {
        guard let menu = NSApp.mainMenu else { return }
        // 先强制把菜单「更新」一遍。
        //
        // 为什么必须这么干：NSMenu 的部分内容（勾选、启用状态、动态项）是在
        // `update()` 里才落定的，而在真实使用中这个动作由「用户拉开菜单」触发。
        // dump 时没人去拉菜单，所以必须自己调一次 —— 否则看到的是「还没更新」的状态，
        // 与用户真正看到的不一致，验收就白做了。
        // （这一条是踩坑得来：第一版没调 update()，菜单里「窗口」那一节的内容
        //   与实际拉开的对不上，差点放过一个重复项。）
        Self.forceUpdate(menu)

        var out = "\n===== 菜单树（MP_DUMP_MENU）=====\n"
        for item in menu.items {
            guard let sub = item.submenu else { continue }
            out += "[\(sub.title.isEmpty ? "(应用菜单)" : sub.title)]\n"
            out += Self.dump(sub, indent: 1)
        }
        out += "===== 结束 =====\n"
        emit(out)
    }

    /// `MP_DUMP_UI=1` 时把控制条的状态打到 stderr。
    func dumpOverlayState() {
        var out = "\n===== 控制条状态（MP_DUMP_UI）=====\n"
        if let container {
            out += container.dumpOverlayState()
        } else {
            out += "  (没有窗口控制器 / 容器)"
        }
        if let container {
            out += "\n  currentURL: \(container.currentURL?.lastPathComponent ?? "nil")"
            out += "\n  isPlaying: \(container.isPlaying)"
            out += "\n  audioTracks: \(container.audioTracks.count)"
            out += "\n  subtitleTracks: \(container.subtitleTracks.count)"
            out += "\n  playlistVisible: \(container.isPlaylistVisible)"
        }
        out += "\n===== 结束 =====\n"
        emit(out)
    }

    /// `MP_DUMP_STATS=1` 时把性能监看面板的文本打到 stderr。
    ///
    /// 与 `MP_DUMP_UI` / `MP_DUMP_MENU` 同一套做法：面板是纯 UI，没法用「跑一遍看日志」
    /// 验证，就把它的**文本内容**导出来做程序化比对。三节内容（源参数 / 输出参数 /
    /// 性能参数）都在里面，所以这一条 dump 同时覆盖了「按 Tab 能显示详细参数」那条验收。
    ///
    /// 会**先把面板点亮**再导：面板不可见时刷新定时器是停的（这是刻意的，见
    /// `StatsPanelView.startTimer`），不点亮就永远只有构造时那一拍的空白数据。
    func dumpStatsState() {
        var out = "\n===== 性能监看（MP_DUMP_STATS）=====\n"
        if let container {
            container.setStatsVisible(true)
            container.refreshStatsPanel()
            out += container.dumpStatsState()
            out += "\n  panelVisible: \(container.isStatsVisible)"
            // 字幕层（Phase 3）。单独列一段而不是塞进那三节里：
            // 那三节是「源参数 / 输出参数 / 性能」，字幕不属于其中任何一类，
            // 硬塞进去会让人以为它是性能的一部分。
            out += "\n\n---- 字幕层 ----\n"
            out += container.subtitleDumpText() + "\n"
        } else {
            out += "  (没有窗口控制器 / 容器)"
        }
        out += "\n===== 结束 =====\n"
        emit(out)
    }

    /// 递归 `update()`。顺便把每个 AppKit 动态插入的项都归位。
    private static func forceUpdate(_ menu: NSMenu) {        menu.update()
        for item in menu.items {
            if let sub = item.submenu { forceUpdate(sub) }
        }
    }

    private static func dump(_ menu: NSMenu, indent: Int) -> String {
        var out = ""
        let pad = String(repeating: "  ", count: indent)
        for item in menu.items {
            if item.isSeparatorItem { out += "\(pad)---\n"; continue }
            let mark = item.state == .on ? "✓" : " "
            let enabled = item.isEnabled ? "" : "  (禁用)"
            // 打出 action 选择器：用来区分「我们自己造的项」与「AppKit 自动塞的标准项」。
            // 这个字段是定位「进入全屏出现两条」那类问题的关键 —— 光看标题分不出谁是谁。
            let action = item.action.map { "  ⟨\(NSStringFromSelector($0))⟩" } ?? ""
            out += "\(pad)\(mark) \(item.title)\(enabled)\(action)\n"
            if let sub = item.submenu { out += dump(sub, indent: indent + 1) }
        }
        return out
    }
}

// 注：观测到的两个模块级全局变量
//     MetalPlayer.app      : __C.NSApplication
//     MetalPlayer.delegate : MetalPlayer.AppDelegate
// 由 `MetalPlayer/App/main.swift` 声明（那份仍由 generate.py 生成，因为它就是手写入口
// 的最小形态）。这里**不能**再声明一次 —— 同一模块内的 file-scope `let app` 会重名。
