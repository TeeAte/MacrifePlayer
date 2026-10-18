//  AssSubtitleRenderer.swift
//  MetalPlayer 重建工程 —— Phase 3 字幕渲染（libass 封装）
//
//  ┌ 接口不是我设计的，是从符号表**观测**来的
//  │
//  │ 原版二进制里有 `final class AssSubtitleRenderer`（元数据访问器 CMa），
//  │ REA 在 MetalPlayer/Subtitle/AssSubtitleRenderer.swift 留下了骨架，
//  │ 里面带着 demangle 出来的方法签名：
//  │
//  │     init(codecPrivate: Data, fontDirectories: [URL], embeddedFonts: [SubtitleEmbeddedFont])
//  │     init(script: String,   fontDirectories: [URL], embeddedFonts: [SubtitleEmbeddedFont])
//  │     func installFonts(fontDirectories: [URL], embeddedFonts: [SubtitleEmbeddedFont])
//  │     func processASSChunk(data: Data, startMs: Int64, durationMs: Int64)
//  │     func render(at: Double, width: Int, height: Int) -> SubtitleBitmap?
//  │
//  │ 本文件**逐条照抄这些签名**（而不是我另起一套更好看的 API），
//  │ 理由与 Phase 2 对齐 UI 类时相同：签名是观测到的既有事实，
//  │ 改掉它就等于丢掉了一条「原版到底怎么工作」的证据。
//  │
//  │ 两个 init 的分工也一目了然：
//  │     codecPrivate → 内封字幕（容器给的 extradata，含样式表）
//  │     script       → 外挂字幕（整份 ASS 文本）
//  │ processASSChunk 收的是**毫秒**（startMs / durationMs），不是秒。
//  └
//
//  ┌ 底层只用原版用过的那些 libass 函数
//  │
//  │ 原版 undefined 符号里 libass 相关的只有 16 个（清单见下），
//  │ 本文件一个不多一个不少：
//  │     ass_library_init / ass_library_done
//  │     ass_renderer_init / ass_renderer_done
//  │     ass_new_track / ass_free_track
//  │     ass_read_memory / ass_process_codec_private / ass_process_chunk
//  │     ass_render_frame
//  │     ass_set_fonts / ass_set_fonts_dir / ass_add_font / ass_set_extract_fonts
//  │     ass_set_frame_size / ass_set_message_cb
//  │
//  │ 唯一的偏差：**ass_set_message_cb 没接**。它的回调签名带 va_list，
//  │ Swift 无法声明这种参数（C 可变参数在 Swift 侧没有对应类型），
//  │ 要接就得往 shim 里塞一个 .c 文件做 vsnprintf 中转 —— 为一条日志不值得。
//  │ 不接的后果只是 libass 的日志走它默认的 stderr 输出（反而看得见）。
//  │ 记在 RECON-REPORT 的偏差清单里。
//  └
//
//  ┌ 为什么不需要 ass_flush_events
//  │
//  │ 上面那份清单里没有它，这不是遗漏 —— 原版不需要：
//  │
//  │ libass 的 track 是「按时间索引的事件集合」，渲染是「查当前时间命中哪些事件」。
//  │ 从 60s seek 回 10s，track 里 0–60s 的事件都还在，但 10s 处该显示哪条，
//  │ 结果与「只有 10s 附近事件」时**完全一样**。所以往后 seek 不必清。
//  │ 只有**换轨**才必须重来 —— 而这里换轨的方式是直接换一个 renderer 实例
//  │ （旧的 deinit 释放），比 flush 更干净。
//  └
//
//  ┌ 线程模型：内部一把锁
//  │
//  │ 写者：解封装线程（processASSChunk 往 track 里加事件）
//  │ 读者：主线程（MTKView 的 draw 回调里 render）
//  │ ASS_Track / ASS_Renderer 都不是线程安全的，两个调用必须互斥。
//  │ 锁粒度很小（加一条事件 = 解析一行文本；渲染走 libass 内部字形缓存），
//  │ 而字幕数据是低频的（几秒一个包），不会成为瓶颈。
//  └
//
//  ┌ 合成：CPU 侧做成预乘 alpha
//  │
//  │ libass 给的是「一串 ASS_Image，每张一个 1bpp 覆盖率位图 + 一个颜色」，
//  │ 链表顺序**就是**绘制顺序（实测：shadow → outline → character，
//  │ 各带自己的 dst 偏移）。这里按顺序叠成一张预乘 alpha 的 BGRA8。
//  │ 预乘的理由：描边 + 阴影 + 半透明文字叠在一起时，非预乘要逐层做除法，
//  │ 既慢又容易在低 alpha 处出色边。
//  └

