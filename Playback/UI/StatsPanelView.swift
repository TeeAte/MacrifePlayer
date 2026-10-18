//  StatsPanelView.swift
//  MetalPlayer 重建工程 —— 性能监看面板（Phase 2 增补）
//
//  按 **Tab** 切换显示。面板分三节：
//      ① 源视频参数   —— 容器 / 编码 / 分辨率 / 帧率 / 像素格式 / 色彩 / 音轨
//      ② 补帧后参数   —— 目标帧率 / 输出分辨率 / 模型 / 核心数 / MetalFX / Anime4K / 解码方式
//      ③ 性能参数     —— 渲染 FPS / 解码 FPS / 帧与丢帧 / 三条队列 / 音画偏差 / CPU / 内存 / GPU
//
//  ⚠️ 这个面板是**本工程新增的功能**，不是从二进制恢复的：
//  符号表给不出 UI 行为，原版有没有这个面板无从得知。所以：
//    · 「源视频参数」全部来自 FFmpeg 的真实读数（`MediaDetail`）；
//    · 「补帧后参数」里的目标帧率是**按当前档位算出来的**（源帧率 × 倍数）；
//      但 RIFE/MetalFX/Anime4K 的**后端都还没接入**（Phase 4/5），
//      所以面板会据此显式标注「后端未接入」—— 不把「设置里的选择」画成「已经生效」。
//
//  为什么用等宽字体 + 定宽标签：这是一个读数面板，数字要能对齐着扫，
//  比例字体下 FPS 每帧跳动会让整行左右抖。
//
//  **面板没有背景板**（刻意的，不是漏做）：它压在全屏画面上，一块半透明底
//  等于把下面的画面糊掉一块 —— 而这块面板存在的意义恰恰是「边看画面边调参数」。
//  采用白色文字搭配柔和灰色外阴影（无描边），兼顾文字边缘平滑度与不同画面的对比度。
//
//  ⚠️ 语言：本文件里的界面文字**只有中文**，没走 `L10n` 也没走 `MPText`。
//  这是已知取舍（不是漏做）：面板正文是三节 × 每节五到七行的
//  「标签 + 数字」拼装，双语化要把每个片段都包一层取词函数，
//  渲染代码立刻淹没在文案里；而这是个偏调试向的读数面（与 `MP_TRACE` 的
//  追踪日志同一性质，那些日志也是中文的）。菜单项与状态胶囊这些**产品chrome**
//  则走 `MPText` 做了双语。理由同样记在 `MPText` 的文档注释里。

import Foundation
import AppKit

final class StatsPanelView: NSView {

    // MARK: 子视图

    private let stack = NSStackView()

    /// 三节的文本控件。分三个而不是一个大的：节之间可以用不同字号，
    /// 也便于将来单独折叠某一节。
    private let sourceHeading = StatsPanelView.makeHeading()
    private let sourceBody = StatsPanelView.makeBody()
    private let outputHeading = StatsPanelView.makeHeading()
    private let outputBody = StatsPanelView.makeBody()
    private let perfHeading = StatsPanelView.makeHeading()
    private let perfBody = StatsPanelView.makeBody()

    // MARK: 刷新用的采样器

    private let sampler = StatsSampler()

    /// 面板可见时才拉起定时器 —— 不可见时一次采样都不做，不占 CPU。
    private var refreshTimer: Timer?
    private var countersProvider: (() -> PlaybackCounters)?
    private var detailProvider: (() -> MediaDetail)?

    /// ① 里追加的「字幕」一行。
    ///
    /// 单独一个 provider 而不是并进 `configure`：`configure` 的签名只承载
    /// 「FFmpeg 读数」这一件事，字幕是 Phase 3 才有的、且**只有真实构建**才有意义的
    /// 一项。并进去会让占位构建也得凭空造一个假值出来。
    /// 不设这个闭包时，① 里那一行直接不出现 —— 与「没有字幕轨」表现一致。
    private var subtitleLineProvider: (() -> String?)?
    private var audioLineProvider: (() -> String?)?

    /// 刷新间隔。性能面板不需要 60Hz：0.5s 已经足够看清趋势，
    /// 且 0.5s 窗口的 FPS 读数比每帧更新稳定得多（后者数字会疯狂跳）。
    private static let refreshInterval: TimeInterval = 0.5

