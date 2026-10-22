//  SubtitleDecoder.swift
//  MetalPlayer 重建工程 —— Phase 3 字幕解码层
//
//  职责：把容器里的字幕包统一解成 **ASS 事件行**，交给 libass 渲染。
//
//  ┌ 为什么中间要过一道 libavcodec
//  │
//  │ 容器里字幕的编码五花八门（Matroska 里常见 ASS / SSA / SubRip / UTF-8 纯文本 /
//  │ PGS 图形字幕），而 libass 只认 ASS 方言。原版的做法就是过一道 libavcodec ——
//  │ 这不是我的推断，是**观测**：原版二进制 undefined 符号里有一组
//  │
//  │     _avcodec_alloc_context3 / _avcodec_parameters_to_context / _avcodec_open2
//  │     _avcodec_decode_subtitle2 / _avsubtitle_free
//  │
//  │ 与本文件一一对应。换句话说：这条路是原版走的路。
//  └
//
//  ┌ 两条分支（由 AVSubtitleRect.type 决定）
//  │
//  │   SUBTITLE_ASS    → rect.ass 已经是「Dialogue: …」整行，**原样透传**。
//  │                     内封 ASS/SSA 走这条，不需要任何转换。
//  │   SUBTITLE_TEXT   → 是纯文本（SubRip / MOV_TEXT 走这条），要手工拼一条
//  │                     Dialogue 行。拼法见 makeDialogueLine。
//  │   SUBTITLE_BITMAP → DVD / PGS 这类**图形**字幕，是已经画好的位图而不是文字。
//  │                     它跟 ASS 是两条完全不同的链路（libass 不参与），
//  │                     Phase 3 不做 —— 见 decode 末尾的说明。
//  └
//
//  线程约定：与 MediaFileSource 相同 —— **只允许解封装线程调用**。
//  内部的 AVCodecContext 只被这一个线程碰，所以不需要门闸（PipelineGate 是给
//  「同一 context 被两个线程碰」准备的，这里不存在那个情况）。

#if USE_FFMPEG

import Foundation
import CFFmpeg

/// 一条待喂给 libass 的字幕事件。
struct SubtitleEvent {
    /// 完整的一行（形如 `Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,文本`）。
    /// libass 的 `ass_process_chunk` 就吃这个。
    var line: String
    /// 事件开始时间（秒，按流时间基换算）。
    var start: Double
    /// 事件时长（秒）。<= 0 表示容器没给。
    var duration: Double
}

final class SubtitleDecoder {

    /// 容器里这条字幕流的私有数据（ASS 的 `[Script Info]` / `[V4+ Styles]`）。
    ///
    /// 它是**渲染效果的关键**：没有它，libass 只能拿默认样式渲染，
    /// 片方设定的字体 / 字号 / 描边 / 位置全丢。原版把它喂给了
    /// `ass_process_codec_private`（同样在观测到的调用面里）。
    private(set) var codecPrivate: [UInt8] = []

    /// 这条流的编码名（`ass` / `subrip` / `hdmv_pgs_subtitle`…），用于日志与界面。
    private(set) var codecName = ""

    let streamIndex: Int
    private let timeBase: AVRational

    private var ctx: UnsafeMutablePointer<AVCodecContext>?

    /// 解码出的事件里 `type` 是不是图形字幕（PGS / VobSub）。
    /// 给上层一句「这条轨是图形字幕，渲染不出来」的口实。
    private(set) var isBitmapSubtitle = false

    /// 这条轨**按编解码器本身**就是图形字幕（PGS / VobSub / DVB）。
    ///
    /// 与上面的 `isBitmapSubtitle` 的区别很关键：那个要**解码过至少一个包**
    /// 才会翻成 true，而建渲染器是在解第一个包之前发生的。上层的决策
    ///（「要不要给这条轨建 libass」）必须用这一个 —— 依据是 libavcodec 的
    /// codec descriptor 属性位 `AV_CODEC_PROP_BITMAP_SUB`，
    /// 不需要任何样本就能下结论。
    let isBitmapCodec: Bool

    // MARK: - 构造

    init(parameters: UnsafeMutablePointer<AVCodecParameters>,
         timeBase: AVRational,
         streamIndex: Int) throws {
        self.streamIndex = streamIndex
        self.timeBase = timeBase
        self.codecName = FFmpegSupport.codecName(parameters.pointee.codec_id)
        self.isBitmapCodec = Self.codecIsBitmap(parameters.pointee.codec_id)

        guard let codec = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw SubtitleError.noDecoder(codecName)
        }
        guard let c = avcodec_alloc_context3(codec) else {
            throw SubtitleError.outOfMemory
        }
        ctx = c