import Foundation
import CAss

final class AssSubtitleRenderer {

    // MARK: - libass 句柄

    private var library: OpaquePointer?
    private var renderer: OpaquePointer?
    private var track: UnsafeMutablePointer<ass_track>?

    /// 罩住所有 libass 调用。理由见文件头。
    private let lock = NSLock()

    // MARK: - 状态

    /// 是不是外挂脚本建的（外挂自带全部事件，不再接受 processASSChunk）。
    private let isExternalScript: Bool

    /// 已喂进去的事件条数。
    private(set) var eventCount = 0
    /// 最近一条事件文本（截断），dev dump 用。
    private(set) var lastEventText = ""

    /// 渲染目标尺寸。libass 只在尺寸变化时才需要重设，这里记着免得每帧都调。
    private var frameWidth = 0
    private var frameHeight = 0
    /// 尺寸刚变过（或刚刚换了 track）：下一帧必须重新合成，哪怕 libass 说「没变」。
    private var needsRecompose = true
    /// 最近一次渲染叠了几张图。
    private(set) var lastImageCount = 0

    /// 建 track 用的原始素材，`resetTrack()` 要拿它重建。
    ///
    /// 留一份的理由见 `resetTrack()` —— seek 之后必须把 track 清空重来，
    /// 而清空后重建 track 需要「当初喂进去的那份 header / 脚本」。
    /// 这两份数据都很小（几 KB 的样式表 / 一份字幕文件），留着比
    /// 「每次 seek 都让上层重新传一遍」简单得多，也不会传错。
    private var storedCodecPrivate = Data()
    private var storedScript: String?

    private static let logPrefix = "[AssSubtitleRenderer] "

    // MARK: - 构造（签名照抄符号表）

    /// 内封字幕：`codecPrivate` 是容器给的 extradata，含 `[Script Info]` 与样式表。
    init(codecPrivate: Data,
         fontDirectories: [URL] = [],
         embeddedFonts: [SubtitleEmbeddedFont] = []) {
        self.isExternalScript = false
        bootstrap(fontDirectories: fontDirectories, embeddedFonts: embeddedFonts)
        installCodecPrivate(codecPrivate)
    }

    /// 外挂字幕：`script` 是整份 ASS 文本。
    init(script: String,
         fontDirectories: [URL] = [],
         embeddedFonts: [SubtitleEmbeddedFont] = []) {
        self.isExternalScript = true
        bootstrap(fontDirectories: fontDirectories, embeddedFonts: embeddedFonts)
        installScript(script)
    }

    deinit {
        // 顺序不能反：track 先于 renderer，renderer 先于 library。
        lock.lock()
        if let t = track { ass_free_track(t); track = nil }
        if let r = renderer { ass_renderer_done(r); renderer = nil }
        if let l = library { ass_library_done(l); library = nil }
        lock.unlock()
    }

    var isAvailable: Bool { renderer != nil && library != nil }

    // MARK: - 建立

