//  MediaFileSource.swift
//  MetalPlayer 重建工程 —— Phase 1 解封装层
//
//  职责：打开文件、挑出最佳视频/音频流、按顺序读出 AVPacket、按需 seek。
//
//  线程约定：**只允许解封装线程调用**。内部无锁 —— 这是刻意的，
//  因为 seek 需要「先让解码线程静止，再动 AVFormatContext」，
//  跨线程加锁反而会把死锁面扩大。串行化由 PlaybackEngine 负责。
//
//  与重建出的同名的东西的关系：
//    MetalPlayer/FFmpeg/FFmpegPacketReader.swift 是**符号表骨架**（空函数体）；
//    这里是它的真实实现，放在 Playback/ 下以免被 generate.py 覆盖。

#if USE_FFMPEG

import Foundation
import CoreMedia
import CFFmpeg

final class MediaFileSource {

    // MARK: - 观测到的媒体信息

    let url: URL
    private(set) var formatName = "?"
    private(set) var duration: Double = 0

    private(set) var videoStreamIndex = -1
    private(set) var audioStreamIndex = -1
    private(set) var subtitleStreamIndex = -1

    private(set) var videoTimeBase = AVRational(num: 1, den: 1000)
    private(set) var audioTimeBase = AVRational(num: 1, den: 1000)

    private(set) var videoWidth = 0
    private(set) var videoHeight = 0
    private(set) var videoFrameRate: Double = 25

    private(set) var audioSampleRate = 0
    private(set) var audioChannels = 0

    /// 容器是否**只给了解码序时间戳**（缺呈现序补偿）。
    ///
    /// 命中时 `VideoDecoder` 会丢掉容器 pts，改用「输出序号 × 帧时长」重建时间轴。
    ///
    /// 真凶现场（The.Parent.Trap.1998.1080p.BluRay.x265-RARBG.mp4）：
    /// MP4 的 stbl 里**没有 ctts 盒子**，于是每个样点的 pts 就等于 dts = 解码序。
    /// libavcodec 吐出来的是显示序（POC 序），但这些帧身上贴的是解码序时间戳 ——
    /// 同一 GOP 内时间戳会前后乱跳（实测 0.042 → 0.083 → 0.000 → 0.125 → 0.250 → 0.292 → 0.209）。
    /// 任何按这些时间戳排队/丢帧的逻辑都会把画面在一段里反复倒着放。
    private(set) var videoTimestampsAreDecodeOrder = false

    /// 是否为 MTS / M2TS 摄像机格式或流层标记为隔行扫描 (Interlaced 50i/60i)
    var isMTSOrInterlacedHint: Bool {
        let ext = url.pathExtension.lowercased()
        if ext == "mts" || ext == "m2ts" || ext == "ts" {
            return true
        }
        if formatName.lowercased().contains("mpegts") {
            return true
        }
        if let st = stream(videoStreamIndex) {
            let fo = st.pointee.codecpar.pointee.field_order
            if fo != AV_FIELD_PROGRESSIVE && fo != AV_FIELD_UNKNOWN {
                return true
            }
        }
        return false
    }

    // MARK: - 内部

    private var ctx: UnsafeMutablePointer<AVFormatContext>?
    /// 复用的读包容器：避免每帧 alloc/free。消费者负责 unref。
    private var readPacket: UnsafeMutablePointer<AVPacket>?

    var hasVideo: Bool { videoStreamIndex >= 0 }
    var hasAudio: Bool { audioStreamIndex >= 0 }

    // MARK: - 打开

    init(url: URL) throws {
        FFmpegSupport.ensureReady()
        self.url = url

        var fmt: UnsafeMutablePointer<AVFormatContext>?
        let rc = url.path.withCString { avformat_open_input(&fmt, $0, nil, nil) }
        guard rc >= 0, let opened = fmt else {
            throw FFmpegFailure(stage: "avformat_open_input", code: rc)
        }
        ctx = opened

        let infoRC = avformat_find_stream_info(opened, nil)
        guard infoRC >= 0 else {
            var p: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&p)
            throw FFmpegFailure(stage: "avformat_find_stream_info", code: infoRC)
        }

        formatName = opened.pointee.iformat.flatMap { String(cString: $0.pointee.name) } ?? "?"
        if opened.pointee.duration != Int64.min, opened.pointee.duration > 0 {
            duration = Double(opened.pointee.duration) / Double(AV_TIME_BASE)
        }