        // 单线程：字幕解码本来就是「一个包解出一行文本」，没有并行价值；
        // 而 libavcodec 的帧级线程会给 context 挂一层 async 锁状态机 ——
        // Phase 1 那条 `fctx->async_lock` 断言就是它带来的。能不开就不开。
        c.pointee.thread_count = 1

        try FFmpegSupport.check(avcodec_parameters_to_context(c, parameters),
                                "avcodec_parameters_to_context(字幕)")
        try FFmpegSupport.check(avcodec_open2(c, codec, nil), "avcodec_open2(字幕)")

        codecPrivate = Self.extradata(of: parameters)
    }

    deinit { close() }

    func close() {
        if ctx != nil { avcodec_free_context(&ctx) }
        ctx = nil
    }

    /// seek 之后调用：清掉解码器里可能残留的半条事件。
    func reset() {
        guard let c = ctx else { return }
        avcodec_flush_buffers(c)
    }

    // MARK: - 解码

    /// 解一个字幕包。
    ///
    /// - Note: 包只有解封装线程在碰，解完就要 `av_packet_unref` 的约定由调用方负责
    ///         （这里只读不写，与 `VideoDecoder.decode(packet:)` 一致）。
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [SubtitleEvent] {
        guard let c = ctx else { return [] }

        var sub = AVSubtitle()
        var got: Int32 = 0
        let rc = avcodec_decode_subtitle2(c, &sub, &got, packet)
        // 有些字幕解码器会在某些包上返回错误（例如 SubRip 的畸形时间码）。
        // 这种情况**不该打断整条播放**：字幕是装饰性的，丢一条就丢一条。
        guard rc >= 0, got != 0 else {
            if rc < 0 {
                Self.log("字幕包解码失败（忽略）: \(FFmpegSupport.errorText(rc))")
            }
            return []
        }
        defer { avsubtitle_free(&sub) }

        // 事件的绝对起点 = 包时间戳 + AVSubtitle 给的相对偏移。
        // start_display_time / end_display_time 的单位都是**毫秒**（见 avcodec.h 注释）。
        let packetPTS = Self.packetSeconds(packet, timeBase)
        let start = packetPTS + Double(sub.start_display_time) / 1000
        // 时长取「解码器给的」优先，**但内封 ASS 拿不到** —— 见 packetDurationSeconds
        // 的注释：FFmpeg 的 ssa 解码器这两个字段恒为 0，只能回落到包时长。
        let subDuration = Double(sub.end_display_time &- sub.start_display_time) / 1000
        let duration = subDuration > 0 ? subDuration
                                       : Self.packetDurationSeconds(packet, timeBase)

        guard let rects = sub.rects else { return [] }
        var out: [SubtitleEvent] = []
        out.reserveCapacity(Int(sub.num_rects))

        for i in 0..<Int(sub.num_rects) {
            guard let r = rects[i] else { continue }
            let rect = r.pointee

            switch rect.type {
            case SUBTITLE_ASS:
                // 已经是 ASS 事件行，原样透传 —— 一个字节都不要动。
                // 内封 ASS 的 `rect.ass` 是 libavcodec 从包里原样拿出来的，
                // 任何「整理」（trim / 改换行）都可能破坏 override tag。
                guard let p = rect.ass else { continue }
                out.append(SubtitleEvent(line: String(cString: p),
                                         start: start,
                                         duration: duration))

            case SUBTITLE_TEXT:
                // 纯文本（SubRip / MOV_TEXT）。拼成 ASS 事件行才能进 libass。
                guard let p = rect.text else { continue }
                out.append(SubtitleEvent(line: Self.makeDialogueLine(
                                            text: String(cString: p),
                                            start: start,
                                            duration: duration),
                                         start: start,
                                         duration: duration))

            case SUBTITLE_BITMAP:
                // 图形字幕（PGS / VobSub / DVB）。它的 rect 里是**画好的位图**
                // （data[0] 是 8 位调色板索引，data[1] 是 RGBA 调色板），
                // libass 完全不参与 —— 要么我们自己合成到画面，要么走 libavfilter。
                // 本工程没有 libavfilter（bundle 里就没有那个 dylib），
                // 所以 Phase 3 不做，只标记一下让界面能如实说明。
                isBitmapSubtitle = true

            default:
                continue
            }
        }
        return out
    }

    // MARK: - 工具

    /// 这个编解码器是不是**图形**字幕。
    ///
    /// 用 codec descriptor 的属性位而不是拿 `codecName` 跟字符串比：
    /// 名字会随 FFmpeg 版本变（`hdmv_pgs_subtitle` / `dvd_subtitle` /
    /// `dvb_subtitle` / `xsub` …），而属性位是 libavcodec 自己维护的分类，
    /// 覆盖全部图形字幕、且新加的也不会漏。
    private static func codecIsBitmap(_ id: AVCodecID) -> Bool {
        guard let desc = avcodec_descriptor_get(id) else { return false }
        return (desc.pointee.props & AV_CODEC_PROP_BITMAP_SUB) != 0
    }

    private static func extradata(of par: UnsafeMutablePointer<AVCodecParameters>) -> [UInt8] {
        guard let p = par.pointee.extradata, par.pointee.extradata_size > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: Int(par.pointee.extradata_size)))
    }

    private static func packetSeconds(_ pkt: UnsafeMutablePointer<AVPacket>,
                                      _ tb: AVRational) -> Double {
        let ts = pkt.pointee.pts != Int64.min ? pkt.pointee.pts : pkt.pointee.dts
        return FFmpegSupport.seconds(ts, tb)
    }

    /// 事件时长（秒），从**包**上取。
    ///
    /// 这个函数是 Phase 3 最值得记的一个坑，值得写清楚：
    ///
    /// 内封 ASS 的时长**唯一来源就是包时长**。FFmpeg 的 `ssa` 解码器（MKV 内封 ASS/SSA
    /// 走的就是它）只把事件正文塞进 `rect->ass`，`AVSubtitle` 的
    /// `start_display_time` / `end_display_time` **两个字段恒为 0**（实测确认）。
    /// 于是 `end - start = 0`，一条 `Duration=0` 的事件进 libass —— 而
    /// **libass 对零时长事件永远不渲染**。
    ///
    /// 失败的样子极具迷惑性：字幕轨接上了、`eventCount` 也在涨、libass 日志里
    /// `ass_process_chunk` 一切正常，但画面上一个字都没有，`ass_render_frame`
    /// 每次都说 `change=0`。看着像渲染层的问题，其实是时长没传进去。
    ///
    /// Matroska 的 ASS 块带 BlockDuration，实测 dur / 时间基 = 2.5s / 2.5s / 3.5s，
    /// 与脚本里 End − Start 完全对得上，所以这个回落不是「凑数」而是正解。
    ///
    /// - Note: 包时长按 **AVStream 的 time_base** 计（`av_read_frame` 解出来的包
    ///         就是这个约定），不是 codec context 的 timebase。
    private static func packetDurationSeconds(_ pkt: UnsafeMutablePointer<AVPacket>,
                                             _ tb: AVRational) -> Double {
        let d = pkt.pointee.duration
        guard d > 0 else { return 0 }
        return FFmpegSupport.seconds(d, tb)
    }

    /// 把一段纯文本拼成 ASS 事件行。
    ///
    /// 三处必须转义，少一处就会渲染错：
    ///   · 换行 → `\N`（ASS 的硬换行；直接留 `\n` 会被 libass 当成空白）
    ///   · `{` `}` → `\{` `\}`（否则里面的内容会被当成 override tag 吃掉）
    ///   · 反斜杠本身留在原样 —— ASS 里 `\` 只在 `{}` 内才是 tag，
    ///     正文里的 `\` 无害，反而是 `\\` 会被当成转义显示成 `\`。
    ///
    /// 时间格式是 `H:MM:SS.cc`（最后两位是**厘秒**，不是毫秒）。
    private static func makeDialogueLine(text: String, start: Double, duration: Double) -> String {
        let end = start + max(duration, 0.5)
        var body = text
        body = body.replacingOccurrences(of: "\r\n", with: "\n")
        body = body.replacingOccurrences(of: "\n", with: "\\N")
        body = body.replacingOccurrences(of: "{", with: "\\{")
        body = body.replacingOccurrences(of: "}", with: "\\}")
        return "Dialogue: 0,\(assTime(start)),\(assTime(end)),Default,,0,0,0,,\(body)"
    }

    /// ASS 时间戳 `H:MM:SS.cc`（厘秒）。
    ///
    /// 与 `SubtitleFormat.assTime` 同一套写法，理由也一样：先取整到厘秒再拆，
    /// 避免 `%05.2f` 把 59.999 进位成 `"60.00"` 产出畸形时间戳。
    static func assTime(_ seconds: Double) -> String {
        let totalCs = Int((max(0, seconds) * 100).rounded())
        let totalS = totalCs / 100
        return String(format: "%d:%02d:%02d.%02d",
                      totalS / 3600, (totalS / 60) % 60, totalS % 60, totalCs % 100)
    }

    enum SubtitleError: LocalizedError {
        case noDecoder(String)
        case outOfMemory

        var errorDescription: String? {
            switch self {
            case .noDecoder(let name): return "没有可用的字幕解码器：\(name)"
            case .outOfMemory:         return "FFmpeg 分配字幕解码器失败"
            }
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[SubtitleDecoder] \(message)\n".utf8))
    }
}

#endif