    // MARK: - 构造

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    // 字号与配色抽成常量：`styled` 要按它们拼富文本，而富文本一旦写进控件，
    // `field.font` / `field.textColor` 的读回值就跟着富文本走、不再可靠。
    // 样式只有一个来源，才不会出现「标签按 A 排版、样式按 B 算」的错位。
    // 配色：**纯白填充 + 灰色外阴影**（无描边，字形平滑清晰）。
    private static let headingFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    private static let headingColor = NSColor.white
    private static let bodyFont = NSFont.monospacedSystemFont(ofSize: 12.0, weight: .regular)
    private static let bodyColor = NSColor.white

    private static let textShadow: NSShadow = {
        let s = NSShadow()
        s.shadowColor = NSColor(calibratedWhite: 0.05, alpha: 0.85)
        s.shadowOffset = NSSize(width: 0.5, height: -1.0)
        s.shadowBlurRadius = 2.0
        return s
    }()

    private static func makeHeading() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = headingFont
        l.textColor = headingColor
        l.usesSingleLineMode = true
        l.lineBreakMode = .byTruncatingTail
        l.maximumNumberOfLines = 1
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private static func makeBody() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = bodyFont
        l.textColor = bodyColor
        l.translatesAutoresizingMaskIntoConstraints = false
        // **一行一条读数，超长就截断**，不换行。
        // 正确的组合是：**允许多行（行数不限）+ 每行超宽就截断（不折行）**。
        l.usesSingleLineMode = false
        l.maximumNumberOfLines = 0
        l.lineBreakMode = .byTruncatingTail
        // 压缩抗性给低：面板被窗口挤窄时宁可截断文字，也不要把其它约束顶破。
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    // MARK: - 文本样式（白字 + 灰色外阴影）

    private func setHeading(_ field: NSTextField, _ text: String) {
        field.attributedStringValue = Self.styled(text,
                                                  font: Self.headingFont,
                                                  fill: Self.headingColor)
    }

    private func setBody(_ field: NSTextField, _ text: String) {
        field.attributedStringValue = Self.styled(text,
                                                  font: Self.bodyFont,
                                                  fill: Self.bodyColor)
    }