        // av_find_best_stream 会顺手把 decoder 也挑好；这里只要流号。
        videoStreamIndex = Int(av_find_best_stream(opened, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        audioStreamIndex = Int(av_find_best_stream(opened, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0))
        subtitleStreamIndex = Int(av_find_best_stream(opened, AVMEDIA_TYPE_SUBTITLE, -1, -1, nil, 0))
        if videoStreamIndex < 0 { videoStreamIndex = -1 }
        if audioStreamIndex < 0 { audioStreamIndex = -1 }
        if subtitleStreamIndex < 0 { subtitleStreamIndex = -1 }

        guard hasVideo || hasAudio else {
            var p: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&p)
            throw SourceError.noPlayableStream
        }

        if let st = stream(videoStreamIndex) {
            videoTimeBase = st.pointee.time_base
            videoWidth = Int(st.pointee.codecpar.pointee.width)
            videoHeight = Int(st.pointee.codecpar.pointee.height)
            let fps = av_q2d(st.pointee.avg_frame_rate)
            videoFrameRate = (fps > 0.1 && fps < 1000) ? fps : 25
        }
        if let st = stream(audioStreamIndex) {
            audioTimeBase = st.pointee.time_base
            audioSampleRate = Int(st.pointee.codecpar.pointee.sample_rate)
            audioChannels = Int(st.pointee.codecpar.pointee.ch_layout.nb_channels)
        }
        // 有些容器不给 duration，用流里的兜底
        if duration <= 0, let st = stream(videoStreamIndex), st.pointee.duration != Int64.min {
            duration = FFmpegSupport.seconds(st.pointee.duration, st.pointee.time_base)
        }

        // 关键的一次性探测：这个片源的样点时间戳到底是不是呈现序。
        // 只在「编码层声明了 B 帧延迟」时才有意义 —— 没有 B 帧时解码序 == 显示序，
        // pts == dts 是正常的，不该误判。
        if let st = stream(videoStreamIndex) {
            videoTimestampsAreDecodeOrder = Self.probeDecodeOrderTimestamps(
                url: url,
                hasDecoderDelay: st.pointee.codecpar.pointee.video_delay > 0)
            if videoTimestampsAreDecodeOrder {
                FileHandle.standardError.write(Data(
                    "[MediaFileSource] 容器缺少呈现序时间戳（pts==dts，无 ctts/重排偏移）→ 视频时间轴改由解码输出序号重建\n".utf8))
            }
        }

        readPacket = av_packet_alloc()
        if readPacket == nil {
            var p: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&p)
            throw SourceError.outOfMemory
        }
    }

    deinit { close() }

    func close() {
        av_packet_free(&readPacket)
        readPacket = nil
        if ctx != nil { avformat_close_input(&ctx) }
        ctx = nil
    }

    /// 探测容器里的视频样点时间戳是不是只有解码序。
    ///
    /// 做法：另开一个**只读**上下文扫前 240 个视频包，看有没有任何一个包 pts != dts。
    /// 为什么不就地在主上下文里扫：`av_read_frame` 会把解封装位置推走，还得再 seek 回 0；
    /// 一旦那个 seek 失败（部分容器 start_time 不为 0），起播就会直接从几秒之后开始。
    /// 另开上下文多花一次 moov 解析（~10ms），换的是绝对安全。
    private static func probeDecodeOrderTimestamps(url: URL, hasDecoderDelay: Bool) -> Bool {
        // 没有 B 帧 → 解码序恒等于显示序，pts == dts 是正常现象，不判。
        guard hasDecoderDelay else { return false }

        var fmt: UnsafeMutablePointer<AVFormatContext>?
        let openRC = url.path.withCString { avformat_open_input(&fmt, $0, nil, nil) }
        guard openRC >= 0, let c = fmt else { return false }
        defer {
            var p: UnsafeMutablePointer<AVFormatContext>? = c
            avformat_close_input(&p)
        }
        guard avformat_find_stream_info(c, nil) >= 0 else { return false }
        let index = Int(av_find_best_stream(c, AVMEDIA_TYPE_VIDEO, -1, -1, nil, 0))
        guard index >= 0, index < Int(c.pointee.nb_streams) else { return false }

        var pkt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
        guard pkt != nil else { return false }
        defer { if pkt != nil { av_packet_free(&pkt) } }

        var videoPackets = 0
        var sawPresentationOrder = false
        let limit = 240
        while videoPackets < limit, !sawPresentationOrder {
            guard av_read_frame(c, pkt) >= 0 else { break }
            if pkt!.pointee.stream_index == Int32(index) {
                videoPackets += 1
                let pts = pkt!.pointee.pts
                let dts = pkt!.pointee.dts
                if pts != Int64.min, dts != Int64.min, pts != dts {
                    sawPresentationOrder = true
                }
            }
            av_packet_unref(pkt)
        }
        // 包太少不足以判断时按「可信」处理：宁可不修，也不能误改正常片源的时间轴。
        guard videoPackets >= 8 else { return false }
        return !sawPresentationOrder
    }

    enum SourceError: LocalizedError {
        case noPlayableStream
        case outOfMemory
        var errorDescription: String? {
            switch self {
            case .noPlayableStream: return "文件里没有可播放的音视频流"
            case .outOfMemory:      return "FFmpeg 分配 AVPacket 失败"
            }
        }
    }

    // MARK: - 流访问

    private func stream(_ index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, let c = ctx, index < Int(c.pointee.nb_streams) else { return nil }
        return c.pointee.streams[index]
    }

    func codecParameters(at index: Int) -> UnsafeMutablePointer<AVCodecParameters>? {
        stream(index)?.pointee.codecpar
    }

    // MARK: - 音轨切换（Phase 3.5）

    /// 切音轨。传 -1 表示关闭声音。
    ///
    /// 线程约定与 `readNextPacket` 相同：**只允许解封装线程调用**。
    @discardableResult
    func setAudioStream(_ index: Int) -> Bool {
        guard let c = ctx else {
            audioStreamIndex = -1
            return false
        }
        if index < 0 || index >= Int(c.pointee.nb_streams) {
            audioStreamIndex = -1
            return false
        }
        guard let st = stream(index), let par = st.pointee.codecpar,
              par.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
            audioStreamIndex = -1
            return false
        }
        audioStreamIndex = index
        audioTimeBase = st.pointee.time_base
        audioSampleRate = Int(par.pointee.sample_rate)
        audioChannels = Int(par.pointee.ch_layout.nb_channels)
        return true
    }

    // MARK: - 字幕流（Phase 3）

    /// 当前字幕流的时间基。没有字幕流时给一个 1/1000 的兜底 ——
    /// 调用方就不必到处判空了（读到的也都是 0，不会算出离谱的时间）。
    var subtitleTimeBase: AVRational {
        stream(subtitleStreamIndex)?.pointee.time_base ?? AVRational(num: 1, den: 1000)
    }

    /// 切字幕流。传 -1 表示不使用字幕。
    ///
    /// 线程约定与 `readNextPacket` 相同：**只允许解封装线程调用**。
    /// 这不是形式上的要求 —— `readNextPacket` 的分流条件里就带着这个索引，
    /// 两个操作必须串行，否则会出现「读包线程拿着旧索引、切轨线程刚改过它」的窗口。
    func setSubtitleStream(_ index: Int) {
        guard let c = ctx else { subtitleStreamIndex = -1; return }
        subtitleStreamIndex = (index >= 0 && index < Int(c.pointee.nb_streams)) ? index : -1
    }

    /// 收集容器里的字体附件。
    ///
    /// Matroska 允许把 ttf/otf 当作**附件流**塞进容器（`AVMEDIA_TYPE_ATTACHMENT`），
    /// 文件名在 `metadata["filename"]`，字节在 `codecpar->extradata`。
    /// 字幕组做内封 ASS 时这是标配 —— 不然用户机器上缺字体，断行与字形全变。
    ///
    /// 与 `enumerateTracks()` 同一套约定：只允许解封装线程调用。
    func embeddedFonts() -> [SubtitleEmbeddedFont] {
        guard let c = ctx else { return [] }
        var out: [SubtitleEmbeddedFont] = []

        for i in 0..<Int(c.pointee.nb_streams) {
            guard let st = stream(i), let par = st.pointee.codecpar,
                  par.pointee.codec_type == AVMEDIA_TYPE_ATTACHMENT else { continue }
            guard let p = par.pointee.extradata, par.pointee.extradata_size > 0 else { continue }

            let name = metadata(st, "filename")
            // 附件流里也可能有别的种类（图片、章节文件）。只收字体 ——
            // 把非字体喂给 ass_add_font 只会让 libass 白解析一遍。
            let lower = name.lowercased()
            guard lower.hasSuffix(".ttf") || lower.hasSuffix(".otf")
               || lower.hasSuffix(".ttc") else { continue }

            out.append(SubtitleEmbeddedFont(
                name: name,
                data: Data(bytes: p, count: Int(par.pointee.extradata_size))))
        }
        return out
    }

    /// 视频流的 SAUCE（分辨率/编码）摘要，给 UI 状态栏用。
    func videoSummary() -> String {
        guard let par = codecParameters(at: videoStreamIndex) else { return "无视频流" }
        return "\(FFmpegSupport.codecName(par.pointee.codec_id)) "
             + "\(par.pointee.width)x\(par.pointee.height) "
             + String(format: "@%.3f fps", videoFrameRate)
    }

    func audioSummary() -> String {
        guard let par = codecParameters(at: audioStreamIndex) else { return "无音频流" }
        return "\(FFmpegSupport.codecName(par.pointee.codec_id)) "
             + "\(par.pointee.sample_rate) Hz / \(par.pointee.ch_layout.nb_channels) ch"
    }

    // MARK: - 轨道枚举（Phase 2）

    /// `AV_DISPOSITION_DEFAULT`。
    ///
    /// 这是个 C 宏（`#define AV_DISPOSITION_DEFAULT 0x0001`），Swift 里**不是常量** ——
    /// 与本工程踩过的 `AVERROR_EOF` 是同一类问题（见 REBUILD-PLAN.md 的 Phase 1 踩坑 4）。
    /// 所以这里显式写值，并把出处钉住。
    private static let dispositionDefault: Int32 = 0x0001

    /// 列出容器里的全部轨道，供菜单动态构造。
    ///
    /// 为什么 Phase 1 没这个东西：那时只关心「挑一条最好的」，所以
    /// `av_find_best_stream` 拿到单条索引就够了（见 `init`）。
    /// 但菜单要**列出全部**用户才能切轨，所以得遍历 `nb_streams` 逐流读信息。
    ///
    /// 语言与标题来自容器元数据，用 `av_dict_get` 取 —— 这也是原版用到的 API
    /// （`av_dict_get` 在 `RECON-REPORT.md` 第 3 节的 66 个调用点清单里）。
    func enumerateTracks() -> [TrackInfo] {
        guard let c = ctx else { return [] }
        var out: [TrackInfo] = []

        for i in 0..<Int(c.pointee.nb_streams) {
            guard let st = stream(i), let par = st.pointee.codecpar else { continue }

            let kind: TrackInfo.Kind
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:    kind = .video
            case AVMEDIA_TYPE_AUDIO:    kind = .audio
            case AVMEDIA_TYPE_SUBTITLE: kind = .subtitle
            default:                    continue        // 数据流 / 附件流：菜单里没有位置
            }

            let codec = FFmpegSupport.codecName(par.pointee.codec_id)
            var info = TrackInfo(index: i,
                                 kind: kind,
                                 displayName: codec,
                                 codecName: codec,
                                 languageCode: metadata(st, "language"),
                                 title: metadata(st, "title"),
                                 channels: Int(par.pointee.ch_layout.nb_channels),
                                 sampleRate: Int(par.pointee.sample_rate),
                                 isDefault: (st.pointee.disposition & Self.dispositionDefault) != 0)
            // displayName 是观测到的既有字段：存一个不依赖界面的名字，
            // 菜单标题另外用 menuTitle 拼（那里会带上语言/声道/默认标记）。
            info.displayName = info.menuTitle
            out.append(info)
        }
        return out
    }

    /// 读一条流元数据。取不到返回空串（不返回 nil，调用方就不用到处判空）。
    private func metadata(_ st: UnsafeMutablePointer<AVStream>, _ key: String) -> String {
        guard let m = st.pointee.metadata else { return "" }
        guard let entry = key.withCString({ av_dict_get(m, $0, nil, 0) }) else { return "" }
        guard let value = entry.pointee.value else { return "" }
        return String(cString: value)
    }

    // MARK: - 详细参数快照（Phase 2 增补：Tab 监看面板用）

    /// 把容器的参数读成一个纯值类型快照。
    ///
    /// 与 `enumerateTracks()` 同一套约定：**只允许解封装线程调用一次**，
    /// 之后 UI 只读返回的快照。理由见两个文件头（越界读 `AVFormatContext` 会踩线程问题）。
    ///
    /// 读不到的值一律留空 —— 面板上宁可少一行，也不显示一个编出来的默认值。
    func detail() -> MediaDetail {
        var out = MediaDetail()
        guard let c = ctx else { return out }

        out.container.fileName = url.lastPathComponent
        out.container.formatName = formatName
        if let fmt = c.pointee.iformat, let long = fmt.pointee.long_name {
            out.container.formatLongName = String(cString: long)
        }
        out.container.duration = duration
        out.container.bitRate = c.pointee.bit_rate

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? NSNumber {
            out.container.fileSize = size.int64Value
        }

        var videoCount = 0, audioCount = 0, subtitleCount = 0
        for i in 0..<Int(c.pointee.nb_streams) {
            guard let st = stream(i), let par = st.pointee.codecpar else { continue }
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:    videoCount += 1
            case AVMEDIA_TYPE_AUDIO:    audioCount += 1
            case AVMEDIA_TYPE_SUBTITLE: subtitleCount += 1
            default:                    break
            }
        }
        out.container.streamCount = Int(c.pointee.nb_streams)
        out.container.videoCount = videoCount
        out.container.audioCount = audioCount
        out.container.subtitleCount = subtitleCount

        // ---- 视频流（取 av_find_best_stream 选中的那条）
        if let st = stream(videoStreamIndex), let par = st.pointee.codecpar {
            var v = VideoStreamDetail()
            v.codec = FFmpegSupport.codecName(par.pointee.codec_id)
            v.profile = profileName(par.pointee.codec_id, par.pointee.profile)
            v.level = par.pointee.level
            v.width = Int(par.pointee.width)
            v.height = Int(par.pointee.height)
            let fps = av_q2d(st.pointee.avg_frame_rate)
            v.frameRate = (fps > 0.1 && fps < 1000) ? fps : videoFrameRate
            v.pixelFormat = pixelFormatName(par.pointee.format)
            v.bitRate = par.pointee.bit_rate
            v.colorPrimaries = cString(av_color_primaries_name(par.pointee.color_primaries))
            v.colorTransfer = cString(av_color_transfer_name(par.pointee.color_trc))
            v.colorSpace = cString(av_color_space_name(par.pointee.color_space))
            v.colorRange = cString(av_color_range_name(par.pointee.color_range))
            out.video = v
        }

        // ---- 音频流
        if let st = stream(audioStreamIndex), let par = st.pointee.codecpar {
            var a = AudioStreamDetail()
            a.codec = FFmpegSupport.codecName(par.pointee.codec_id)
            a.profile = profileName(par.pointee.codec_id, par.pointee.profile)
            a.sampleFormat = sampleFormatName(par.pointee.format)
            a.channels = Int(par.pointee.ch_layout.nb_channels)
            a.sampleRate = Int(par.pointee.sample_rate)
            a.bitRate = par.pointee.bit_rate
            a.channelLayout = channelLayoutName(par.pointee.ch_layout)
            out.audio = a
        }

        return out
    }

    // MARK: 参数名翻译（FFmpeg 的 name 函数全部返回 `const char *`，可能为 NULL）

    private func cString(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        let s = String(cString: p)
        return (s == "unknown" || s == "none") ? "" : s
    }

    private func profileName(_ id: AVCodecID, _ profile: Int32) -> String {
        cString(avcodec_profile_name(id, profile))
    }

    private func pixelFormatName(_ raw: Int32) -> String {
        let name = cString(av_get_pix_fmt_name(AVPixelFormat(rawValue: raw)))
        return name.isEmpty ? "?" : name
    }

    private func sampleFormatName(_ raw: Int32) -> String {
        cString(av_get_sample_fmt_name(AVSampleFormat(rawValue: raw)))
    }

    /// 声道布局 → `stereo` / `5.1` 之类。
    ///
    /// `av_channel_layout_describe` 需要一个调用方给的缓冲；给 64 字节足够
    /// （FFmpeg 里最长的布局名远短于此）。
    private func channelLayoutName(_ layout: AVChannelLayout) -> String {
        var copy = layout
        var buf = [CChar](repeating: 0, count: 64)
        let rc = av_channel_layout_describe(&copy, &buf, buf.count)
        guard rc >= 0 else { return "" }
        let s = String(cString: buf)
        return s == "unknown" ? "" : s
    }

    // MARK: - 读包

    /// 读下一个包。
    /// - Returns: 包所属的流号；EOF 返回 nil；`packet` 保持有效直到下次调用或 unref。
    enum ReadResult {
        case packet(streamIndex: Int)
        case endOfFile
    }

    /// 读出下一个 AVPacket。调用方须在使用完后 `av_packet_unref`（或交给解码器消费）。
    func readNextPacket() -> (index: Int, packet: UnsafeMutablePointer<AVPacket>)? {
        guard let c = ctx, let pkt = readPacket else { return nil }
        while true {
            av_packet_unref(pkt)
            let rc = av_read_frame(c, pkt)
            if rc < 0 { return nil }                       // EOF / 错误：统一按结束处理
            if pkt.pointee.stream_index == Int32(videoStreamIndex) && videoStreamIndex >= 0 {
                return (videoStreamIndex, pkt)
            }
            if pkt.pointee.stream_index == Int32(audioStreamIndex) && audioStreamIndex >= 0 {
                return (audioStreamIndex, pkt)
            }
            // 字幕流：Phase 3 起不再丢弃 —— 交给解封装线程原地解码并喂给 libass。
            // 不入队列、不开线程：字幕包是低频的（几秒一个），处理也只是解析一行文本。
            if pkt.pointee.stream_index == Int32(subtitleStreamIndex) && subtitleStreamIndex >= 0 {
                return (subtitleStreamIndex, pkt)
            }
            // 其余（未选中的字幕轨 / 附件 / 数据流）：继续找下一个包
        }
    }

    // MARK: - Seek

    /// 最近一次 seek 的说明（策略 + 返回码），供引擎打日志。
    private(set) var lastSeekDescription = ""

    /// 跳到 `seconds`。
    ///
    /// 两种策略依次尝试——这不是过度设计，是实测逼出来的：
    /// `av_seek_frame(c, -1, ts, AVSEEK_FLAG_BACKWARD)` 在本工程的 MKV 上
    /// **返回 0（成功）但解封装器纹丝不动**（下个包 pts 仍是文件开头的 0）。
    /// 换成 `avformat_seek_file` 走 matroska 的 `read_seek2` 路径才真正跳过去。
    /// 保留旧调用作回落，以防某些容器只有 `read_seek`。
    ///
    /// - Returns: 生效那次调用的返回码（<0 表示两种策略都失败）。
    @discardableResult
    func seek(to seconds: Double) -> Int32 {
        guard let c = ctx else { lastSeekDescription = "无 context"; return -1 }
        let clamped = max(0, min(seconds, duration > 0 ? duration - 0.05 : seconds))
        let ts = Int64((clamped * Double(AV_TIME_BASE)).rounded())

        // 优先按视频流索引寻址（MKV/MP4 的关键帧 Cues 索引通常挂在视频流上）
        if videoStreamIndex >= 0, let st = stream(videoStreamIndex) {
            let streamTS = av_rescale_q(ts, AVRational(num: 1, den: AV_TIME_BASE), st.pointee.time_base)
            // 策略 1：针对视频流调用 avformat_seek_file，限制上界 max_ts = streamTS 绝不越界
            let rc1 = avformat_seek_file(c, Int32(videoStreamIndex), 0, streamTS, streamTS, 0)
            if rc1 >= 0 {
                if let pkt = readPacket { av_packet_unref(pkt) }
                lastSeekDescription = "avformat_seek_file(video) → \(rc1)"
                return rc1
            }

            // 策略 2：针对视频流调用 av_seek_frame 向后查找最近关键帧
            let rc2 = av_seek_frame(c, Int32(videoStreamIndex), streamTS, AVSEEK_FLAG_BACKWARD)
            if rc2 >= 0 {
                if let pkt = readPacket { av_packet_unref(pkt) }
                lastSeekDescription = "av_seek_frame(video) → \(rc2)"
                return rc2
            }
        }

        // 策略 3：全局回落 avformat_seek_file (-1)，限制上界 max_ts = ts
        let rc3 = avformat_seek_file(c, -1, 0, ts, ts, 0)
        if rc3 >= 0 {
            if let pkt = readPacket { av_packet_unref(pkt) }
            lastSeekDescription = "avformat_seek_file(-1) → \(rc3)"
            return rc3
        }

        // 策略 4：全局回落 av_seek_frame (-1)
        let rc4 = av_seek_frame(c, -1, ts, AVSEEK_FLAG_BACKWARD)
        if let pkt = readPacket { av_packet_unref(pkt) }
        lastSeekDescription = "av_seek_frame(-1) → \(rc4)"
        return rc4
    }
}

#endif