    /// library → 字体 → renderer。顺序不能换：字体注册在 library 层，
    /// 必须发生在 `ass_renderer_init`（它建字体缓存）之前。
    private func bootstrap(fontDirectories: [URL], embeddedFonts: [SubtitleEmbeddedFont]) {
        library = ass_library_init()
        guard let lib = library else {
            Self.log("ass_library_init 失败 —— 字幕渲染不可用")
            return
        }

        installFonts(fontDirectories: fontDirectories, embeddedFonts: embeddedFonts)

        renderer = ass_renderer_init(lib)
        guard let r = renderer else {
            Self.log("ass_renderer_init 失败")
            ass_library_done(lib)
            library = nil
            return
        }

        // `ASS_FONTPROVIDER_AUTODETECT` 在 macOS 上落到 **CoreText** provider。
        // 已实测：libass 自己会打印 `Using font provider coretext`。
        // 这也是为什么不需要 fontconfig —— bundle 里虽然有 libfontconfig.1.dylib，
        // 但 libass 没链它（`otool -L` 可验证），那是别的库拖进来的。
        //
        // update = 1：立刻扫一遍系统字体建索引，而不是等第一次渲染才扫，
        // 否则第一句字幕会额外卡几十毫秒。
        ass_set_fonts(r, nil, "sans-serif",
                      Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue), nil, 1)
    }

    /// 字体安装。`init` 里会调一次；也可以在换字体后自行再调
    /// （重复注册同一个字体无害，只是多占一点内存）。
    func installFonts(fontDirectories: [URL], embeddedFonts: [SubtitleEmbeddedFont]) {
        guard let lib = library else { return }

        // libass 的 `ass_set_fonts_dir` 只接受**一个**目录（不是列表）。
        // 原版签名收的是数组，这里取第一个真实存在的 —— 为不存在的路径建索引
        // 只会拖慢启动，没有收益。
        if let dir = fontDirectories.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            ass_set_fonts_dir(lib, dir.path)
        }

        // 让 libass 把 track 里内嵌的字体提取出来（外挂 ASS 可以自带字体）。
        ass_set_extract_fonts(lib, 1)

        for font in embeddedFonts where !font.isEmpty {
            addFont(name: font.name, data: font.data)
        }
    }

    /// 把一份字体交给 libass。必须在上面的 `init` 流程里（renderer 建好之前）调用。
    private func addFont(name: String, data: Data) {
        guard let lib = library, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
            name.withCString { cname in
                ass_add_font(lib, cname, base, Int32(data.count))
            }
        }
    }

    /// 内封：新建空 track，先喂 header。
    private func installCodecPrivate(_ codecPrivate: Data) {
        guard let lib = library else { return }
        storedCodecPrivate = codecPrivate
        guard let t = ass_new_track(lib) else {
            Self.log("ass_new_track 失败")
            return
        }
        track = t
        needsRecompose = true

        guard !codecPrivate.isEmpty else {
            Self.log("这条字幕轨没有 codec_private —— 只能用默认样式渲染")
            return
        }
        // codec_private 就是这份 ASS 的「文件头 + 样式表」。
        // 不喂它，字幕会用 libass 的默认字体/字号/描边/位置渲染，与片方意图无关。
        codecPrivate.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
            ass_process_codec_private(t, base, Int32(codecPrivate.count))
        }
        Self.log("内封 track 已建立（codec_private \(codecPrivate.count) 字节）")
    }

    /// 外挂：整份脚本交给 `ass_read_memory`。它建出的 track 自带全部事件与样式，
    /// 之后不再需要 processASSChunk。
    private func installScript(_ script: String) {
        guard let lib = library else { return }
        storedScript = script
        guard !script.isEmpty else { return }

        var bytes = Array(script.utf8).map { CChar(bitPattern: $0) }
        bytes.append(0)   // ass_read_memory 会就地改这块内存，且按 C 字符串找结尾

        let newTrack: UnsafeMutablePointer<ass_track>? = bytes.withUnsafeMutableBufferPointer { p in
            ass_read_memory(lib, p.baseAddress, script.utf8.count, nil)
        }
        guard let t = newTrack else {
            Self.log("ass_read_memory 失败 —— 外挂脚本不是合法的 ASS/SSA")
            return
        }
        track = t
        eventCount = Int(t.pointee.n_events)
        needsRecompose = true
        Self.log("外挂 track 已建立（脚本 \(script.utf8.count) 字节，\(eventCount) 条事件）")
    }

    // MARK: - 喂事件

    /// 把 track 清回「刚建好、一条事件都没有」的状态。
    ///
    /// ┌ 为什么 seek 非做这一步不可（**实测结论，不是推理**）
    /// │
    /// │ 本工程用的 MKV 只有第 0 帧标了 key，`av_seek_frame` 跳不过去，
    /// │ 只能回到文件开头 —— 真正的「跳到 5s」是靠**从头重读、把 5s 之前的丢掉**
    /// │ 完成的（ffmpeg CLI 的 `-ss` 也是这个套路，`applySeek` 里已记着）。
    /// │ 于是 0–5s 的字幕包会被**再投递一次**。
    /// │
    /// │ 视频那边有 `minValidPTS` 把过期帧丢在解码之后，字幕没有对应的机制：
    /// │ libass 的 track 是**只增不减**的事件列表，同一条事件进两次就是两条。
    /// │ 画面上表现为描边变粗、半透明字叠深 —— 而且每 seek 一次就厚一分。
    /// │ 实测：不加这一步时，一次 seek 让「事件 3 条」变成「事件 6 条」。
    /// └
    ///
    /// ┌ 为什么是「重建 track」而不是「清事件」
    /// │
    /// │ libass 没有公开的「清空事件」API —— 原版用到的 16 个符号里没有
    /// │ `ass_flush_events`，只有 `ass_new_track` / `ass_free_track`。
    /// │ 也就是说**原版就是靠重建 track 来做这件事的**：free 掉再 new 一个，
    /// │ 重新喂 header。renderer 与字体缓存都留着（那才是贵的那部分）。
    /// └
    ///
    /// - Note: 重建后事件是空的，必须等解封装线程从新位置重读一遍才会有内容。
    ///         这正是 `applySeek` 里「先重建、再重读」的顺序。
    /// - Note: **不过滤** target 之前的事件（虽然那样能省内存）。
    ///         一条 10s 开始、30s 结束的字幕在 seek 到 20s 时**仍然该显示**，
    ///         而 `duration` 为 0（容器没给）时无法判断——过滤会把该显示的滤掉。
    ///         事件总量本就有界（一部长片几千条），不值得为它引入一个正确性风险。
    func resetTrack() {
        lock.lock(); defer { lock.unlock() }
        guard library != nil else { return }
        if let t = track { ass_free_track(t); track = nil }
        eventCount = 0
        lastEventText = ""
        lastImageCount = 0
        needsRecompose = true

        if isExternalScript {
            // 外挂脚本自带全部事件，重建一遍与原来完全等价（不是「重读」）。
            if let s = storedScript { installScript(s) }
        } else {
            installCodecPrivate(storedCodecPrivate)
        }
    }

    /// 喂一条 ASS 事件行（内封字幕每个包走一次）。
    ///
    /// `data` 是一行完整的事件文本，形如
    /// `Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,文本`。
    /// 时间单位是**毫秒**（符号表里的参数名 startMs / durationMs 已经说明了）。
    func processASSChunk(data: Data, startMs: Int64, durationMs: Int64) {
        guard !data.isEmpty else { return }

        lock.lock(); defer { lock.unlock() }
        guard let t = track, !isExternalScript else { return }

        var bytes = data.map { CChar(bitPattern: $0) }
        let count = bytes.count
        bytes.append(0)

        bytes.withUnsafeMutableBufferPointer { p in
            guard let base = p.baseAddress else { return }
            ass_process_chunk(t, base, Int32(count), startMs, durationMs)
        }
        eventCount += 1

        if let text = String(data: data, encoding: .utf8) {
            lastEventText = text.count > 80 ? String(text.prefix(80)) + "…" : text
        }
    }

    // MARK: - 渲染

    /// 渲染 `at` 这一时刻的字幕。
    ///
    /// - Returns: 需要更新画面时返回新位图；**返回 nil 表示「与上一帧完全一样，
    ///   继续用你手里那张纹理」**。这是绝大多数帧的情况，也是这个返回值可空的理由：
    ///   60Hz 里真正需要重传纹理的只有字幕变化的那几帧。
    func render(at time: Double, width: Int, height: Int) -> SubtitleBitmap? {
        guard width > 0, height > 0 else { return nil }

        lock.lock(); defer { lock.unlock() }

        guard let r = renderer, let t = track else {
            // 没有可用 track（libass 挂了 / 没字幕）：上一帧若画过东西，
            // 得给一张透明的把它擦掉；否则什么都不用做。
            guard needsRecompose || lastImageCount > 0 else { return nil }
            needsRecompose = false
            lastImageCount = 0
            return SubtitleBitmap.transparent(width: width, height: height)
        }

        if width != frameWidth || height != frameHeight {
            ass_set_frame_size(r, Int32(width), Int32(height))
            frameWidth = width
            frameHeight = height
            needsRecompose = true
        }

        var change: Int32 = 0
        let head = ass_render_frame(r, t, Int64((time * 1000).rounded()), &change)

        // libass 说画面没变、尺寸也没变 → 不必重做合成，更不必重传纹理。
        if change == 0 && !needsRecompose { return nil }
        needsRecompose = false

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let count = Self.composite(head, into: &pixels, width: width, height: height)
        lastImageCount = count
        return SubtitleBitmap(width: width, height: height,
                              pixels: pixels, imageCount: count)
    }

    /// 强制重做一次合成，把「此刻的字幕层」原样交出来。
    ///
    /// 与 `render` 的唯一区别：它**无视** libass 的 change 标志。
    ///
    /// 为什么需要：`render` 的正常语义是「没变就返回 nil，你继续用手里的纹理」——
    /// 这正是渲染循环想要的。但验收要问的是「**此刻**画面上是哪一句字幕」，
    /// 而验收跑到时这一帧往往已经被渲染循环消费过了（change 已归零），
    /// 于是 `render` 返回 nil，拿不到任何像素证据。
    ///
    /// - Note: 它会置上 `needsRecompose`，在渲染循环里表现为「额外多传一次纹理」，
    ///   内容完全一致，所以是安全的 —— 只是别每帧都调。
    /// - Note: 置标志与渲染分两次拿锁（`render` 自己会再拿一次）。理论上中间可能
    ///   被渲染线程插进来把这个标志消费掉 —— 那只是让本次快照退化成普通 render。
    ///   这是 dev 观测路径，不值得为它引一层可重入锁。
    func snapshot(at time: Double, width: Int, height: Int) -> SubtitleBitmap? {
        lock.lock(); needsRecompose = true; lock.unlock()
        return render(at: time, width: width, height: height)
    }

    /// ASS_Image 链表 → 预乘 alpha 的 BGRA8。
    ///
    /// 三条**实测**得来的注意事项，都在这个函数里：
    ///   1. 跨行必须用 `stride` 而不是 `w` —— 实测 w=302 时 stride=304，
    ///      官方注释也明说「最后一行可能没有 padding 到 stride」，
    ///      所以只能逐行读 w 个字节。
    ///   2. 颜色编码是 `R=c>>24, G=c>>16, B=c>>8, A=255-(c&0xFF)`（alpha 取反的写法）。
    ///      实测：纯红字幕解出 `color=0xFF000000` → R=255 ✓
    ///   3. 链表顺序就是绘制顺序，**不能重排**（阴影要垫在描边下面，描边再垫正文下面）。
    private static func composite(_ head: UnsafeMutablePointer<ASS_Image>?,
                                  into pixels: inout [UInt8],
                                  width: Int, height: Int) -> Int {
        var node = head
        var drawn = 0

        while let n = node {
            let img = n.pointee
            node = img.next

            let iw = Int(img.w), ih = Int(img.h)
            guard iw > 0, ih > 0, let bm = img.bitmap else { continue }

            let stride = Int(img.stride)
            let r = Int((img.color >> 24) & 0xFF)
            let g = Int((img.color >> 16) & 0xFF)
            let b = Int((img.color >> 8) & 0xFF)
            let colorAlpha = 255 - Int(img.color & 0xFF)
            guard colorAlpha > 0 else { continue }

            let baseX = Int(img.dst_x)
            let baseY = Int(img.dst_y)
            drawn += 1

            for y in 0..<ih {
                let py = baseY + y
                guard py >= 0, py < height else { continue }
                let srcRow = y * stride          // ← 用 stride，不是 iw
                let dstRow = py * width * 4
                for x in 0..<iw {
                    let cov = Int(bm[srcRow + x])
                    if cov == 0 { continue }
                    let px = baseX + x
                    guard px >= 0, px < width else { continue }

                    let a = cov * colorAlpha / 255
                    if a == 0 { continue }
                    let inv = 255 - a
                    let idx = dstRow + px * 4
                    pixels[idx]     = UInt8((b * a + Int(pixels[idx])     * inv) / 255)
                    pixels[idx + 1] = UInt8((g * a + Int(pixels[idx + 1]) * inv) / 255)
                    pixels[idx + 2] = UInt8((r * a + Int(pixels[idx + 2]) * inv) / 255)
                    let dstA = Int(pixels[idx + 3])
                    pixels[idx + 3] = UInt8(a + dstA * inv / 255)
                }
            }
        }
        return drawn
    }

    // MARK: - dev 观测

    /// 一句话描述当前状态，给 `MP_DUMP_STATS` 用。
    func debugSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        guard isAvailable else { return "libass 不可用" }
        guard track != nil else { return "无字幕轨" }
        let kind = isExternalScript ? "外挂" : "内封"
        return "\(kind) · 事件 \(eventCount) 条 · 本帧 \(lastImageCount) 张图"
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((logPrefix + message + "\n").utf8))
    }
}