    private static func styled(_ text: String, font: NSFont, fill: NSColor) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: fill,
            .shadow: textShadow,
            .paragraphStyle: para,
        ])
    }

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // 没有背景板，但**裁切要留**：窗口被压得很矮时，下面那条撑高约束（999）
        // 会被容器里那条 required 的「面板下沿 <= 控制条顶部」打破，
        // 多出来的文本必须被裁掉，而不是溢出去盖住控制条。
        layer?.masksToBounds = true

        stack.orientation = .vertical
        // `.leading` + 逐条宽度约束（在下面），**不是** `.width`。
        //
        // 原来写的是 `stack.alignment = .width`，以为它能让每行铺满面板宽度。
        // 实测不是那么回事 —— 它让每个子视图保持**固有宽度**并靠右贴齐：
        // 六个控件 frame 的右边缘全是 438（= 栈右边界），左边参差不齐，
        // 于是整块文本贴在面板右侧、正文的宽行还越过了面板左边界。
        // 证据（`--dump-frames`）：
        //     ①标题 {{368.5, 319}, {69.5, 13}}
        //     ①正文 {{78.5, 232},  {359.5, 84}}
        //     ②标题 {{355, 210},   {83, 13}}        ← 右边缘都是 438
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false

        for v in [sourceHeading, sourceBody, outputHeading, outputBody, perfHeading, perfBody] {
            stack.addArrangedSubview(v)
        }
        // `setCustomSpacing` 必须在 `addArrangedSubview` **之后**调 ——
        // 它按「已排布的子视图」记间距，先调会被丢掉（这个不报错，只是节间距静默失效）。
        stack.setCustomSpacing(9, after: sourceBody)
        stack.setCustomSpacing(9, after: outputBody)
        addSubview(stack)

        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ]
        // 宽度得逐条钉：`.leading` 对齐下，栈**不会**给子视图加 trailing 约束，
        // 标签就保持固有宽度 —— `byTruncatingTail` 永远不触发，
        // 长行会从面板右边缘直接切掉（连省略号都没有，看着像渲染坏了）。
        for v in [sourceHeading, sourceBody, outputHeading, outputBody, perfHeading, perfBody] {
            constraints.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        // 面板高度 = 内容高度。给 999 而不是 required：
        // 窗口太矮时，外面那条 `bottom <= 控制条顶部`（required）优先，
        // 这条被打破 → 内容下沿被裁掉（见上面的 `masksToBounds`）。**不能**反过来
        //（内容优先），那会导致面板盖住控制条，用户没法拖进度条。
        let fitContent = stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        fitContent.priority = NSLayoutConstraint.Priority(999)
        fitContent.isActive = true
    }

    // MARK: - 数据接线

    /// 面板每次刷新都向这两个闭包要数据。
    ///
    /// 传闭包而不是传值：容器持有引擎，引擎的数据随时在变；
    /// 面板只该在**自己可见时**去取，所以由它反拉，而不是让容器推。
    func configure(counters: @escaping () -> PlaybackCounters,
                   detail: @escaping () -> MediaDetail) {
        countersProvider = counters
        detailProvider = detail
        refreshNow()
    }

    /// ①「源视频参数」里补一行字幕轨说明（Phase 3）。
    ///
    /// 为什么字幕要出现在**①源**里而不是新开一节：它描述的是**源文件里有什么** ——
    /// 与容器/编码/分辨率同级，不是「补帧后的输出」，也不是性能读数。
    /// 返回 nil / 空串表示这一行不显示。
    func setSubtitleLineProvider(_ provider: @escaping () -> String?) {
        subtitleLineProvider = provider
    }

    /// ①「源视频参数」里补一行音轨说明（Phase 3.5）。
    func setAudioLineProvider(_ provider: @escaping () -> String?) {
        audioLineProvider = provider
    }

    /// 换文件 / 热切换之后调用。
    ///
    /// FPS 是「计数差 ÷ 时间差」算出来的。重建管线后计数器归零，而采样器手里
    /// 还攥着上一个文件的末次计数 —— 不清的话下一拍就是 `(0 - 12345) / 0.5`，
    /// 面板上闪出一个负号天文数字，看起来像坏了。
    func resetSampling() {
        sampler.reset()
        refreshNow()
    }

    // MARK: - 显示 / 隐藏

    private(set) var isShown = false

    func show() {
        guard !isShown else { return }
        isShown = true
        isHidden = false
        sampler.reset()
        refreshNow()
        startTimer()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        isHidden = true
        stopTimer()
    }

    func toggle() { isShown ? hide() : show() }

    private func startTimer() {
        stopTimer()
        // .common：拖进度条 / 弹菜单时 runloop 会切到 event tracking 模式，
        // 不加这个 mode 定时器会被挂起，面板数字就定住了。
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    deinit { stopTimer() }

    // MARK: - 开发期：把面板自身导成 PNG（MP_STATS_PNG）

    /// 把面板**视图本身**渲染成一张位图。
    ///
    /// 为什么值得有：这个面板是纯视觉的，而「文字描边读不读得清」「背后还有没有
    /// 那块底板」这两件事**用文本 dump 证明不了** —— dump 出来的字符串在两种实现下
    /// 一模一样。只有把它画成图才看得见。
    ///
    /// 背景是**透明**的（面板本来就没有底板），所以导出的 PNG 可以叠到任意
    /// 视频帧上看效果 —— 这也顺带成了「没有矩形背景」这个断言的证据。
    ///
    /// 渲染方式的选择与两条路的差别写在 `ViewSnapshot` 文件头。
    func snapshotForExport() -> CGImage? {
        // 面板默认隐藏。隐藏时没有内容可画，必须先显示并跑一次刷新，
        // 否则拿到的是空的（连文本都还没设过）。
        if !isShown { show() } else { refreshNow() }
        return ViewSnapshot.layerImage(of: self)
    }

    /// 面板与六个文本控件的**真实 frame**（`--stats-png` 一并打出）。
    ///
    /// 为什么需要它：面板去掉底板之后，导出的图上就再也看不出面板的边界了 ——
    /// 「文字到底有没有溢出面板」「六个控件各占多高」只能靠数字说话。
    /// 它顺手还记下每个控件的行数上限，那是判断「正文为什么只画出一行」的关键线索。
    func framesDebugText() -> String {
        // ⚠️ 必须先**强制跑一次布局**再读 frame，否则读到的是上一轮的值 ——
        // 这个坑实打实踩过：`refreshNow()` 刚改过 `stringValue`，
        // 文本的固有高度变了、布局被标脏但还没重算，这时读到的 frame
        // 是「旧高度 + 新内容」的混合体，看起来就像「正文只画出一行」
        //（实测 ①正文 x=-2、宽 440 而栈只有 436 —— 数字自相矛盾，
        // 那不是布局坏了，是读数读早了）。
        //
        // 面板默认隐藏，隐藏时没有布局可言，先显示出来。
        if !isShown { show() }
        window?.layoutIfNeeded()
        layoutSubtreeIfNeeded()

        var lines: [String] = []
        lines.append(String(format: "面板    %@  (边界 %.0fx%.0f pt)",
                            NSStringFromRect(frame), bounds.width, bounds.height))
        lines.append(String(format: "文本栈  %@", NSStringFromRect(stack.frame)))
        let named: [(String, NSTextField)] = [
            ("①标题", sourceHeading), ("①正文", sourceBody),
            ("②标题", outputHeading), ("②正文", outputBody),
            ("③标题", perfHeading), ("③正文", perfBody),
        ]
        for (name, f) in named {
            let stringLines = f.stringValue.components(separatedBy: "\n").count
            lines.append(String(format: "%@  %@ · 行数上限 %d · 字符串 %d 行 · 固有 %.0fx%.0f",
                                name, NSStringFromRect(f.frame),
                                f.maximumNumberOfLines, stringLines,
                                f.intrinsicContentSize.width, f.intrinsicContentSize.height))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 刷新

    /// 最近一次采样结果。给 dev 诊断（`MP_CAPTURE_GO`）读实测值用 ——
    /// 面板自己只负责画，把这份数据留一份可读副本，比让学生去猜内部状态可靠。
    private(set) var lastStats = PlaybackRuntimeStats()

    /// dev：返回最近一次采样，必要时先刷新一次（保证拿到的是当前值而不是旧的）。
    func currentRuntimeStats() -> PlaybackRuntimeStats {
        refreshNow()
        return lastStats
    }

    func refreshNow() {
        let detail = detailProvider?() ?? MediaDetail()
        let counters = countersProvider?() ?? PlaybackCounters.empty
        let stats = sampler.sample(counters)
        lastStats = stats

        renderSource(detail, subtitleLine: subtitleLineProvider?(), audioLine: audioLineProvider?(),
                     captureColor: stats.captureColorInfo)
        renderOutput(detail, stats: stats)
        renderPerformance(stats)
    }

    // MARK: ① 源视频

    private func renderSource(_ d: MediaDetail, subtitleLine: String? = nil,
                              audioLine: String? = nil, captureColor: String = "") {
        setHeading(sourceHeading, "① 源视频参数")
        guard d.hasAny else {
            setBody(sourceBody, "未打开文件")
            return
        }

        let c = d.container
        var lines: [String] = []

        var head = c.fileName
        if !c.formatLongName.isEmpty { head += "  ·  \(c.formatLongName)" }
        else if c.formatName != "?" { head += "  ·  \(c.formatName)" }
        lines.append(head)

        var meta: [String] = []
        if c.duration > 0 { meta.append(TimeFormat.clock(c.duration)) }
        if let t = MediaDetail.bitRateText(c.bitRate).nilIfEmpty { meta.append("总码率 \(t)") }
        if let t = MediaDetail.fileSizeText(c.fileSize).nilIfEmpty { meta.append(t) }
        meta.append("流 \(c.streamCount)"
                    + "（V\(c.videoCount)/A\(c.audioCount)/S\(c.subtitleCount)）")
        lines.append(meta.joined(separator: "  ·  "))

        if let v = d.video {
            var vline = "视频  \(v.codec)"
            if !v.profileLevelText.isEmpty { vline += " \(v.profileLevelText)" }
            vline += "  \(v.resolutionText)  \(MediaDetail.frameRateText(v.frameRate))"
            lines.append(vline)

            var v2: [String] = ["像素 \(v.pixelFormat)"]
            if let t = MediaDetail.bitRateText(v.bitRate).nilIfEmpty { v2.append("码率 \(t)") }
            var color: [String] = []
            if !v.colorPrimaries.isEmpty { color.append(v.colorPrimaries) }
            if !v.colorTransfer.isEmpty { color.append(v.colorTransfer) }
            if !v.colorSpace.isEmpty { color.append(v.colorSpace) }
            if !v.colorRange.isEmpty { color.append(v.colorRange) }
            // 采集卡：色彩不是从文件元数据来的，而是从每个样本缓冲**实测**的
            //（原版 VideoColorInfo.resolvedSDR）。没有它就只能看到「像素 nv12」，
            // 范围/矩阵用错了也无从判断。
            if !captureColor.isEmpty, captureColor != "—" { color.append(captureColor) }
            if !color.isEmpty { v2.append("色彩 " + color.joined(separator: "/")) }
            lines.append(v2.joined(separator: "  ·  "))
        }

        if let a = d.audio {
            var aline = "音频  \(a.codec)"
            if !a.profile.isEmpty { aline += " \(a.profile)" }
            var ap: [String] = []
            if a.sampleRate > 0 { ap.append("\(a.sampleRate) Hz") }
            if a.channels > 0 {
                ap.append(a.channelLayout.isEmpty ? "\(a.channels) ch"
                                                  : "\(a.channels) ch (\(a.channelLayout))")
            }
            if !a.sampleFormat.isEmpty { ap.append(a.sampleFormat) }
            if !ap.isEmpty { aline += "  " + ap.joined(separator: " · ") }
            lines.append(aline)

            if let audioLine, !audioLine.isEmpty {
                lines.append("音轨  " + audioLine)
            } else if let t = MediaDetail.bitRateText(a.bitRate).nilIfEmpty {
                lines.append("音频码率  \(t)")
            }
        } else {
            lines.append("音频  无")
        }

        // 字幕（Phase 3）。放在音频之后 —— 与 ffprobe 的行序一致，
        // 也符合「视频 / 音频 / 字幕」这个习惯顺序。
        if let sub = subtitleLine, !sub.isEmpty {
            lines.append("字幕  " + sub)
        }

        setBody(sourceBody, lines.joined(separator: "\n"))
    }

    // MARK: ② 补帧后

    private func renderOutput(_ d: MediaDetail, stats: PlaybackRuntimeStats) {
        setHeading(outputHeading, "② 补帧后（输出）")
        let s = PlaybackSettings.shared

        let sourceFPS = d.video?.frameRate ?? 0
        let targetFPS = Self.targetFrameRate(source: sourceFPS, mode: s.rifeRateMode)

        // 输出分辨率：MetalFX 空间超分辨率
        var resLine = "—"
        if let v = d.video {
            if s.metalFX == .spatial {
                resLine = "\(v.width)x\(v.height) → \(v.width * 2)x\(v.height * 2) (MetalFX 空间上采样)"
            } else {
                resLine = "\(v.width)x\(v.height)"
            }
        }

        var lines: [String] = []
        let targetText = targetFPS > 0 ? MediaDetail.frameRateText(targetFPS) : "—"

        var enhanceParts: [String] = []
        if s.metalFX == .spatial {
            enhanceParts.append("MetalFX 空间上采样")
        } else {
            enhanceParts.append("MetalFX 关闭")
        }
        if s.anime4k == .on {
            enhanceParts.append("Anime4K 开启 (\(s.anime4kPresetID.shortTitle))")
        } else {
            enhanceParts.append("Anime4K 关闭")
        }
        let enhanceLine = "增强  " + enhanceParts.joined(separator: "  ·  ")

        if s.rifeRateMode != .off {
            let actualFPS = stats.renderFPS > 0 ? String(format: " · 实测 %.1f FPS", stats.renderFPS) : ""
            let familyName = s.rifeModel.isFLAVR ? "FLAVR" : "RIFE"
            let archNote = s.rifeModel.isFLAVR ? " (3D-CNN · ANE加速)" : ""
            lines.append("补帧  \(s.rifeRateMode.statusTitle) (\(familyName))  ·  目标 \(targetText)\(actualFPS)")
            lines.append(String(format: "模型  %@%@  ·  缩放 %.2fx  ·  %@", s.rifeModel.title, archNote, s.rifeScaleFactor, s.rifePrecision.shortTitle))
            lines.append(String(format: "核心  %d 核  ·  缓冲 %d 帧  ·  质量 %@", s.rifeWorkerCount, s.rifeQueueDepth, s.rifeQualityMode.title))
            lines.append(String(format: "保护  转场保护 %@ (%.0f%%)  ·  静帧跳过 %@",
                                s.rifeTransitionDetection ? "开" : "关",
                                s.rifeSceneThreshold * 100,
                                s.rifeStaticFrameSkip ? "开" : "关"))
            let countSuffix = stats.rifeInterpolatedFrames > 0 ? "（已插帧 \(stats.rifeInterpolatedFrames) 帧）" : "（插帧管线就绪）"
            lines.append("输出  \(resLine)  \(countSuffix)")
            lines.append(enhanceLine)
            if stats.videoDecoderName.isEmpty {
                lines.append("解码  \(s.decodeMode.title)")
            } else if stats.isHardwareDecode {
                lines.append("解码  硬解（VideoToolbox · \(stats.videoDecoderName)）")
            } else {
                lines.append("解码  软解（\(stats.videoDecoderName)）")
            }
            if s.deinterlaceMode != .off {
                let deintTitle = (s.deinterlaceMode == .auto) ? "智能反交错 (MTS 50i/60i 2X 倍频)" : "强制 2X 双场反交错"
                lines.append("反交错  \(deintTitle)")
            }
            if d.container.formatName.contains("采集卡") {
                if s.captureLowLatencyMode != .off {
                    let latencyText = (s.captureLowLatencyMode == .extreme) ? "极限电竞 (1帧缓冲直出 · 零堆积)" : "平衡抗抖动 (2帧缓冲)"
                    lines.append("输入延迟  \(latencyText)")
                }
                if s.fake60FPSOptimization != .off {
                    let cadence = CadenceDetector.shared.currentCadence
                    if cadence == .fake60From30 {
                        lines.append("假60识别  ✅ 命中 2:2 假60 (主机30FPS) · 已AI重构真60帧")
                    } else {
                        lines.append("假60识别  智能监听中 (HDMI 60Hz 防卡顿)")
                    }
                }
            }
            if s.metalFX == .spatial || s.anime4k == .on {
                lines.append("状态  ✅ \(familyName) 补帧 (\(targetText)) + 画质增强 全链路活跃")
            } else {
                lines.append("状态  ✅ \(familyName) AI 补帧活跃运行中 · 输出 \(targetText)")
            }
        } else {
            lines.append("补帧  关闭（原始帧率直通）")
            lines.append(String(format: "模型  %@  ·  缩放 %.2fx  ·  %@", s.rifeModel.title, s.rifeScaleFactor, s.rifePrecision.shortTitle))
            lines.append(String(format: "核心  %d 核  ·  缓冲 %d 帧  ·  质量 %@", s.rifeWorkerCount, s.rifeQueueDepth, s.rifeQualityMode.title))
            lines.append(String(format: "保护  转场保护 %@ (%.0f%%)  ·  静帧跳过 %@",
                                s.rifeTransitionDetection ? "开" : "关",
                                s.rifeSceneThreshold * 100,
                                s.rifeStaticFrameSkip ? "开" : "关"))
            lines.append("输出  \(resLine)")
            lines.append(enhanceLine)
            if stats.videoDecoderName.isEmpty {
                lines.append("解码  \(s.decodeMode.title)")
            } else if stats.isHardwareDecode {
                lines.append("解码  硬解（VideoToolbox · \(stats.videoDecoderName)）")
            } else {
                lines.append("解码  软解（\(stats.videoDecoderName)）")
            }
            if s.deinterlaceMode != .off {
                let deintTitle = (s.deinterlaceMode == .auto) ? "智能反交错 (MTS 50i/60i 2X 倍频)" : "强制 2X 双场反交错"
                lines.append("反交错  \(deintTitle)")
            }
            if d.container.formatName.contains("采集卡") {
                if s.captureLowLatencyMode != .off {
                    let latencyText = (s.captureLowLatencyMode == .extreme) ? "极限电竞 (1帧缓冲直出 · 零堆积)" : "平衡抗抖动 (2帧缓冲)"
                    lines.append("输入延迟  \(latencyText)")
                }
                if s.fake60FPSOptimization != .off {
                    let cadence = CadenceDetector.shared.currentCadence
                    if cadence == .fake60From30 {
                        lines.append("假60识别  ✅ 命中 2:2 假60 (主机30FPS) · 已AI重构真60帧")
                    } else {
                        lines.append("假60识别  智能监听中 (HDMI 60Hz 防卡顿)")
                    }
                }
            }
            if s.metalFX == .spatial || s.anime4k == .on {
                lines.append("状态  ✅ 画质增强活跃运行中 (MetalFX / Anime4K)")
            } else {
                lines.append("状态  增强链路全关（输出 = 源帧率）")
            }
        }

        setBody(outputBody, lines.joined(separator: "\n"))
    }

    /// 目标帧率 = 源帧率 × 档位倍数；`.fps60`, `.fps120`, `.customFps` 是目标帧率。
    static func targetFrameRate(source: Double, mode: RIFERateMode) -> Double {
        guard source > 0 else { return 0 }
        switch mode {
        case .off:       return source
        case .fps60:     return 60
        case .fps120:    return 120
        case .customFps: return PlaybackSettings.shared.rifeCustomTargetFps
        default:         return source * Double(mode.multiplier ?? 1)
        }
    }

    // MARK: ③ 性能

    private func renderPerformance(_ s: PlaybackRuntimeStats) {
        setHeading(perfHeading, "③ 性能参数")

        let q = s.queues
        var lines: [String] = []
        // 采集模式下把「采集卡实测投递帧率」摆在最前面 —— 它是判断
        //「20 fps 到底是采集没出帧、还是渲染没上屏」的唯一分界线。
        if s.captureDeliveredFPS > 0 {
            lines.append(String(format: "采集 %6.1f fps    渲染 %6.1f fps    解码 %6.1f fps",
                                s.captureDeliveredFPS, s.renderFPS, s.decodeFPS))
        } else {
            lines.append(String(format: "渲染 %6.1f fps    解码 %6.1f fps", s.renderFPS, s.decodeFPS))
        }
        lines.append("帧    已解码 \(s.decodedFrames)  已上屏 \(s.presentedFrames)  丢帧 \(s.droppedFrames)")
        lines.append("队列  视频包 \(q.videoPacket)/\(q.videoPacketCapacity)"
                     + "  音频包 \(q.audioPacket)/\(q.audioPacketCapacity)"
                     + "  帧 \(q.frame)/\(q.frameCapacity)")
        lines.append(String(format: "音画  时钟 %.2fs  末帧 %.2fs  偏差 %+.3fs  ·  %@",
                            s.currentTime,
                            s.lastPresentedPTS >= 0 ? s.lastPresentedPTS : 0.0,
                            s.avDrift,
                            s.usesAudioClock ? "音频主时钟" : "墙钟"))
        // 三个内存口径都摆出来：IOSurface 不计入 phys_footprint，补帧链路
        // 却大量用它 —— 只报一个数，用户看活动监视器和看面板会得出相反结论。
        lines.append(String(format:
            "资源  CPU %.1f%%  内存 RSS %.0f / 足迹 %.0f / 压缩 %.0f MB  ·  GPU %@",
                            s.cpuPercent, s.memoryMB, s.footprintMB, s.compressedMB, s.gpuName))
        lines.append("状态  \(s.stateText)")
        setBody(perfBody, lines.joined(separator: "\n"))
    }

    // MARK: - 开发期：文本快照（MP_DUMP_STATS）

    /// 把面板当前显示的内容原样打出来，供自动化验收。
    /// 与 `MP_DUMP_MENU` / `MP_DUMP_UI` 同一套思路：UI 没法用「跑一遍看日志」验证，
    /// 就把它的文本内容导出成可比对的字符串。
    func dumpText() -> String {
        var out = ""
        for v in [sourceHeading, sourceBody, outputHeading, outputBody, perfHeading, perfBody] {
            out += v.stringValue + "\n"
        }
        return out
    }
}

// MARK: - 小工具

private extension String {
    /// 空串当 nil 用 —— 让「有值才拼进去」写成一行。
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
