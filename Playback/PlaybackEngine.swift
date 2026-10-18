//  PlaybackEngine.swift
//  MetalPlayer 重建工程 —— Phase 1 播放引擎主体
//
//  ┌─ 解封装线程 ── read packet ─┬─ 视频包队列(200) ── 视频解码线程 ── 帧队列(24) ── 渲染循环(主线程 vsync)
//  │                             └─ 音频包队列(600) ── 音频解码线程 ── 重采样 ── AVAudioPlayerNode
//  └─ 时钟：AVSyncClock（音频为主，墙钟回落）
//
//  三条并发规则，违反任何一条都会出难查的 bug：
//
//  1. **同一个 AVCodecContext，同一时刻只能有一个线程碰**。这不是洁癖：
//     FFmpeg 帧级线程内部有个 async 锁，`ff_thread_decode_frame()` 进入时释放、
//     返回前拿回；两个线程同时进去，第二个就会 `av_assert0` 直接中止进程：
//         Assertion fctx->async_lock failed at libavcodec/pthread_frame.c:178
//     靠 videoGate / audioGate 保证。视频与音频各自一把，解码仍然并行。
//     两者都会碰解码器的只有「流结束冲刷」和「seek」，都按门取→用→放。
//
//  2. **寻址（seek）是唯一需要「独占」的操作**。要动 AVFormatContext /
//     AVCodecContext / SwrContext，先 requestSeek()，由解封装线程执行
//     freezeAndWait() —— 冻住两把门、等在途任务退出，才动手。
//
//  3. **代际号（generation）作废陈旧数据**。seek 之后，此前已经从队列里取出的
//     包/帧都不再属于当前时间轴，靠代际号丢弃，而不是靠清空队列（清空有竞态窗口）。
//
//  关于 clock.scheduledAudioEnd / clock.hasAudio 这两个跨线程标量：
//  它们是 8 字节对齐的 Double/Bool，arm64 上对齐读写天然原子，刻意不加锁 ——
//  加锁会引入「时钟锁 → 锚点锁」的锁序反转（音频线程反向获取），得不偿失。

#if USE_FFMPEG

import Foundation
import CoreGraphics
import CoreVideo
import AVFoundation
import CFFmpeg

// MARK: - 状态

enum PlaybackState: Equatable {
    case idle
    case opening
    case playing
    case paused
    case ended
    case failed(String)

    var isActive: Bool { self == .playing }
}

protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngine(_ engine: PlaybackEngine, didChange state: PlaybackState)
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double, duration: Double)
}

// MARK: - 引擎

final class PlaybackEngine {

    weak var delegate: PlaybackEngineDelegate?

    // MARK: 对外只读信息

    private(set) var url: URL?
    private(set) var duration: Double = 0
    private(set) var videoSize: CGSize = .zero
    private(set) var sourceInfo: String = ""
    private(set) var isCaptureMode: Bool = false
    private var captureSession: AVCaptureSession?
    private var captureOutputDelegate: CaptureOutputDelegate?
    private var captureAudioPreviewOutput: AVCaptureAudioPreviewOutput?
    private var captureFPS: Double = 60.0
    /// 面板请求的帧时长 / 帧率，留到 `startRunning()` 之后再落地（见 openCapture）。
    private var pendingCaptureFrameDuration: CMTime?
    private var pendingCaptureFPS: Double = 60.0

    /// 采集卡**实测**投递帧率（由相邻样本的时间差算出）。
    ///
    /// 存在的理由：设备属性读回值可以是 60 而实际只出 20（驱动启动时重置），
    /// 只看配置值等于蒙眼开车。原版对应 `actualCaptureMismatch(threshold:)`
    /// 与 `logActualCaptureState(reason:)`。
    private var actualCaptureFPS: Double = 0
    private var captureSampleCount: Int = 0
    private var lastCaptureSampleHostTime: Double = 0
    private var captureRateWarned = false
    /// 本次采集解析出的色彩信息，供面板显示与日志落盘。
    private var captureColorDescription = "—"
    var hasVideo: Bool { videoDecoder != nil || isCaptureMode }
    var hasAudio: Bool { audioOutput != nil || captureAudioPreviewOutput != nil }

    /// Phase 2：打开文件时取下的轨道快照（见 `open(url:)`）。主线程只读。
    /// 是个值类型数组，不是对 `MediaFileSource` 的活引用 —— 理由见 open 里的注释。
    private(set) var tracks: [TrackInfo] = []

    /// Phase 2 增补：开文件与切轨时取下的**详细参数快照**（Tab 监看面板的上半部分）。
    /// 与 `tracks` 同一套约定 —— 只读值类型，主线程随便读。
    private var _detail = MediaDetail()
    var detail: MediaDetail {
        stateLock.lock(); defer { stateLock.unlock() }
        return _detail
    }

    var audioTracks: [TrackInfo] { tracks.filter { $0.kind == .audio } }
    var videoTracks: [TrackInfo] { tracks.filter { $0.kind == .video } }
    var subtitleTracks: [TrackInfo] { tracks.filter { $0.kind == .subtitle } }

    /// 当前音轨的**流索引**。Phase 1 由 `av_find_best_stream` 在开文件时选定，之后不变。
    var currentAudioStreamIndex: Int? {
        guard let s = source, s.audioStreamIndex >= 0 else { return nil }
        return s.audioStreamIndex
    }

    /// 当前内封字幕轨的流索引。Phase 1 只挑一条；Phase 3 起可切。
    ///
    /// 读的是**快照**而不是 `source.subtitleStreamIndex` —— 后者归解封装线程所有
    ///（切轨会改它），主线程直接读就是跨线程摸同一个变量。
    /// 这个区别在 Phase 1 不明显（那时索引开文件后再不变），切轨之后就是真的了。
    var currentSubtitleStreamIndex: Int? {
        let index = selectedSubtitleStreamIndex
        return index >= 0 ? index : nil
    }

    /// 选中的字幕流索引（-1 = 关闭）。菜单用它回显勾选状态。
    var selectedSubtitleStreamIndex: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _selectedSubtitleStreamIndex
    }

    /// 选中的音频流索引（-1 = 关闭）。菜单用它回显勾选状态。
    var selectedAudioStreamIndex: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _selectedAudioStreamIndex
    }

    var currentTime: Double { clock.currentTime() }

    var state: PlaybackState {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }

    var isPlaying: Bool { state == .playing }

    var volume: Float {
        get { audioOutput?.volume ?? captureAudioPreviewOutput?.volume ?? storedVolume }
        set {
            storedVolume = max(0, min(1, newValue))
            audioOutput?.volume = storedVolume
            captureAudioPreviewOutput?.volume = storedVolume
        }
    }

    // MARK: 内部状态

    private let stateLock = NSLock()
    private var _state: PlaybackState = .idle
    private var stopRequested = false
    private var seekRequested: Double?
    private var wantPlaying = false
    private var eofReached = false
    private var videoDrained = false
    private var audioDrained = false
    private var generation = 0
    private var minValidPTS: Double = 0

    private let anchorLock = NSLock()
    private var audioAnchorPTS: Double?
    private var audioBuffersScheduled = false

    private var storedVolume: Float = 1.0

    // MARK: 性能监看计数（Phase 2 增补）
    //
    // 只做单调递增的整数累加，不读时钟 —— FPS 由采样侧对时间求导（见 PlaybackStats.swift）。
    // 用一把独立的锁而不是复用 stateLock：这些计数器在三条线程上都会被写
    // （解码线程 +1、渲染线程 +1、主线程读），但它们和状态机没有不变式关系，
    // 分开锁可以避免把热路径塞进状态机的临界区。
    private let statsLock = NSLock()
    private var decodedVideoFrames = 0
    private var presentedFrames = 0
    private var droppedFrames = 0

    // MARK: 组件

    private var source: MediaFileSource?
    private var videoDecoder: VideoDecoder?
    private var audioDecoder: AudioDecoder?
    private var audioOutput: AudioOutput?

    // MARK: 字幕（Phase 3）
    //
    // 这里有两层线程关系，别混：
    //   · **libass 的那一层**（track / renderer 的内部状态）由 AssSubtitleRenderer
    //     自己的一把锁罩着 —— 解封装线程 feed、主线程 render，互斥在那边解决。
    //   · **这里这一层**只负责「替换引用」：切轨时解封装线程会把整个 renderer
    //     换成新实例，而主线程可能正在读那个属性。subtitleLock 就是为这一件事存在的，
    //     它**不会**被嵌套进 libass 那把锁（render 是拿到引用之后才调用的）。
    private let subtitleLock = NSLock()
    private var subtitleRendererStorage: AssSubtitleRenderer?

    /// 字幕解码器。只属于解封装线程（与 MediaFileSource 同一套约定）。
    private var subtitleDecoder: SubtitleDecoder?

    /// 待处理的字幕请求：主线程写、解封装线程读。由 stateLock 保护。
    private var subtitleRequest: SubtitleRequest?

    /// 当前选中的字幕流索引快照（-1 = 关闭）。给主线程读（菜单勾选状态）。
    private var _selectedSubtitleStreamIndex = -1

    /// 待处理的音轨请求：主线程写、解封装线程读。由 stateLock 保护。
    private var audioTrackRequest: Int?
    /// 当前选中的音频流索引快照（-1 = 关闭）。给主线程读（菜单勾选状态）。
    private var _selectedAudioStreamIndex = -1

    enum SubtitleRequest {
        /// 切到某条内封轨。-1 = 关闭字幕（关字幕也是一种选择）。
        case internalTrack(Int)
        /// 加载外挂字幕文件。
        case externalFile(URL)
    }

    private let clock = AVSyncClock()

    // MARK: 队列 / 线程

    private let videoPacketQueue = BoundedQueue<PacketItem>(capacity: 200)
    private let audioPacketQueue = BoundedQueue<PacketItem>(capacity: 600)
    private let frameQueue = BoundedQueue<DecodedVideoFrame>(capacity: 48)
    private let rifeEngine = RIFEInterpolationEngine()
    private let flavrEngine = FLAVRInterpolationEngine()
    /// 每个编解码上下文一把门闸：视频与音频独立，解码可以并行；
    /// 但同一把门闸保证「同一时刻只有一个线程在动这个 context」——
    /// FFmpeg 帧级线程的 async 锁不变式就靠它（详见 PipelinePrimitives.swift）。
    private let videoGate = PipelineGate()
    private let audioGate = PipelineGate()
    private let threadGroup = DispatchGroup()
    private let demuxQueue = DispatchQueue(label: "metalplayer.demux", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "metalplayer.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "metalplayer.audio", qos: .userInitiated)

    // MARK: 真·RIFE 异步推理管线（对齐原版 RIFE60 + MultiPairReorder 深流水线）
    //
    // 结构（四条线程，全部由 ensureRifePipeline 拉起、shutdownPipeline 关闭）：
    //   解码线程 → rifeInputQueue → 调度线程 rifeDispatchLoop
    //     · 把连续两帧组成帧对，计算插值时间戳（ticks），按 seq 提交；
    //     · 在途对数超软限 → 本对直通不插帧（protect interval）；
    //     · 超硬限 → 阻塞等待（背压传导回解码线程）。
    //   worker ×2（rifeWorkerLoop）：
    //     · 各自从自己的作业队列取帧对，调 CoreMLRIFEEngine.runPair 并行推理
    //       （每 worker 独立 Engine 实例；微基准 .all 双 worker 聚合 44 对/s）；
    //     · 结果（含作为首元素的 f0）按 seq 推入重排缓冲。
    //   出口线程 rifeEmitLoop：
    //     · 按序从重排缓冲取结果推入 frameQueue —— 乱序完成、按序上屏。
    private enum RifeItem {
        case frame(DecodedVideoFrame, generation: Int, fps: Double)
        case end(generation: Int)
    }
    private struct RifeJob {
        let seq: Int
        let generation: Int
        let workerIndex: Int
        let f0: DecodedVideoFrame
        let f1: DecodedVideoFrame
        let ticks: [CoreMLRIFEEngine.RifeTick]
        let fps: Double
        let settings: PlaybackSettings
    }
    private let rifeInputQueue = BoundedQueue<RifeItem>(capacity: 8)
    private var rifeJobQueues: [BoundedQueue<RifeJob>] = []
    private let rifeReorder = RifeReorderBuffer()
    private let rifeDispatchQueue = DispatchQueue(label: "metalplayer.rife60.dispatch", qos: .userInitiated)
    private let rifeEmitQueue = DispatchQueue(label: "metalplayer.rife60.emit", qos: .userInitiated)
    private let rifeWorkerQueues: [DispatchQueue] = [
        DispatchQueue(label: "metalplayer.rife60.worker0", qos: .userInitiated),
        DispatchQueue(label: "metalplayer.rife60.worker1", qos: .userInitiated),
    ]
    /// 线程组是否已拉起（stateLock 保护；shutdownPipeline 复位）
    private var rifeThreadsStarted = false
    /// 在途帧对硬上限（超过则调度线程阻塞 —— 背压传导回解码）
    /// 旧值 6。实测 2x@30fps 下 GPU 争用（2 worker + 1 渲染）会让在途短暂冲到 3，
    /// 原软限 3 于是频繁误触发 protect-interval，把本可补的帧永久直通掉，输出被压到 ~48fps。
    /// 把硬限抬到 8、软限抬到 5，给瞬时抖动留余量：稳态在途仍远低于 5，
    /// 不会再误杀插值；真·worker 跟不上时也只是多缓冲几帧，不会退化成队列满死锁
    ///（队列满死锁的防线是下方 rifeAheadLimit，独立于本值）。
    private static let rifeMaxInflight = 8
    /// 在途帧对软上限（超过则本对直通不插帧 —— protect interval）
    private static let rifeSoftInflight = 5
    /// 端到端领先量上限（RIFE 输入 + 在途帧对×2 输出帧 + 帧队列）。
    /// 对齐原版 RIFE60_MAX_AHEAD 的职责：没有它，兜底引擎预热期会以解码
    /// 全速把 frameQueue 灌满，出口线程被满队列卡住 → 在途堆积 →
    /// protect interval 永久触发 → 插帧几乎全灭，且系统锁死在
    /// 「队列全满 + 纯直通」的病态平衡里（拖进度条清空队列后才短暂恢复）。
    ///
    /// 注意**不能**把 videoPacketQueue 计进来：解封装瞬间就能灌满 200 包，
    /// 而唯一能排空它的是解码线程自己 —— 一算它就是自锁死锁。
    /// 上限 48 = 帧队列(64) 之下的安全水位，出口线程永不被顶死。
    private static let rifeAheadLimit = 48
    /// 追帧直通计数（诊断用，调度线程独占写）
    private var rifeBehindFrames = 0
    /// 诊断：真推理 tick 计数（调度线程独占写）—— 判断每对实际跑了几个网络
    private var rifeChainTickCount = 0
    /// 诊断：调度分支快照（timeline 网格 / 定比）
    private var rifeLastBranch = "-"
    /// 诊断：最近一帧对的源帧率快照
    private var rifeLastFps: Double = 0

    /// 端到端领先量限流：补帧激活时由解码线程在入队前调用。
    /// 把解码领先显示的量压在 ~1s 内，管线常年半空，插帧才能按目标帧率流动。
    private func rifeThrottleWait(generation gen: Int) {
        while !isStopping {
            let ahead = rifeInputQueue.count
                      + 2 * rifeReorder.inflight + frameQueue.count
            if ahead <= Self.rifeAheadLimit { return }
            if currentGeneration() != gen { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // MARK: 渲染侧（主线程独占）

    private let frameLock = NSLock()
    private var pendingFrame: DecodedVideoFrame?
    private var lastPresentedPTS: Double = -1
    private var loggedFirstFrame = false
    private var audioPrebufferDone = false
    private var captureStartPTS: Double?

    private var ticker: Timer?
    private var audioStallWatchdogStart: TimeInterval = 0

    // dev-only：脚本化 seek 只触发一次（见 applyScriptedSeekIfRequested）。
    private var scriptedSeekDone = false

    // 仅 demux 线程读写（追踪用）
    private var demuxReadCount = 0
    private var pushTimeouts = 0
    private var lastDemuxTrace: TimeInterval = 0
    private var loggedEOF = false

    // dev-only：seek 之后要打印的前若干个包的计数
    private var postSeekPacketLog = 0

    // MARK: - 打开

    /// 打开媒体文件。会同步做完解封装/解码器初始化，并自动开始播放。
    /// 调用方应放在后台线程（内部有磁盘 I/O 与 FFmpeg 探测）。
    func open(url: URL) throws {
        shutdownPipeline()

        stateLock.lock()
        stopRequested = false
        seekRequested = nil
        wantPlaying = true
        eofReached = false
        videoDrained = false
        audioDrained = false
        generation &+= 1
        minValidPTS = 0
        _state = .opening
        stateLock.unlock()
        // 复位队列（上一轮可能被 close 过）
        videoPacketQueue.reopen()
        audioPacketQueue.reopen()
        frameQueue.reopen()
        rifeInputQueue.reopen()
        rifeJobQueues.forEach { $0.reopen() }
        rifeReorder.reopen()
        frameLock.lock(); pendingFrame = nil; lastPresentedPTS = -1; loggedFirstFrame = false; audioPrebufferDone = false; frameLock.unlock()
        demuxReadCount = 0; pushTimeouts = 0; lastDemuxTrace = 0; loggedEOF = false
        anchorLock.lock(); audioAnchorPTS = nil; audioBuffersScheduled = false; anchorLock.unlock()
        // 性能计数归零：换文件之后旧的计数没有意义，留着会算出跨文件的假 FPS。
        resetStats()

        let src = try MediaFileSource(url: url)
        self.url = url
        self.source = src
        self.duration = src.duration
        self.minValidPTS = 0

        // Phase 2：轨道清单在开文件时**取一次快照**，之后 UI 只读这份数组。
        //
        // 为什么不提供「随时去问 MediaFileSource」的口子：那个类有明确的线程约定
        // （只允许解封装线程碰，见文件头）。菜单是主线程构造的，越界读
        // AVFormatContext 等于在两个线程上同时摸一个结构体 —— 正是 Phase 1
        // 那个 async_lock 断言的同类问题。快照没有这个问题：它是个值类型数组。
        //
        // 轨道在播放期间不会变（换轨只切解码器，不增删流），所以一次快照足够。
        self.tracks = src.enumerateTracks()
        // 同上：详细参数也在这里取一次快照（Tab 监看面板的上半部分）。
        // 之后若做切轨/改参数，这份快照要跟着更新 —— 目前没有那些路径。
        stateLock.lock()
        self._detail = src.detail()
        stateLock.unlock()

        // Phase 3：字幕管线。必须在这里建 —— 此刻解封装线程还没起来（startThreads 在后面），
        // 而 `codecParameters` / `embeddedFonts` 都归解封装线程所有。
        setupSubtitlePipeline(source: src)

        sourceInfo = "\(src.formatName) · \(FFmpegSupport.timeLabel(src.duration))"
            + (src.hasVideo ? " · " + src.videoSummary() : "")
            + (src.hasAudio ? " · " + src.audioSummary() : "")

        if src.hasVideo, let par = src.codecParameters(at: src.videoStreamIndex) {
            let useHW = (PlaybackSettings.shared.decodeMode == .hardware)
            let dec = try VideoDecoder(parameters: par,
                                       timeBase: src.videoTimeBase,
                                       useHardware: useHW,
                                       frameRate: src.videoFrameRate,
                                       isMTSOrInterlacedHint: src.isMTSOrInterlacedHint)
            videoDecoder = dec
            videoSize = CGSize(width: dec.width, height: dec.height)
            Self.log("视频解码器已建立: \(dec.codecName) (\(dec.isHardwareAccelerated ? "硬解 VideoToolbox" : "软解")) [MTS/隔行提示: \(src.isMTSOrInterlacedHint)]")
        }
        let initialAudioIdx = src.audioStreamIndex
        stateLock.lock(); _selectedAudioStreamIndex = initialAudioIdx; stateLock.unlock()

        if src.hasAudio, let par = src.codecParameters(at: src.audioStreamIndex) {
            if let dec = try? AudioDecoder(parameters: par, timeBase: src.audioTimeBase) {
                audioDecoder = dec
                let out = AudioOutput(sampleRate: 48_000, channels: 2)
                out.volume = storedVolume
                do {
                    try out.start()
                    audioOutput = out
                    Self.log("音频输出已启动: \(out.format.sampleRate)Hz / \(out.format.channelCount)ch")
                } catch {
                    // 没有可用输出设备：退化成「有音轨但不播」，时钟改走墙上时间
                    audioOutput = nil
                    audioDecoder = nil
                    Self.log("音频输出启动失败，改走墙上时钟: \(error.localizedDescription)")
                }
            }
        }

        clock.hasAudio = (audioOutput != nil)
        clock.scheduledAudioEnd = 0
        clock.reset(to: 0)
        clock.audioTimeProvider = { [weak self] () -> Double? in
            guard let self,
                  let out = self.audioOutput,
                  let played = out.renderedSeconds() else { return nil }
            self.anchorLock.lock()
            let anchor = self.audioAnchorPTS
            self.anchorLock.unlock()
            guard let a = anchor else { return nil }
            return a + played
        }

        startThreads()
        startTicker()
        Self.log("已打开 \(url.lastPathComponent) — \(sourceInfo)")

        // 自动开播：等价于原版「打开即播」的行为
        clock.start()
        setState(.playing)
    }

    // MARK: - 播放控制

    func play() {
        // 放完之后再点播放 = 从头重播。
        //
        // 这里原来是 `seek(to: 0); return` —— 只丢一个 seek 请求就退出，
        // 状态机仍停在 .ended、wantPlaying 仍是 false、时钟仍是暂停的。
        // 于是这条分支成了死路：再点一次还是 .ended，还是只 seek(0)，
        // 永远起不来（用户报的就是「不能点击播放再放一次」）。
        // 必须走完下面那整套起播动作，只是把位置先归零。
        if state == .ended {
            restartFromBeginning()
            return
        }
        stateLock.lock(); wantPlaying = true; stateLock.unlock()
        anchorLock.lock(); let scheduled = audioBuffersScheduled; anchorLock.unlock()
        if scheduled { audioOutput?.play() }
        clock.start()
        setState(.playing)
    }

    /// 结束态的「从头再来」：先把播放意图立起来，再下 seek 请求，最后推状态。
    ///
    /// 顺序不能反：`applySeek` 末尾读 `wantPlaying` 决定要不要让音频继续，
    /// 而 seek 是**异步**的（由解封装线程执行），这里若先改状态后下请求，
    /// applySeek 就可能读到旧的 false 把音频按回去。
    private func restartFromBeginning() {
        stateLock.lock(); wantPlaying = true; stateLock.unlock()
        seek(to: 0)

        // 时钟立刻归零并起走：进度条不再钉在片尾。
        // 真正的精确对齐由首帧上屏时那次 `clock.reset(to: 首帧 pts)` 兜底
        //（applySeek 已把 loggedFirstFrame 复位，所以那次对齐一定会发生）。
        clock.reset(to: 0)
        clock.start()

        // 这里**不能**直接 audioOutput?.play()：seek 会 flush 掉旧 buffer，
        // 空 buffer 起播时 playerTime 会空转把时钟带飞（applySeek 注释里那次
        // throttleAudio 死锁就是这么来的）。交给音频线程排入第一个 buffer
        // 后自行触发（见 audioLoop 里的 `if isWantPlaying, !out.isPlaying`）。
        setState(.playing)
        Self.log("从头重播：结束态 → 播放")
    }

    func pause() {
        stateLock.lock(); wantPlaying = false; stateLock.unlock()
        audioOutput?.pause()
        clock.pause()
        setState(.paused)
    }

    func togglePlayPause() {
        if state == .playing { pause() } else { play() }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        stateLock.lock()
        seekRequested = clamped
        eofReached = false
        stateLock.unlock()

        // 放完之后拖进度条：必须把状态机从 .ended 拉回 .paused。
        // 否则状态一直挂在 .ended，play() 每次都走「只 seek(0)」那条死路，
        // 而时钟还停在片尾那一格不动 —— 进度条看着就是「拉不动」。
        if state == .ended {
            // 时钟是暂停的，reset 之后 currentTime 立刻等于目标点，
            // 渲染下一次取帧就能把目标位置的画面顶上来。
            clock.reset(to: clamped)
            setState(.paused)
            Self.log(String(format: "结束态拖动进度条 → %.2fs（已复活为暂停态）", clamped))
        }
    }

    /// 彻底停止并释放资源。会等待所有工作线程退出。
    func shutdown() {
        shutdownPipeline()
        setState(.idle)
    }

    // MARK: - 热切换（Phase 2 增补）

    /// 就地重建管线：不重启 APP，把正在放的这个文件按**当前设置**从头拉起一遍，
    /// 保留播放位置与播放/暂停状态。
    ///
    /// 为什么需要它：原版对 RIFE 模型 / 档位 / 核心数这类设置的做法是
    /// 「保存 + 提示下次重启播放器后生效」（文案 `restart_next_launch_with_mode`）。
    /// 那些设置影响的正是**管线本身**（解码器 / 推理引擎 / 渲染链），
    /// 而管线是开文件时按当时设置搭起来的 —— 所以原版只能重启。
    /// 本工程改成：设置一变就把管线拆了重建，用户不必重启。
    ///
    /// 调用方：`PlayerContainerView` 收到 `.playbackSettingsDidChange` 且判定
    /// 「这项影响管线」时。内部会重入 `open(url:)`，那是个重活（磁盘 I/O），
    /// 所以调用方应保证在后台线程；这里不做线程跳转，避免和调用方的调度打架。
    ///
    /// - Returns: 是否真的重建了（没文件可重开时返回 false，调用方据此决定要不要提示）。
    @discardableResult
    func reloadInPlace() -> Bool {
        guard let target = url else { return false }

        // 先把「现在放到哪了 / 是不是在播」记下来 —— open() 会把这两样都清掉。
        let resumeAt = duration > 0 ? min(max(0, currentTime), duration) : currentTime
        let wasPlaying = isPlaying

        do {
            try open(url: target)
        } catch {
            setState(.failed(error.localizedDescription))
            return false
        }

        // open() 会把位置归零并自动开播，所以：
        //   1. 位置恢复到重建前的地方（走正常的 seek 通路，解封装线程会处理）
        //   2. 若重建前是暂停态，再按回去
        if resumeAt > 0.05 { seek(to: resumeAt) }
        if !wasPlaying { pause() }
        Self.log("热切换：已就地重建管线 — \(target.lastPathComponent)"
                 + String(format: " · 续播 %.2fs · %@", resumeAt, wasPlaying ? "保持播放" : "保持暂停"))
        return true
    }

    // MARK: - 渲染取帧（主线程调用）

    /// 返回「此刻该显示」的帧；没有就返回 nil（渲染器继续显示上一帧）。
    ///
    /// 顺带记三个性能计数（丢帧 / 上屏帧）。**刻意在释放 `frameLock` 之后**再更新
    /// 那组计数器 —— 两把锁嵌套就得分清「谁在外面」，而这里没有任何理由嵌套：
    /// 计数在临界区外做，锁序永远只有单层的 frameLock 或单层的 statsLock。
    func nextFrameForDisplay() -> DecodedVideoFrame? {
        let now = clock.currentTime()

        var lateDropped = 0
        var presented: DecodedVideoFrame?

        frameLock.lock()
        let latencyMode = PlaybackSettings.shared.captureLowLatencyMode
        let isInterpolating = (PlaybackSettings.shared.rifeRateMode != .off)

        if isCaptureMode && latencyMode != .off && !isInterpolating {
            // 采集卡原生极低延迟直出模式（仅在未开启补帧时生效）：
            // 只要队列中有帧，立即弹出最新帧呈现，如有积压旧帧则直接跳过，零等待 V-Sync 立即上屏。
            //
            // 两档在这里才有区别：极限电竞一路取到最新、队列清空（延迟最低）；
            // 平衡抗抖动在队列里保留最后 1 帧当缓冲，吸收 USB/驱动侧的帧到达抖动。
            // 之前两档共用同一个 while，行为完全一致。
            let reserve = (latencyMode == .extreme) ? 0 : 1
            var newest = pendingFrame ?? frameQueue.tryPop()
            while frameQueue.count > reserve, let newer = frameQueue.tryPop() {
                if newest != nil { lateDropped += 1 }
                newest = newer
            }
            pendingFrame = nil
            if let candidate = newest {
                lastPresentedPTS = candidate.pts
                if !loggedFirstFrame {
                    loggedFirstFrame = true
                    Self.log("首帧上屏 pts=\(String(format: "%.3f", candidate.pts))s [采集卡超低延迟直出已激活]")
                }
                presented = candidate
            }
        } else {
            // 标准时间轴对齐呈现（文件回放，或者采集卡开启 RIFE/FLAVR 补帧）：
            // 严格按 V-Sync 节奏输出每一帧过渡画面，绝不批量清空队列丢弃插值帧
            if pendingFrame == nil { pendingFrame = frameQueue.tryPop() }

            // 迟到丢帧保护门限：仅在音画严重脱节（超过 0.4 秒）或 seek 后才丢帧追时钟，避免误杀正常插值帧
            while let c = pendingFrame, c.pts < now - 0.40 {
                pendingFrame = frameQueue.tryPop()
                lateDropped += 1
            }

            // 根据目标帧率动态计算提前上屏容差（覆盖 ~70% 的 V-Sync 刷新周期，例如 60fps 对应 ~11.6ms，24fps 对应 ~22ms）
            // 彻底防止因 1ms 调度微差错过刷新窗口导致的 15~30Hz 规律性周期性抽搐 (Judder)
            let srcFPS = videoDecoder?.frameRate ?? (isCaptureMode ? captureFPS : 24.0)
            let targetFPS = StatsPanelView.targetFrameRate(source: srcFPS, mode: PlaybackSettings.shared.rifeRateMode)
            let activeFPS = targetFPS > 0 ? targetFPS : (srcFPS > 0 ? srcFPS : 60.0)
            let earlyTolerance = max(0.010, min(0.022, 0.70 / activeFPS))

            if let candidate = pendingFrame, candidate.pts <= now + earlyTolerance {
                pendingFrame = nil
                lastPresentedPTS = candidate.pts
                if !loggedFirstFrame {
                    loggedFirstFrame = true
                    clock.reset(to: candidate.pts)
                    Self.log("首帧上屏 pts=\(String(format: "%.3f", candidate.pts))s (时钟基准已对齐)")
                }
                presented = candidate
            }
        }
        frameLock.unlock()

        if lateDropped > 0 { noteDroppedFrame(count: lateDropped) }
        guard let frame = presented else { return nil }
        notePresentedFrame()
        // dev-only：MP_DUMP_FRAME 指定时导出符合目标 pts 的第一帧（见 FrameDumper）
        FrameDumper.dumpIfRequested(frame)
        return frame
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[PlaybackEngine] \(message)\n".utf8))
    }

    // MARK: - 线程启动 / 收尾

    private func startThreads() {
        // 只要文件里有音轨就把音频解码线程拉起来 —— 即便解码器没能建起来
        // （例如没有可用输出设备），也需要有人把音频包队列排空，
        // 否则解封装线程会在这条队列上阻塞，连视频一起卡死。
        let shouldDrainAudio = (source?.hasAudio ?? false)

        threadGroup.enter()
        demuxQueue.async { [weak self] in
            defer { self?.threadGroup.leave() }
            self?.demuxLoop()
        }

        threadGroup.enter()
        videoQueue.async { [weak self] in
            defer { self?.threadGroup.leave() }
            self?.videoLoop()
        }

        if shouldDrainAudio {
            threadGroup.enter()
            audioQueue.async { [weak self] in
                defer { self?.threadGroup.leave() }
                self?.audioLoop()
            }
        }
    }

    private func shutdownPipeline() {
        stopTicker()

        stateLock.lock(); stopRequested = true; seekRequested = nil; wantPlaying = false
        stateLock.unlock()

        // 关队列唤醒所有阻塞中的线程
        videoPacketQueue.close()
        audioPacketQueue.close()
        frameQueue.close()
        rifeInputQueue.close()
        rifeJobQueues.forEach { $0.close() }
        rifeReorder.close()
        stateLock.lock(); rifeThreadsStarted = false; stateLock.unlock()
        audioOutput?.teardown()

        // 等线程真正退出（每个线程都在 threadGroup 里）
        if threadGroup.wait(timeout: .now() + 3) == .timedOut {
            FileHandle.standardError.write(
                Data("[PlaybackEngine] 警告：工作线程未在 3s 内退出\n".utf8))
        }

        // 此时没有线程在跑，可以安全拆组件
        if let cap = captureSession {
            cap.stopRunning()
            captureSession = nil
        }
        captureOutputDelegate = nil
        captureAudioPreviewOutput = nil
        isCaptureMode = false
        source?.close()
        source = nil
        videoDecoder = nil
        audioDecoder = nil
        audioOutput = nil
        subtitleDecoder?.close()
        subtitleDecoder = nil
        subtitleRenderer = nil
        stateLock.lock()
        _selectedSubtitleStreamIndex = -1
        subtitleRequest = nil
        _selectedAudioStreamIndex = -1
        audioTrackRequest = nil
        stateLock.unlock()
        setExternalSubtitleName(nil)
        tracks = []
        stateLock.lock()
        _detail = MediaDetail()
        stateLock.unlock()
        resetStats()
        clock.audioTimeProvider = nil
        anchorLock.lock(); audioAnchorPTS = nil; audioBuffersScheduled = false; anchorLock.unlock()
    }

    // MARK: - 解封装线程

    private func demuxLoop() {
        while !isStopping {
            if let target = takeSeekRequest() {
                applySeek(target)
                continue
            }
            // 音轨请求（切音轨）由这个线程执行
            if let req = takeAudioTrackRequest() {
                applyAudioTrackRequest(req)
                continue
            }
            // 字幕请求（切轨 / 装外挂）由这个线程执行 —— 它要动 MediaFileSource
            // 的流索引、重建字幕解码器，两件事都归这个线程所有。
            if let req = takeSubtitleRequest() {
                applySubtitleRequest(req)
                continue
            }
            if isEOF {
                Thread.sleep(forTimeInterval: 0.05)   // 等可能的 seek
                continue
            }
            guard let src = source else { return }

            let gen = currentGeneration()
            // 本循环永不返回（`continue` 一路绕回去），autorelease 临时对象
            // 会永久堆积。每趟读包 + 拷贝都包一层池排掉 —— 与 video/worker/
            // emit 三个循环同一个道理（那三个是泄漏到 1.3GB/s 的元凶）。
            // 池必须是闭包，而 `continue` 穿不过去，所以把整段搬进
            // demuxStep（里面的 continue 变成 return）。
            autoreleasepool { demuxStep(src: src, gen: gen) }
        }
    }

    /// demuxLoop 的单趟主体。抽出来是为了能整段包进 autoreleasepool：
    /// 原地的 `continue` 在这里写成 `return`，语义一致（都表示「本趟结束」）。
    private func demuxStep(src: MediaFileSource, gen: Int) {
        // 读包不需要门闸：AVFormatContext 只有解封装线程会碰
        //（seek 也是由这个线程执行的），本身就没有并发。
        let read = src.readNextPacket()

        if Self.traceEnabled {
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastDemuxTrace > 0.5 {
                lastDemuxTrace = now
                Self.log("demux: 累计读包 \(demuxReadCount) | 队列 v=\(videoPacketQueue.count) "
                         + "a=\(audioPacketQueue.count) | 推送超时 \(pushTimeouts) | EOF=\(isEOF)")
            }
        }

        if read == nil {
            if !loggedEOF {
                loggedEOF = true
                Self.log("demux: av_read_frame 返回文件尾（累计读包 \(demuxReadCount)）")
            }
            signalEndOfStream(generation: gen)
            return
        }
        demuxReadCount += 1

        var kind: PacketKind?
        var box: PacketBox?
        if let r = read {
            // 字幕包：**不入队、不开线程**，就在解封装线程原地处理完。
            //
            // 为什么不为它建第三条队列 + 第三个线程：字幕包是低频的（几秒一个），
            // 处理也只是「解析一行文本 + 往 libass 的 track 里加一条」，
            // 换来的并发度抵不上多一套队列 / 代际 / 收尾逻辑的复杂度。
            //
            // 代际检查不能省：seek 之前读到的字幕属于旧时间轴。
            // 喂进去虽不至于显示错（libass 是按时间查的），但会白占内存。
            if r.index == src.subtitleStreamIndex && src.subtitleStreamIndex >= 0 {
                if currentGeneration() == gen {
                    ingestSubtitlePacket(r.packet, source: src)
                }
                return
            }
            if r.index == src.videoStreamIndex { kind = .video }
            else if r.index == src.audioStreamIndex { kind = .audio }
            if kind != nil {
                box = PacketBox(copying: r.packet)
                // dev-only：seek 之后打印前若干个包的流号与 pts，确认解封装器落在哪个时间段。
                if Self.traceEnabled, postSeekPacketLog > 0, let k = kind {
                    postSeekPacketLog -= 1
                    let tb = (k == .video) ? src.videoTimeBase : src.audioTimeBase
                    let rawTS = r.packet.pointee.pts != Int64.min
                        ? r.packet.pointee.pts : r.packet.pointee.dts
                    let secs = rawTS == Int64.min ? Double.nan
                                                 : FFmpegSupport.seconds(rawTS, tb)
                    Self.log(String(format: "demux[seek后]: %@ 包 pts=%.3fs (raw %lld)",
                                    k == .video ? "视频" : "音频", secs, rawTS))
                }
            }
        }

        guard let k = kind, let b = box else { return }
        // 已经 seek 过了：这个包属于旧时间轴
        if currentGeneration() != gen { return }
        pushWithRetry(.packet(b), kind: k, generation: gen)
    }

    /// 文件读完了：往两条包队列的**尾部**各放一个流结束标记。
    ///
    /// 关键点：这里**不碰解码器**。冲刷由解码线程在消费完自己的队列后自行完成
    /// （见 PacketItem 的注释 —— 早一步 flush 会把参考帧冲掉，画面就卡在开头）。
    private func signalEndOfStream(generation gen: Int) {
        stateLock.lock(); eofReached = true; stateLock.unlock()
        pushWithRetry(.endOfStream, kind: .video, generation: gen)
        pushWithRetry(.endOfStream, kind: .audio, generation: gen)
    }

    private enum PacketKind { case video, audio }

    private func pushWithRetry(_ item: PacketItem, kind: PacketKind, generation gen: Int) {
        let queue = (kind == .video) ? videoPacketQueue : audioPacketQueue
        while !isStopping {
            if queue.push(item, timeout: 0.1) { return }
            pushTimeouts += 1
            if currentGeneration() != gen { return }
        }
    }

    // MARK: - 视频解码线程

    private func videoLoop() {
        while !isStopping {
            guard let item = videoPacketQueue.pop() else { return }
            if isStopping { return }
            let gen = currentGeneration()

            switch item {
            case .endOfStream:
                // 队列已经排空，现在才是冲刷解码器的时机
                videoGate.enter()
                // 解码是本线程 autorelease 临时对象的大头（解码循环永不返回，
                // 块级自动释放池排不到）。用返回值式包池，不穿越控制流。
                let tail = autoreleasepool {
                    (try? videoDecoder?.decode(packet: nil)) ?? []
                }
                videoGate.leave()
                if currentGeneration() != gen { break }
                noteDecodedFrames(tail.count)
                let floor = currentMinValidPTS
                for f in tail where f.pts >= floor { enqueueFrame(f) }
                // 流末哨兵：让调度线程把最后一个未配对的 prev 源帧提交出去，
                // 否则文件的最后一帧会永远停在调度线程手里。
                if rifeThreadsStarted {
                    _ = rifeInputQueue.push(.end(generation: gen), timeout: 0.05)
                }
                stateLock.lock(); videoDrained = true; stateLock.unlock()
                Self.trace("video: 已冲刷解码器，尾帧 \(tail.count) 张")

            case .packet(let box):
                videoGate.enter()
                let frames = autoreleasepool {
                    (try? videoDecoder?.decode(packet: box.packet)) ?? []
                }
                videoGate.leave()
                if currentGeneration() != gen { continue }
                noteDecodedFrames(frames.count)
                let floor = currentMinValidPTS
                for f in frames where f.pts >= floor {
                    enqueueFrame(f)
                }
            }
        }
    }

    private func enqueueFrame(_ f: DecodedVideoFrame) {
        let gen = currentGeneration()
        let settings = PlaybackSettings.shared
        let fps = videoDecoder?.frameRate ?? (isCaptureMode ? captureFPS : 0)

        // 采集卡「假 60 帧（真 30）」识别：CadenceDetector 用亮度差分 FSM 检测 2:2 重复帧，
        // 命中后直接抽掉重复帧 —— 流还原成真 30fps，再由下方 2X（fps60 模式在源帧率 ≥ 29 时
        // 即等价于每对 1 次真插值）补回真 60fps。只抽「已锁定假 60 且确为重复」的帧，
        // 真 60fps 静态画面不会被误抽。放在最前：丢弃的重复帧不再做限流与 YUY2 转换。
        // processFrame 每帧都调用以维持 FSM 历史（含即将丢弃的重复帧本身）。
        if isCaptureMode, settings.rifeRateMode != .off {
            let cadenceDecision = CadenceDetector.shared.processFrame(
                pixelBuffer: f.pixelBuffer,
                containerFPS: fps,
                settings: settings)
            if cadenceDecision.cadence == .fake60From30, cadenceDecision.isDuplicate {
                return   // 抽掉 2:2 重复帧，不送补帧/上屏（其时刻由相邻真帧插值补全）
            }
        }

        // 补帧激活期间的端到端限流（对齐原版 RIFE60_MAX_AHEAD）：先压住解码
        // 领先量，再谈路由 —— 否则管线被灌满后 protect interval 会永久触发。
        if settings.rifeRateMode != .off {
            rifeThrottleWait(generation: gen)
        }

        // 真·RIFE 神经网络引擎就绪 → 源帧交给异步推理流水线。
        // 解码线程在这里**绝不等推理**：入队失败/换代即放弃，推理延迟由
        // 调度线程的背压与 protect interval 消化。
        //
        // ⚠️ 打包 4:2:2（YUY2）不能进这条链路：推理引擎按双平面 NV12 取纹理
        //（mapNV12Textures），喂打包缓冲会得到错误的输入甚至直接失败。
        // 这里显式降级为直通并只提示一次 —— 画面正确优先于补帧，
        // 静默产出垃圾比少一个功能糟糕得多。
        let pixelFormat = CVPixelBufferGetPixelFormatType(f.pixelBuffer)
        var isPacked422 = (pixelFormat == kCVPixelFormatType_422YpCbCr8_yuvs)
        // 采集卡原生输出 YUY2（打包 4:2:2），而 RIFE 推理引擎只认双平面 NV12。
        // 这里先把 YUY2 在 GPU 上解包成 NV12，之后就能正常进补帧链路 ——
        // 直接喂打包缓冲会拿到错误输入甚至失败。
        var effectiveFrame = f
        if isPacked422, settings.rifeRateMode != .off {
            if let nv12 = CoreMLRIFEEngine.shared.convertPacked422ToNV12(f.pixelBuffer) {
                effectiveFrame = DecodedVideoFrame(pixelBuffer: nv12, pts: f.pts,
                                                  isBT709: f.isBT709,
                                                  colorSpaceCode: f.colorSpaceCode,
                                                  isFullRange: f.isFullRange,
                                                  isInterpolated: false)
                isPacked422 = false   // 已转 NV12，可走补帧
            } else {
                // 引擎还在加载期：回落直通，只提示一次（加载完下一帧即可补帧）
                notePacked422InterpolationSkipOnce()
            }
        }

        if !isPacked422,
           !settings.rifeModel.isFLAVR,
           settings.rifeRateMode != .off,
           CoreMLRIFEEngine.shared.isReady(settings: settings,
                                           sourceWidth: CVPixelBufferGetWidth(effectiveFrame.pixelBuffer),
                                           sourceHeight: CVPixelBufferGetHeight(effectiveFrame.pixelBuffer),
                                           fullRange: effectiveFrame.isFullRange,
                                           bt709: effectiveFrame.isBT709) {
            ensureRifePipeline()
            while !isStopping {
                if rifeInputQueue.push(.frame(effectiveFrame, generation: gen, fps: fps),
                                       timeout: 0.1) { return }
                if currentGeneration() != gen { return }
            }
            return
        }

        let framesToEnqueue: [DecodedVideoFrame]
        if isPacked422 {
            // 打包 4:2:2 且未转换（引擎未就绪）：直通上屏（渲染器支持）
            framesToEnqueue = [effectiveFrame]
        } else if settings.rifeModel.isFLAVR {
            framesToEnqueue = flavrEngine.interpolate(incoming: effectiveFrame, settings: settings, sourceFrameRate: fps)
        } else {
            // 引擎未就绪：后台拉起初始化（秒级），先用块匹配引擎顶着，就绪后热切换
            CoreMLRIFEEngine.shared.prewarmIfNeeded(settings: settings,
                                                    sourceWidth: CVPixelBufferGetWidth(effectiveFrame.pixelBuffer),
                                                    sourceHeight: CVPixelBufferGetHeight(effectiveFrame.pixelBuffer),
                                                    fullRange: effectiveFrame.isFullRange,
                                                    bt709: effectiveFrame.isBT709)
            framesToEnqueue = rifeEngine.interpolate(incoming: effectiveFrame, settings: settings, sourceFrameRate: fps)
        }
        pushOutputs(framesToEnqueue, generation: gen)
    }

    // MARK: 真·RIFE 流水线线程体

    /// 按需拉起 RIFE 流水线线程（一次；shutdownPipeline 关闭后复位）。
    private func ensureRifePipeline() {
        stateLock.lock()
        let started = rifeThreadsStarted
        if !started { rifeThreadsStarted = true }
        stateLock.unlock()
        guard !started else { return }

        rifeJobQueues = [
            BoundedQueue<RifeJob>(capacity: 4),
            BoundedQueue<RifeJob>(capacity: 4),
        ]
        rifeDispatchQueue.async { [weak self] in self?.rifeDispatchLoop() }
        rifeEmitQueue.async { [weak self] in self?.rifeEmitLoop() }
        for i in 0..<rifeWorkerQueues.count {
            rifeWorkerQueues[i].async { [weak self] in self?.rifeWorkerLoop(i) }
        }
    }

    /// 调度线程：组帧对 → 决定插值时间戳 → 按 seq 提交（乱序执行、按序回收）。
    private func rifeDispatchLoop() {
        var prev: DecodedVideoFrame?
        var prevLuma: [UInt8]?
        var prevGen = -1
        var seq = 0
        var diag = 0
        var cursor = -1.0   // 时间轴重采样游标：严格对齐目标帧率网格

        func submit(_ f0: DecodedVideoFrame, _ f1: DecodedVideoFrame,
                    ticks: [CoreMLRIFEEngine.RifeTick],
                    itemGen: Int, itemFps: Double, settings: PlaybackSettings) {
            guard rifeReorder.waitCapacity(Self.rifeMaxInflight) else { return }
            // protect interval：在途超过软限 → 本对**不跑网络**，但网格节奏不丢。
            //
            // 旧做法 t = [] 整对直通：24fps 片源 + 60fps 模式下真推理需求 ≈48 次/秒
            // 超出 ANE 双实例 ~44 上限，protect 会持续触发 —— 输出瞬间从 60 网格掉回
            // 纯 24fps 源帧、下一对又爆发补帧，帧间距在 16.7ms 与 41.7ms 之间跳变，
            // 视觉上就是「一下快一下慢」，统计上落在 ~48.6fps（实测复现）。
            // 新做法：保留网格 PTS，把 tick 全部降级为 runChain=false（复制帧，
            // 零网络开销）→ 输出节奏恒定贴 60fps 网格，真推理量被自然节流回预算内。
            var t = ticks
            if !t.isEmpty && rifeReorder.inflight >= Self.rifeSoftInflight {
                rifeBehindFrames += 1
                t = t.map { CoreMLRIFEEngine.RifeTick(pts: $0.pts, alpha: $0.alpha, runChain: false) }
            }
            let job = RifeJob(seq: seq, generation: itemGen,
                              workerIndex: seq % rifeWorkerQueues.count,
                              f0: f0, f1: f1, ticks: t,
                              fps: itemFps, settings: settings)
            seq += 1
            rifeReorder.submit(seq: job.seq)
            _ = rifeJobQueues[job.workerIndex].push(job, timeout: 0.5)
        }

        while !isStopping {
            guard let item = rifeInputQueue.pop() else {
                if isStopping { break }
                Thread.sleep(forTimeInterval: 0.02)   // 队列已关闭：等下一轮 open
                continue
            }
            if isStopping { break }
            // 本调度循环只做 PTS 算术与稀疏采样（纯 Swift 对象，无 autorelease
            // 积压），重活都在 worker 侧并在那里排池 —— 这里刻意不加池：
            // autoreleasepool 是闭包，continue 无法穿越它。
            let gen = currentGeneration()

            switch item {
            case .end(let eGen):
                // 流末哨兵：把最后一个还没配对的 prev 源帧提交出去（空 ticks → 仅直通）
                if gen == eGen, let p = prev, gen == prevGen {
                    submit(p, p, ticks: [], itemGen: gen, itemFps: 0, settings: PlaybackSettings.shared)
                }
                prev = nil; prevLuma = nil; cursor = -1

            case .frame(let f, let itemGen, let fps):
                if itemGen != gen { continue }
                if gen != prevGen { prev = nil; prevLuma = nil; cursor = -1; prevGen = gen }

                guard let p = prev else {
                    prev = f
                    continue
                }
                prev = f

                let settings = PlaybackSettings.shared
                var ticks: [CoreMLRIFEEngine.RifeTick] = []
                let dt = f.pts - p.pts
                var skip = (dt <= 0.001 || dt > 1.0)   // 倒退/跳变（seek 等）→ 直通

                // 镜头转场保护（调度线程独占 prevLuma，无共享状态）
                let luma = CoreMLRIFEEngine.sampleDownscaledLuma(from: f.pixelBuffer)
                if !skip, settings.rifeTransitionDetection,
                   let pl = prevLuma, luma.count == pl.count {
                    var diffSum = 0.0
                    for i in 0..<luma.count { diffSum += abs(Double(luma[i]) - Double(pl[i])) }
                    if diffSum / Double(luma.count * 255) > settings.rifeSceneThreshold { skip = true }
                }
                prevLuma = luma

                if !skip {
                    let similar = CoreMLRIFEEngine.areFramesSimilar(p.pixelBuffer, f.pixelBuffer)
                    let timeline = settings.rifeRateMode.needsTimelineResample(sourceFPS: fps)
                    rifeLastBranch = timeline ? "网格" : (similar ? "静帧" : "定比")
                    rifeLastFps = fps
                    if timeline {
                        // 时间轴连续重采样（60/120/自定义）：tick 严格对齐目标帧率网格
                        //（1/60s = 16.667ms），每个落在 (0.04, 0.96) 内的网格点都跑**真**
                        // 神经网络合成 —— 即「全真 60 帧 / 120 帧」。端点附近的网格点
                        //（alpha < 0.04 或 > 0.96）与相邻源帧几乎重合，复制即可、零开销。
                        //
                        // 采集卡「假 30fps → 真 60fps」由此自然成立：CadenceDetector 已在
                        // enqueueFrame 抽掉 2:2 重复帧，把流还原成真 30fps；这里每对只插 1 个
                        // 真网格点（30 对/秒推理，远在 ANE 双实例 ~44 对/秒预算内）→ 顺滑真 60。
                        // 24fps 影片 → 60fps 每对插 2 个真网格点（48 对/秒），超出预算时由
                        // protect-interval 逐对优雅直通（偶发重复帧，不冻结），不会卡死。
                        let targetFPS: Double
                        switch settings.rifeRateMode {
                        case .fps60: targetFPS = 60.0
                        case .fps120: targetFPS = 120.0
                        case .customFps: targetFPS = max(10.0, min(240.0, settings.rifeCustomTargetFps))
                        default: targetFPS = 60.0
                        }
                        let step = 1.0 / targetFPS
                        if cursor < 0 || abs(p.pts - cursor) > 0.5 { cursor = p.pts }
                        while cursor + step <= f.pts + 0.0001 {
                            cursor += step
                            let alpha = Float(max(0.0, min(1.0, (cursor - p.pts) / dt)))
                            // 端点网格点（alpha≤0.10 / ≥0.90）离源帧 ≤3ms，源帧本身就会上屏，
                            // 复制即可 —— 绝不跑网络。旧界 0.96 在采集帧间隔抖动（dt 30~36ms）
                            // 下会让大量 alpha≈0.93 的「准重复帧」跑真推理：30fps 源每对平均
                            // 1.3~1.7 次推理 → 40~50 次/秒，超出 ANE 双实例 ~44 对/秒预算 →
                            // protect-interval 频繁触发 → 输出被压到 ~46fps（实测复现）。
                            // 收紧到 0.90 后 30fps 源稳态每对恰 1 次推理，与 2X 同预算 → 真 60。
                            ticks.append(.init(pts: cursor, alpha: alpha,
                                               runChain: alpha >= 0.10 && alpha <= 0.90))
                        }
                    } else if similar {
                        // 静止画面：垫一帧拷贝，不跑网络
                        ticks = [.init(pts: p.pts + dt * 0.5, alpha: 0.5, runChain: false)]
                    } else {
                        for a in CoreMLRIFEEngine.fractionalAlphas(mode: settings.rifeRateMode) {
                            ticks.append(.init(pts: p.pts + Double(a) * dt, alpha: a, runChain: true))
                        }
                    }
                }
                rifeChainTickCount += ticks.filter { $0.runChain }.count

                submit(p, f, ticks: ticks, itemGen: gen, itemFps: fps, settings: settings)
            }

            diag += 1
            let needLog = (diag % 200 == 0)
                        || (MemoryFootprint.currentMB() > 4000 && diag % 50 == 0)
            if needLog {
                let ahead = videoPacketQueue.count + rifeInputQueue.count
                          + 2 * rifeReorder.inflight + frameQueue.count
                NSLog("[RIFE60] 足迹 %.0f MB | 领先量 %d 输入%d 在途%d 帧队列%d | 重排待发 %d "
                      + "| 直通 %d 插帧 %d 真推理 %d | 模式 %@ 源fps %.1f 分支 %@ | 解码包 %d | %@",
                      MemoryFootprint.currentMB(), ahead, rifeInputQueue.count,
                      rifeReorder.inflight, frameQueue.count, rifeReorder.pendingCount,
                      rifeBehindFrames, CoreMLRIFEEngine.shared.totalInterpolatedFrames,
                      rifeChainTickCount,
                      String(describing: PlaybackSettings.shared.rifeRateMode),
                      rifeLastFps, rifeLastBranch,
                      videoPacketQueue.count, CoreMLRIFEEngine.shared.poolStatsText())
            }
        }
    }

    /// worker：从自己的作业队列取帧对，调用独立 Engine 实例并行推理。
    private func rifeWorkerLoop(_ index: Int) {
        while !isStopping {
            guard let job = rifeJobQueues[index].pop() else {
                if isStopping { break }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            if isStopping { break }
            // 每对帧推理是 autorelease 临时对象的大头（CoreML 输出数组、
            // MLFeatureValue、字典…）：本循环永不返回，必须手动排池，否则
            // 每对 ~27MB 的堆内存会永久堆积（实测 1.3GB/s）。
            autoreleasepool {
            var out: [DecodedVideoFrame] = []
            if currentGeneration() == job.generation {
                out = CoreMLRIFEEngine.shared.runPair(workerIndex: index,
                                                      f0: job.f0, f1: job.f1,
                                                      ticks: job.ticks, settings: job.settings)
            }
            rifeReorder.push(seq: job.seq, gen: job.generation, frames: out)
            }
        }
        Self.log("RIFE worker\(index) 线程退出: 关闭=\(isStopping)")
    }

    /// 出口线程：按 seq 从重排缓冲取结果，按序推入 frameQueue。
    private func rifeEmitLoop() {
        while !isStopping {
            guard let r = rifeReorder.next() else {
                if isStopping { break }
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }
            if r.frames.isEmpty { continue }   // 换代丢弃的空结果
            // 同上：永不返回的循环块，每轮手动排池
            autoreleasepool {
                pushOutputs(r.frames, generation: r.gen)
            }
        }
        Self.log("RIFE 出口线程退出: 关闭=\(isStopping)")
    }

    /// 统一出口：把（可能含插帧的）帧序列按序推入 frameQueue，并处理
    /// 采集模式的防积压限流与音频预缓冲唤醒。解码线程与 RIFE 出口线程共用。
    private func pushOutputs(_ framesToEnqueue: [DecodedVideoFrame], generation gen: Int) {
        let settings = PlaybackSettings.shared
        let isInterpolating = (settings.rifeRateMode != .off)
        let isLowLatency = isCaptureMode && (settings.captureLowLatencyMode != .off) && !isInterpolating
        // 低延迟档位真正的差别：队列允许积压的上限帧数。
        // 极限电竞 = 只留最新 1 帧（延迟最低，抖动风险最大）；
        // 平衡抗抖动 = 留 2 帧（多一帧余量吸收网络/USB 抖动）。
        // 之前两档共用写死的 2，选哪一档行为完全一致，等于没得选。
        let lowLatencyCap = (settings.captureLowLatencyMode == .extreme) ? 1 : 2
        for outFrame in framesToEnqueue {
            // 换代（seek/切轨）后仍在本函数里的残留帧直接丢弃
            if currentGeneration() != gen { return }
            if isLowLatency {
                // 仅在未开启补帧的极低延迟模式下丢弃积压旧帧
                if frameQueue.count >= lowLatencyCap {
                    _ = frameQueue.tryPop()
                }
                _ = frameQueue.push(outFrame, timeout: 0.005)
                continue
            }
            // 补帧模式防积压门限：若渲染卡顿导致积压超过 10 帧，适度弹出最旧 1 帧限流防爆，但不暴利清空
            if isCaptureMode && isInterpolating && frameQueue.count >= 10 {
                _ = frameQueue.tryPop()
            }
            while !isStopping {
                if frameQueue.push(outFrame, timeout: 0.1) { break }
                if currentGeneration() != gen { return }
            }
        }

        // 原版 startRIFEAudioAfterPrebufferIfNeeded:
        // 当补帧开启且队列已缓冲 >= 3 帧时，唤醒音频播放，避免音频抢跑
        if !audioPrebufferDone && frameQueue.count >= 3 {
            audioPrebufferDone = true
            if isWantPlaying, let out = audioOutput, !out.isPlaying {
                out.play()
            }
        }
    }

    // MARK: - 音频解码线程

    private func audioLoop() {
        while !isStopping {
            guard let item = audioPacketQueue.pop() else { return }
            if isStopping { return }
            let gen = currentGeneration()

            switch item {
            case .endOfStream:
                // 与 demux/worker/emit 同因：本循环永不返回（pop 会阻塞），
                // 每包解码产生的 PCM 缓冲与桥接对象要靠手动排池才不会永久堆积。
                autoreleasepool {
                    audioGate.enter()
                    let tail = audioDecoder?.decode(packet: nil) ?? []
                    audioGate.leave()
                    if currentGeneration() != gen { return }
                    scheduleAudio(tail)
                    stateLock.lock(); audioDrained = true; stateLock.unlock()
                    Self.trace("audio: 已冲刷解码器，尾块 \(tail.count) 个")
                }

            case .packet(let box):
                // 池里不能直接 continue —— 用返回值告诉外面要不要继续限流
                let scheduled = autoreleasepool { () -> Bool in
                    audioGate.enter()
                    let chunks = audioDecoder?.decode(packet: box.packet) ?? []
                    audioGate.leave()
                    if currentGeneration() != gen { return false }
                    scheduleAudio(chunks)
                    return true
                }
                if scheduled { throttleAudio() }
            }
        }
    }

    private func scheduleAudio(_ chunks: [PCMChunk]) {
        guard let out = audioOutput, !chunks.isEmpty else { return }
        // seek 之后要丢掉目标点之前的音频，理由见 applySeek 里那段注释：
        // 容器只能跳到早先的关键帧时，解码器会先吐出一大段旧音频，
        // 全部排进播放器就会把音频锚点带回到 0，时钟随之错乱。
        // floor 与视频侧的 minValidPTS 是同一个值，保证音画丢弃点一致。
        let floor = currentMinValidPTS
        var scheduledAny = false
        for chunk in chunks where chunk.frameCount > 0 && chunk.endPTS >= floor {
            anchorLock.lock()
            if !audioBuffersScheduled {
                audioAnchorPTS = chunk.pts
                audioBuffersScheduled = true
                Self.trace(String(format: "audio: 锚点=%.3fs（本块 pts=%.3f, 时长 %.3f）",
                                  chunk.pts, chunk.pts, chunk.duration))
            }
            anchorLock.unlock()

            if out.schedule(chunk) {
                scheduledAny = true
                clock.scheduledAudioEnd = max(clock.scheduledAudioEnd, chunk.endPTS)
            }
        }
        guard scheduledAny else { return }
        if isWantPlaying, !out.isPlaying {
            let rifeActive = (PlaybackSettings.shared.rifeRateMode != .off)
            if rifeActive {
                // 原版 startRIFEAudioAfterPrebufferIfNeeded:
                // 等待插帧队列预缓冲至少 3 帧（或已有可用插值帧），再启动音频播放
                // 彻底消除音频抢跑导致的画面追赶、掉帧与抽搐
                if frameQueue.count >= 3 || audioPrebufferDone {
                    audioPrebufferDone = true
                    out.play()
                }
            } else {
                out.play()
            }
        }
    }

    /// 音频排得太超前就等一等 —— 这是音频侧唯一的限流点。
    private func throttleAudio() {
        var blockedSince: TimeInterval = 0
        var warned = false
        while !isStopping {
            let ahead = clock.scheduledAudioEnd - clock.currentTime()
            if ahead < 0.9 { return }
            if blockedSince == 0 {
                blockedSince = Date.timeIntervalSinceReferenceDate
            } else if !warned, Date.timeIntervalSinceReferenceDate - blockedSince > 1.0 {
                warned = true
                Self.trace(String(format: "audio: 限流阻塞中 —— 超前 %.3fs（排到 %.3f / 当前 %.3f）",
                                  ahead, clock.scheduledAudioEnd, clock.currentTime()))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    // MARK: - Seek

    private func applySeek(_ target: Double) {
        guard let src = source else { return }

        stateLock.lock()
        generation &+= 1
        minValidPTS = max(0, target - 0.3)
        stateLock.unlock()

        // 0. **先给帧队列松绑，再谈冻结。**
        //
        // 顺序错了就是死锁：解码线程此刻很可能正阻塞在 `frameQueue.push` 上
        //（队列满时它就在等渲染来取 —— 渲染停摆时这是常态），而它还**持着门**。
        // 这时候 freezeAndWait 会永远等下去，拖进度条就彻底没反应了。
        // 先换代 + 清空帧队列：阻塞的 push 立刻有地方可去（或直接换代放弃），
        // 解码线程得以走完这一趟、把门交出来。
        // 换代的帧本来就要作废，先清掉没有额外代价。
        frameQueue.flush()
        rifeInputQueue.flush()

        // 1. 冻结两把门：等在途解码全部结束，之后独占所有 context
        videoGate.freezeAndWait()
        audioGate.freezeAndWait()

        // 2. 清空队列与待显示帧
        videoPacketQueue.flush()
        audioPacketQueue.flush()
        frameQueue.flush()
        rifeInputQueue.flush()
        rifeReorder.discardPending()   // 在途插帧结果整体作废（seq 窗口前移，防止出口线程等死帧）
        rifeJobQueues.forEach { $0.flush() }   // 未开工的旧帧对也不再算（结果会被过期 seq 丢弃）
        rifeEngine.reset()
        flavrEngine.reset()
        CoreMLRIFEEngine.shared.reset()
        frameLock.lock(); pendingFrame = nil; lastPresentedPTS = -1; loggedFirstFrame = false; audioPrebufferDone = false; frameLock.unlock()
        anchorLock.lock(); audioAnchorPTS = nil; audioBuffersScheduled = false; anchorLock.unlock()

        // 3. 真正寻址 + 重置解码器与重采样器
        let seekRC = src.seek(to: target)
        Self.trace("seek: \(String(format: "%.3f", target))s → rc=\(seekRC) · \(src.lastSeekDescription)")
        postSeekPacketLog = 8
        videoDecoder?.reset()
        audioDecoder?.reset()
        // 字幕解码器也要清：它可能正卡着半条事件（例如 SubRip 的一个多行块）。
        subtitleDecoder?.reset()
        // 但光清解码器**不够** —— 还得把 libass 的 track 整个重建。
        //
        // 上面那句注释原来写的是「track 不需要清」，那话对了一半：
        // 对**渲染结果**而言确实不用清（libass 按时间查事件，多留的事件不会显示错），
        // 但漏了「重读会重复投递」这一半 —— 本工程的 MKV 只有第 0 帧标了 key，
        // seek 实际是「从头重读」，于是 0→target 的字幕会被再喂一次，
        // 而 track 只增不减，同一条事件就变成了两条。
        // 实测：加这一步之前，一次 seek 让事件数从 3 变 6。详见 resetTrack 的注释。
        subtitleRenderer?.resetTrack()

        // 4. 音频输出丢弃旧缓冲；时间轴锚回目标点
        audioOutput?.flush()
        // 注意：这里**不能**把 scheduledAudioEnd 预设为目标值。
        //
        // 有些容器的关键帧标记是坏的（实测的 MKV 就是：只有第 0 帧标了 key），
        // 于是 avformat 只能跳回文件开头的关键帧，真正的「跳到 5s」要靠
        // **解码并丢弃到 5s** 来完成（ffmpeg CLI 的 -ss 也是这么干的）。
        // 这种情况下解码线程会先吐出一大段 pts < target 的音频；如果这里把
        // scheduledAudioEnd 预置成 target，就会和真实音频锚点（≈0）打架，
        // throttleAudio 会误判「超前 5 秒」把音频线程永久堵死。
        // 正确做法：让 scheduledAudioEnd 从 0 起步，由真实排入的音频推进
        //（scheduleAudio 里用 minValidPTS 把 target 之前的块丢掉）。
        clock.scheduledAudioEnd = 0
        clock.reset(to: target)

        stateLock.lock(); eofReached = false; videoDrained = false; audioDrained = false
        let playing = wantPlaying; stateLock.unlock()

        // 5. 解冻。音频的 play() 由解码线程在排入第一个 buffer 后触发，
        //    避免「无 buffer 时 playerTime 空转」把时钟带飞。
        videoGate.unfreeze()
        audioGate.unfreeze()

        Self.trace(String(format: "seek: 目标 %.3fs，锚点=%d，scheduledAudioEnd=%.3f，generation=%d",
                          target, audioBuffersScheduled ? 1 : 0, clock.scheduledAudioEnd, currentGeneration()))

        if !playing { audioOutput?.pause() }

        // 新位置的时钟从头走，停摆计时也要跟着归零，
        // 否则刚 seek 完就可能被兜底判成「放完」。
        resetEOSStallWatch()

        PlaybackEngine.trace(String(
            format: "seek 完成: 足迹 %.0f MB，重排待发 %d，在途 %d",
            MemoryFootprint.currentMB(), rifeReorder.pendingCount, rifeReorder.inflight))
    }

    // MARK: - 字幕（Phase 3）

    private var subtitleRenderer: AssSubtitleRenderer? {
        get { subtitleLock.lock(); defer { subtitleLock.unlock() }; return subtitleRendererStorage }
        set { subtitleLock.lock(); defer { subtitleLock.unlock() }; subtitleRendererStorage = newValue }
    }

    // MARK: - 音轨控制（Phase 3.5）

    /// 选中一条音轨。`-1` = 静音/禁用声音。
    ///
    /// 主线程调用。真正的切换在解封装线程执行（见 `applyAudioTrackRequest`）。
    func selectAudioTrack(_ index: Int) {
        stateLock.lock(); audioTrackRequest = index; stateLock.unlock()
    }

    private func takeAudioTrackRequest() -> Int? {
        stateLock.lock(); defer { stateLock.unlock() }
        let r = audioTrackRequest
        audioTrackRequest = nil
        return r
    }

    private func applyAudioTrackRequest(_ index: Int) {
        guard let src = source else { return }

        let targetTime = clock.currentTime()

        videoGate.freezeAndWait()
        audioGate.freezeAndWait()

        let success = src.setAudioStream(index)
        stateLock.lock()
        _selectedAudioStreamIndex = success ? index : -1
        _detail = src.detail()
        stateLock.unlock()

        audioDecoder = nil
        if success, let par = src.codecParameters(at: index) {
            do {
                let dec = try AudioDecoder(parameters: par, timeBase: src.audioTimeBase)
                audioDecoder = dec
                Self.log("音轨：已切换到 #\(index)（\(dec.codecName) · \(src.audioSampleRate)Hz / \(src.audioChannels)ch）")
            } catch {
                Self.log("音轨：解码器建立失败 — \(error.localizedDescription)")
            }
        } else {
            Self.log("音轨：已关闭")
        }

        clock.hasAudio = (audioDecoder != nil && audioOutput != nil)

        stateLock.lock()
        generation &+= 1
        minValidPTS = max(0, targetTime - 0.3)
        stateLock.unlock()

        videoPacketQueue.flush()
        audioPacketQueue.flush()
        frameQueue.flush()
        rifeInputQueue.flush()
        rifeReorder.discardPending()
        rifeEngine.reset()
        flavrEngine.reset()
        CoreMLRIFEEngine.shared.reset()
        frameLock.lock(); pendingFrame = nil; frameLock.unlock()
        anchorLock.lock(); audioAnchorPTS = nil; audioBuffersScheduled = false; anchorLock.unlock()

        _ = src.seek(to: targetTime)
        videoDecoder?.reset()
        audioDecoder?.reset()
        subtitleDecoder?.reset()
        subtitleRenderer?.resetTrack()

        audioOutput?.flush()
        clock.scheduledAudioEnd = 0
        clock.reset(to: targetTime)

        stateLock.lock()
        eofReached = false
        videoDrained = false
        audioDrained = false
        stateLock.unlock()

        videoGate.unfreeze()
        audioGate.unfreeze()
    }

    /// 选中一条内封字幕轨。`-1` = 关闭字幕。
    ///
    /// 主线程调用。真正的切换在解封装线程做（见 `applySubtitleRequest`）——
    /// 这里只记下请求，因为切轨要动 `MediaFileSource` 的流索引和字幕解码器，
    /// 两者都归那个线程所有。
    func selectSubtitleTrack(_ index: Int) {
        stateLock.lock(); subtitleRequest = .internalTrack(index); stateLock.unlock()
    }

    /// 关闭字幕。关字幕也是一种「选择」，界面上要能选中它并回显勾。
    func disableSubtitles() { selectSubtitleTrack(-1) }

    /// 加载外挂字幕文件。
    func loadExternalSubtitle(url: URL) {
        stateLock.lock(); subtitleRequest = .externalFile(url); stateLock.unlock()
    }

    /// 渲染「此刻」的字幕层。**主线程**（MTKView 的 draw 回调）调用。
    ///
    /// - Returns: nil 表示画面没变，调用方继续用手里那张纹理。
    func renderSubtitle(at time: Double, width: Int, height: Int) -> SubtitleBitmap? {
        // 先取一次引用：拿到之后即使解封装线程把属性换成新实例，ARC 也保证
        // 这个本地引用指向的对象还活着（旧 renderer 的 deinit 会推迟到本次调用结束）。
        guard let renderer = subtitleRenderer else { return nil }
        return renderer.render(at: time, width: width, height: height)
    }

    /// 与 `renderSubtitle` 相同，但**无视 libass 的「没变化」**，一定合成一张出来。
    /// 只给 dev 验收用（`MP_DUMP_STATS` 的「主动」那一行），渲染循环不要用它。
    func subtitleSnapshot(at time: Double, width: Int, height: Int) -> SubtitleBitmap? {
        subtitleRenderer?.snapshot(at: time, width: width, height: height)
    }

    /// 字幕状态的一句话描述，给 `MP_DUMP_STATS` 用。
    var subtitleDebugSummary: String {
        guard let s = subtitleRenderer else {
            return externalSubtitleName.map { "外挂 \($0)（渲染器未建立）" } ?? "无字幕"
        }
        let index = selectedSubtitleStreamIndex
        let which = index >= 0 ? "内封轨 #\(index)" : (externalSubtitleName ?? "—")
        return "\(which) · \(s.debugSummary())"
    }

    // MARK: 字幕：由解封装线程执行

    private func takeSubtitleRequest() -> SubtitleRequest? {
        stateLock.lock(); defer { stateLock.unlock() }
        let r = subtitleRequest
        subtitleRequest = nil
        return r
    }

    /// 开文件时建立字幕管线。**必须在 `startThreads` 之前调用**（见 `open` 的注释）。
    private func setupSubtitlePipeline(source src: MediaFileSource) {
        subtitleDecoder?.close()
        subtitleDecoder = nil
        subtitleRenderer = nil
        setExternalSubtitleName(nil)

        let index = src.subtitleStreamIndex
        stateLock.lock(); _selectedSubtitleStreamIndex = index; stateLock.unlock()

        guard index >= 0, let par = src.codecParameters(at: index) else {
            Self.log("字幕：这个文件没有字幕轨")
            return
        }
        attachInternalTrack(index: index, parameters: par, source: src)
    }

    /// 建（或重建）内封字幕的解码器与渲染器。
    private func attachInternalTrack(index: Int,
                                     parameters: UnsafeMutablePointer<AVCodecParameters>,
                                     source src: MediaFileSource) {
        subtitleDecoder?.close()
        subtitleDecoder = nil
        subtitleRenderer = nil

        do {
            let dec = try SubtitleDecoder(parameters: parameters,
                                          timeBase: src.subtitleTimeBase,
                                          streamIndex: index)
            let fonts = src.embeddedFonts()
            let renderer = AssSubtitleRenderer(codecPrivate: Data(dec.codecPrivate),
                                               fontDirectories: [],
                                               embeddedFonts: fonts)
            subtitleDecoder = dec
            subtitleRenderer = renderer
            Self.log("字幕：已接入内封轨 #\(index)（\(dec.codecName) · "
                     + "\(dec.codecPrivate.count) 字节样式表）"
                     + (fonts.isEmpty ? "" : " · 内嵌字体 \(fonts.count) 份")
                     + (dec.isBitmapSubtitle ? " · ⚠️ 图形字幕，libass 渲染不出来" : ""))
        } catch {
            Self.log("字幕：解码器建立失败 — \(error.localizedDescription)")
        }
    }

    private func applySubtitleRequest(_ req: SubtitleRequest) {
        guard let src = source else { return }

        switch req {
        case .internalTrack(let index):
            src.setSubtitleStream(index)
            stateLock.lock(); _selectedSubtitleStreamIndex = index; stateLock.unlock()
            setExternalSubtitleName(nil)

            guard index >= 0, let par = src.codecParameters(at: index) else {
                subtitleDecoder?.close()
                subtitleDecoder = nil
                subtitleRenderer = nil
                Self.log("字幕：已关闭")
                return
            }
            attachInternalTrack(index: index, parameters: par, source: src)

            // 关键一步：让 demuxer 回到当前播放位置重读一遍。
            //
            // 为什么非做不可：demuxer 的读位置**领先于**播放位置（队列在预读）。
            // 不回头的话，新轨的第一批字幕包都是「未来」的 —— 字幕会提前跳出来；
            // 而此刻正在显示的那条（它的包早就读过去了）则再也不会出现。
            // 代价是视频/音频也跟着重新对齐一次，与用户手拖进度条走的是同一条路径
            //（已有实测 rc=0），值这个代 cost。
            applySeek(currentTime)

        case .externalFile(let url):
            loadExternalSubtitleNow(url, source: src)
        }
    }

    private func loadExternalSubtitleNow(_ url: URL, source src: MediaFileSource) {
        guard let raw = try? Data(contentsOf: url) else {
            Self.log("字幕：读不到外挂文件 \(url.path)")
            return
        }
        guard let assBytes = SubtitleFormat.toASS(data: raw, path: url.path),
              let script = String(bytes: assBytes, encoding: .utf8) else {
            Self.log("字幕：外挂格式不支持或解析失败 — \(url.lastPathComponent)")
            return
        }

        let renderer = AssSubtitleRenderer(script: script,
                                           fontDirectories: [],
                                           embeddedFonts: src.embeddedFonts())
        guard renderer.isAvailable else {
            Self.log("字幕：外挂渲染器建立失败")
            return
        }
        // 外挂 track 自带全部事件，不需要 seek 重读包 —— 直接换掉渲染器即可。
        // 但要把内封解码器停掉，否则后续字幕包会继续往已经被丢弃的旧 track 里灌。
        subtitleDecoder?.close()
        subtitleDecoder = nil
        subtitleRenderer = renderer
        setExternalSubtitleName(url.lastPathComponent)
        stateLock.lock(); _selectedSubtitleStreamIndex = -1; stateLock.unlock()
        Self.log("字幕：已加载外挂 \(url.lastPathComponent) — \(renderer.debugSummary())")
    }

    /// 解一个字幕包并喂给 libass。解封装线程调用。
    private func ingestSubtitlePacket(_ packet: UnsafeMutablePointer<AVPacket>,
                                      source src: MediaFileSource) {
        guard let dec = subtitleDecoder else { return }
        let events = dec.decode(packet: packet)
        guard !events.isEmpty, let renderer = subtitleRenderer else { return }
        for event in events {
            // 时长必须 > 0，否则 libass 建出来的是「零时长事件」= 永不渲染。
            // 这条 trace 就是为盯住它留的（内封 ASS 的时长只能从包上取，
            // 而包时长缺失时这里是唯一的报警点）。
            if event.duration <= 0 {
                Self.log("字幕：事件时长 <= 0（\(event.start)s）—— libass 不会渲染这条")
            }
            renderer.processASSChunk(
                data: Data(event.line.utf8),
                startMs: Int64((event.start * 1000).rounded()),
                durationMs: Int64((max(event.duration, 0) * 1000).rounded()))
        }
    }

    // MARK: 外挂字幕名（跨线程，用 subtitleLock 保护）

    private var _externalSubtitleName: String?

    var externalSubtitleName: String? {
        subtitleLock.lock(); defer { subtitleLock.unlock() }
        return _externalSubtitleName
    }

    private func setExternalSubtitleName(_ name: String?) {
        subtitleLock.lock(); defer { subtitleLock.unlock() }
        _externalSubtitleName = name
    }

    // MARK: - 状态同步

    private func setState(_ new: PlaybackState) {
        stateLock.lock()
        if _state == new { stateLock.unlock(); return }
        Self.log("状态变迁: \(_state) -> \(new)")
        _state = new
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.playbackEngine(self, didChange: new)
        }
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        delegate?.playbackEngine(self, didUpdateTime: currentTime, duration: duration)
        applyScriptedSeekIfRequested()
        applyScriptedSeekLoopIfRequested()
        memoryTraceIfEnabled()
        checkEndOfStream()
        audioWatchdog()
        applyEOSReplaySelfTestIfRequested()
        traceIfEnabled()
    }

    /// dev-only：`MP_MEMSEC=5` 每 5 秒打一行足迹 + 池遥测。
    ///
    /// 独立于 RIFE60 那行：那条是「每 200 个调度项」触发，seek 风暴期间调度
    /// 项会停摆，恰恰最需要看内存的时候它不打了。内存排查要的是稳定节拍。
    private var memTraceLast: TimeInterval = 0
    private func memoryTraceIfEnabled() {
        guard let raw = ProcessInfo.processInfo.environment["MP_MEMSEC"],
              let secs = Double(raw), secs > 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if memTraceLast == 0 { memTraceLast = now; return }
        guard now - memTraceLast >= secs else { return }
        memTraceLast = now
        // 「已上屏」是这个采样行里最重要的一列：MTKView 的 draw 由显示链路驱动，
        // 窗口被遮挡 / 屏幕休眠时它会直接停摆，而主线程照活 —— 于是视频包队列
        // 满、帧队列满、插帧计数冻结，看上去像「内存泄漏 → 卡死」，实际是
        // **没人拉帧**。没有这一列就只能靠猜（这条就是这么来的）。
        statsLock.lock(); let presented = presentedFrames; statsLock.unlock()
        NSLog("[MEM] 足迹 %.0f MB | RSS %.0f MB | 压缩 %.0f MB | 帧队列 %d 视频包 %d"
              + " | 上屏 %d 插帧 %d | %@",
              MemoryFootprint.currentMB(), MemoryFootprint.residentMB(),
              MemoryFootprint.compressedMB(),
              frameQueue.count, videoPacketQueue.count,
              presented, CoreMLRIFEEngine.shared.totalInterpolatedFrames,
              CoreMLRIFEEngine.shared.poolStatsText())
    }

    /// dev-only：`MP_SEEK_LOOP=2` 每 2 秒跳一次（目标在全片里来回跳）。
    ///
    /// 为什么需要它：用户报「拖多几次进度条或者放久了会卡死」，而脚本化入口
    /// MP_SEEK_TEST 只跳一次 —— 一次看不出累积效应。这是复现「拖进度条风暴」
    /// 的可重复手段，配合 MP_MEMSEC 就能把内存曲线和 seek 次数对上。
    private var seekLoopLast: TimeInterval = 0
    private var seekLoopIndex = 0
    private func applyScriptedSeekLoopIfRequested() {
        guard let raw = ProcessInfo.processInfo.environment["MP_SEEK_LOOP"],
              let interval = Double(raw), interval > 0 else { return }
        guard state == .playing, duration > 5 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if seekLoopLast == 0 { seekLoopLast = now; return }
        guard now - seekLoopLast >= interval else { return }
        seekLoopLast = now
        let span = max(1.0, duration - 4.0)
        let bases: [Double] = [0.12, 0.35, 0.62, 0.28, 0.8, 0.45, 0.05, 0.7]
        let frac = bases[seekLoopIndex % bases.count]
        seekLoopIndex += 1
        let target = min(max(1.0, span * frac), span)
        Self.log("dev: 循环跳转 #\(seekLoopIndex) → \(String(format: "%.1f", target))s")
        seek(to: target)
    }

    /// dev-only：`MP_SEEK_TEST=5` 时，在播放 1.5 秒后自动跳到第 5 秒一次。
    ///
    /// 为什么要这个开关：seek 是整条链路上唯一需要「冻结管线 → 动三个 context
    /// → 重建音频锚点」的操作，也是最容易写坏的一处（竞态、代际号、时钟锚点）。
    /// 光靠手拖进度条没法复现，留个可复现的入口。
    private func applyScriptedSeekIfRequested() {
        guard !scriptedSeekDone else { return }
        guard state == .playing, currentTime > 1.5 else { return }
        guard let raw = ProcessInfo.processInfo.environment["MP_SEEK_TEST"],
              let target = Double(raw), target > 0 else {
            scriptedSeekDone = true
            return
        }
        scriptedSeekDone = true
        Self.log("dev: 脚本化跳转到 \(target)s")
        seek(to: target)
    }

    /// dev-only：`MP_EOS_TEST=1` 端到端自检「放完之后还能不能再播一次」。
    ///
    /// 为什么要它：用户报「每次放完影片都会卡住，拉进度条拉不了，也不能点击
    /// 播放再放一次」。这三件事其实是同一个状态机死路，光看代码容易只修一半。
    /// 脚本化跑一遍才能证明「放完 → 点播放 → 真的从头动了」。
    ///
    /// 三个阶段的判定：
    ///   A 等片尾：state 变成 .ended，记下已上屏帧数
    ///   B 静置 2s：上屏帧数**不再增长**（证明确实停住了，这是症状本身）
    ///   C 调 play() 再等 4s：上屏帧数重新增长，且时钟回到片头附近
    /// C 通过才算修复；任一阶段不成立会打出 FAIL 与当时的读数。
    private var eosTestStage = 0
    private var eosTestAt: TimeInterval = 0
    private var eosTestFrames = 0
    private func applyEOSReplaySelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["MP_EOS_TEST"] != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // 用**解码**帧数而不是上屏帧数：本自检常在「窗口不可见」的无人值守
        // 环境下跑，MTKView 不绘制，上屏恒为 0，看不出管线到底动没动。
        // 解码帧数只反映解码线程有没有在推数据，不受渲染影响。
        statsLock.lock(); let decoded = decodedVideoFrames; statsLock.unlock()

        switch eosTestStage {
        case 0:  // A 等片尾
            guard state == .ended else { return }
            eosTestStage = 1; eosTestAt = now
            Self.log("[EOS自检] A 已到片尾（已解码 \(decoded) 帧），静置 2s")

        case 1:  // B 结束态直接拖进度条 —— 用户报的第一个症状
            guard now - eosTestAt >= 2 else { return }
            eosTestStage = 2; eosTestAt = now
            eosTestSeekTarget = duration * 0.3
            seek(to: eosTestSeekTarget)
            Self.log(String(format: "[EOS自检] B 结束态拖到 %.2fs，等 3s 看跟不跟得到",
                            eosTestSeekTarget))
        case 2:
            guard now - eosTestAt >= 3 else { return }
            let arrived = abs(currentTime - eosTestSeekTarget) < 1.5
            Self.log("[EOS自检] 拖动结果：\(arrived ? "PASS" : "FAIL")"
                     + String(format: " — 目标 %.2fs，实际 %.2fs，状态 %@",
                              eosTestSeekTarget, currentTime, String(describing: state)))
            // C 点播放重播 —— 用户报的第二个症状
            eosTestStage = 3; eosTestAt = now; eosTestFrames = decoded
            play()
            Self.log("[EOS自检] C 已调用 play()，等 4s 看是否真的从头重播")
        case 3:
            guard now - eosTestAt >= 4 else { return }
            let grew = decoded > eosTestFrames + 5
            let rewound = currentTime < max(1.0, duration * 0.8)
            Self.log("[EOS自检] 重播结果：\(grew && rewound ? "PASS" : "FAIL")"
                     + " — 已解码 \(eosTestFrames) → \(decoded)"
                     + String(format: "，时钟 %.2fs / 全长 %.2fs，状态 %@",
                              currentTime, duration, String(describing: state)))
            eosTestStage = 4
        default:
            break
        }
    }
    private var eosTestSeekTarget: Double = 0

    /// dev-only 管线追踪：`MP_TRACE=1` 打开，每秒打一行。
    ///
    /// 播放器的问题几乎都是「某一环卡住了」，而单看状态机看不出来是哪一环。
    /// 把三条件队列长度 + 音频已排队时间 + 末帧 pts 一次打出来，
    /// 卡在哪一眼就能定位（这是被「只上屏首帧」折腾过一次之后的教训）。
    private func traceIfEnabled() {
        guard Self.traceEnabled else { return }
        frameLock.lock()
        let pendingPTS = pendingFrame?.pts ?? -1
        let lastPTS = lastPresentedPTS
        frameLock.unlock()

        Self.log(String(format:
            "t=%.2f | 帧队列 %d(待显示 %.2f) | 视频包 %d | 音频包 %d | 音频排到 %.2f | 末帧 %.2f | 音频输出 %@ | EOF %@ 冲刷 v/a=%@/%@ | %@",
            currentTime,
            frameQueue.count, pendingPTS,
            videoPacketQueue.count,
            audioPacketQueue.count,
            clock.scheduledAudioEnd,
            lastPTS,
            audioOutput == nil ? "无" : "有",
            isEOF ? "是" : "否",
            isVideoDrained ? "是" : "否", isAudioDrained ? "是" : "否",
            String(describing: state)))
    }

    private static let traceEnabled =
        DevFlag.on("MP_TRACE", "--trace")

    /// 只在 MP_TRACE=1 时输出的追踪行（dev-only）。
    static func trace(_ message: String) {
        guard traceEnabled else { return }
        log(message)
    }

    /// 上屏计数与「上次看到它在涨」的时刻，用于识别渲染停摆（见 checkEndOfStream）。
    private var eosStallFrames = -1
    private var eosStallSince: TimeInterval = 0

    private func resetEOSStallWatch() {
        eosStallFrames = -1
        eosStallSince = 0
    }

    private func checkEndOfStream() {
        guard state == .playing else { return }
        // 必须等「读完了 + 解码线程把自己的队列消费完并冲刷了」才算放完。
        // 只看 eofReached 会得出「文件才读了一半就播完了」的错误结论。
        guard isEOF else { resetEOSStallWatch(); return }

        // ── 渲染停摆兜底 ──────────────────────────────────────────────
        //
        // 正常判定链的最后一步是「渲染线程把帧队列拉空」，而这一步发生在
        // MTKView 的 draw 里。窗口被遮挡 / 最小化 / 屏幕休眠 / 显示链路停摆时
        // draw 根本不来，于是：
        //     帧队列满 → 解码线程阻塞在 push → 拿不到 .endOfStream
        //     → videoDrained 永远 false → 状态机永远停在 playing
        // 用户看到的就是「放完影片就卡住」，而且因为队列是满的，连 seek 都拖不动
        //（applySeek 的 freezeAndWait 会等死在持门的解码线程上）。
        //
        // 判据取两个条件的**合取**，缺一不可，避免误杀正常播放：
        //   1. 时钟已经走到片尾（声音/墙钟都到头了，没内容可放了）
        //   2. 上屏计数连续 2.5s 没再变（确实没人在拉帧）
        statsLock.lock(); let presentedNow = presentedFrames; statsLock.unlock()
        let wall = Date().timeIntervalSinceReferenceDate
        if presentedNow != eosStallFrames {
            eosStallFrames = presentedNow
            eosStallSince = wall
        }
        let timeDone = duration <= 0 || currentTime >= duration - 0.5
        if timeDone, eosStallSince > 0, wall - eosStallSince >= 2.5 {
            Self.log("结束判定（渲染停摆兜底）：上屏停在 \(presentedNow) 帧已达 "
                     + String(format: "%.1fs，时钟 %.2f/%.2f — 按放完处理",
                              wall - eosStallSince, currentTime, duration))
            finishPlayback()
            return
        }

        if hasVideo && !isVideoDrained { return }
        if hasAudio && !isAudioDrained { return }
        // RIFE worker 可能还压着几对源帧没推理完 —— 不等它就会提前结束
        guard rifeInputQueue.isEmpty else { return }
        guard frameQueue.isEmpty else { return }
        Self.log("checkEndOfStream 命中：eof=\(isEOF) 视频排空=\(isVideoDrained) 音频排空=\(isAudioDrained)"
                 + " 帧队列=\(frameQueue.count) 在途=\(rifeReorder.inflight) 输入=\(rifeInputQueue.count)")
        frameLock.lock()
        let pending = pendingFrame
        frameLock.unlock()
        guard pending == nil else { return }
        guard lastPresentedPTS >= 0 else { return }

        // 时钟追上了最后一帧，并且音频也放完了。
        //
        // 这里不能写成「currentTime > 末帧 + 0.3」——音频时钟被
        // AVSyncClock 夹在「已排队音频的末端」上（underrun 保护），
        // 播到结尾时它恰好停在 scheduledAudioEnd，往前挪不动，
        // 于是永远差那么零点几秒。判断"放完"要看两个终点的**汇合**：
        //   画面终点 = 最后一帧 pts
        //   声音终点 = 已排队音频末端
        let pictureDone = currentTime >= lastPresentedPTS - 0.02
        let audioDone = !hasAudio || currentTime >= clock.scheduledAudioEnd - 0.05
        guard pictureDone, audioDone else { return }

        // 片子放完了
        frameLock.lock(); let endPTS = lastPresentedPTS; frameLock.unlock()
        finishPlayback(endPTS: endPTS)
    }

    /// 收尾动作：停音频、停时钟、清帧队列、切 .ended。
    ///
    /// 「清帧队列」这一步不能省：停摆路径下队列是**满的**，而解码线程正
    /// 阻塞在它的 push 上。不清掉，下一次 applySeek 的 freezeAndWait 就
    /// 等不到这趟解码结束（用户侧表现为「进度条彻底拖不动」）。
    private func finishPlayback(endPTS: Double? = nil) {
        stateLock.lock(); wantPlaying = false; stateLock.unlock()
        audioOutput?.pause()
        clock.pause()
        frameQueue.flush()
        frameLock.lock(); pendingFrame = nil; frameLock.unlock()
        resetEOSStallWatch()
        if let pts = endPTS {
            Self.log("播放结束，末帧 \(String(format: "%.3f", pts))s / 时长 \(String(format: "%.3f", duration))s")
        }
        setState(.ended)
    }

    /// 音轨存在但迟迟没有任何 PCM 排进播放器（不支持的编码、解码器异常等）：
    /// 3 秒后放弃音频时钟，改走墙上时钟，别把画面一起冻住。
    private func audioWatchdog() {
        guard clock.hasAudio, state == .playing else {
            audioStallWatchdogStart = 0
            return
        }
        if clock.scheduledAudioEnd > 0.05 {
            audioStallWatchdogStart = 0
            return
        }
        if audioStallWatchdogStart == 0 {
            audioStallWatchdogStart = Date().timeIntervalSinceReferenceDate
            return
        }
        if Date().timeIntervalSinceReferenceDate - audioStallWatchdogStart > 3 {
            clock.hasAudio = false
            audioStallWatchdogStart = 0
        }
    }

    // MARK: - 小工具

    private var isStopping: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopRequested
    }

    private var isEOF: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return eofReached
    }

    private var isVideoDrained: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return videoDrained
    }

    private var isAudioDrained: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return audioDrained
    }

    private var isWantPlaying: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return wantPlaying
    }

    private func currentGeneration() -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return generation
    }

    private var currentMinValidPTS: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return minValidPTS
    }

    private func takeSeekRequest() -> Double? {
        stateLock.lock(); defer { stateLock.unlock() }
        let v = seekRequested
        seekRequested = nil
        return v
    }

    // MARK: - 性能监看快照（Phase 2 增补）

    /// 给 Tab 监看面板用的一次性读数。
    ///
    /// 主线程调用；内部只做「锁一下取几个数」，不做任何可能阻塞的事
    /// （比如不去 wait 队列，只读它们的 `count`）。
    func snapshotCounters() -> PlaybackCounters {
        var c = PlaybackCounters()

        statsLock.lock()
        c.decodedVideoFrames = decodedVideoFrames
        c.presentedFrames = presentedFrames
        c.droppedFrames = droppedFrames
        statsLock.unlock()

        c.queues.videoPacket = videoPacketQueue.count
        c.queues.videoPacketCapacity = 200
        c.queues.audioPacket = audioPacketQueue.count
        c.queues.audioPacketCapacity = 600
        c.queues.frame = frameQueue.count
        c.queues.frameCapacity = 64

        let s = PlaybackSettings.shared
        c.rifeActive = s.rifeRateMode != .off
        if s.rifeModel.isFLAVR {
            c.rifeInterpolatedFrames = flavrEngine.totalInterpolatedFrames
            c.rifeStatusText = flavrEngine.activeStateText
        } else if CoreMLRIFEEngine.shared.totalInterpolatedFrames > 0 || !CoreMLRIFEEngine.shared.activeStateText.contains("加载") {
            c.rifeInterpolatedFrames = CoreMLRIFEEngine.shared.totalInterpolatedFrames
            c.rifeStatusText = CoreMLRIFEEngine.shared.activeStateText
        } else {
            c.rifeInterpolatedFrames = rifeEngine.totalInterpolatedFrames
            c.rifeStatusText = rifeEngine.activeStateText
        }
        c.metalFXActive = (s.metalFX != .off)
        c.metalFXStatusText = (s.metalFX == .spatial) ? "MetalFX 空间上采样 (已启用)" : "MetalFX 关闭"
        c.anime4kActive = (s.anime4k == .on)
        c.anime4kStatusText = (s.anime4k == .on) ? "Anime4K 开启 (\(s.anime4kPresetID.shortTitle))" : "Anime4K 关闭"

        c.audioScheduledEnd = clock.scheduledAudioEnd
        frameLock.lock()
        c.lastPresentedPTS = lastPresentedPTS
        frameLock.unlock()
        c.currentTime = clock.currentTime()
        c.isPlaying = isPlaying
        c.usesAudioClock = clock.hasAudio
        switch state {
        case .idle:                c.stateText = "空闲"
        case .opening:             c.stateText = "打开中"
        case .playing:             c.stateText = "播放中"
        case .paused:              c.stateText = "已暂停"
        case .ended:               c.stateText = "播放结束"
        case .failed(let message): c.stateText = "失败 — \(message)"
        }
        c.isHardwareDecode = videoDecoder?.isHardwareAccelerated ?? false
        c.videoDecoderName = videoDecoder?.codecName ?? ""
        c.captureDeliveredFPS = captureDeliveredFPS
        c.captureColorInfo = captureColorInfo
        return c
    }

    private func noteDecodedFrames(_ count: Int) {
        guard count > 0 else { return }
        statsLock.lock(); decodedVideoFrames += count; statsLock.unlock()
    }

    private func notePresentedFrame() {
        statsLock.lock(); presentedFrames += 1; statsLock.unlock()
    }

    private func noteDroppedFrame(count: Int) {
        guard count > 0 else { return }
        statsLock.lock(); droppedFrames += count; statsLock.unlock()
    }

    private func resetStats() {
        statsLock.lock()
        decodedVideoFrames = 0
        presentedFrames = 0
        droppedFrames = 0
        statsLock.unlock()
        // 上屏计数归零了，停摆看门狗也得跟着重置，
        // 否则它会拿旧计数当基准，把新的一次开播误判成「早就停了」。
        resetEOSStallWatch()
    }

    // MARK: - 采集卡输入
    /// 只接受设备明确支持的精确帧时长。
    ///
    /// 给 `activeVideoMin/MaxFrameDuration` 传不支持的值，CoreMediaIO 会抛
    /// NSInvalidArgumentException —— Swift 抓不到 ObjC 异常，结果是 SIGABRT 闪退。
    /// 所以设置前必须先拿 activeFormat 的 supported ranges 对一遍。
    private static func isFrameDurationSupported(_ dur: CMTime, by format: AVCaptureDevice.Format) -> Bool {
        format.videoSupportedFrameRateRanges.contains {
            CMTimeCompare($0.minFrameDuration, dur) == 0 || CMTimeCompare($0.maxFrameDuration, dur) == 0
        }
    }

    /// 把 CMTime 帧时长读成「xx.xx fps」便于日志核对。
    private static func fpsText(_ t: CMTime) -> String {
        guard t.isValid, t.value > 0, t.timescale > 0 else { return "无效" }
        return String(format: "%.2f fps", Double(t.timescale) / Double(t.value))
    }

    /// 在 `startRunning()` **之后**把帧时长落到设备与输出连接上，并**读回核对**。
    ///
    /// 与 `applyVideoOutputConnectionFrameRate` 对应：真正决定出帧节奏的是
    /// 输出连接的 `videoMin/MaxFrameDuration`，设备属性只是它的一半。
    /// 只写设备属性、且写在启动之前，驱动会在启动时静默覆盖回自己的默认值。
    private func applyCaptureFrameRate(reason: String, device: AVCaptureDevice,
                                       connection: AVCaptureConnection?) {
        guard let dur = pendingCaptureFrameDuration else {
            Self.log("采集卡帧率: 面板未指定（沿用设备默认，目标 \(Int(pendingCaptureFPS)) FPS）")
            return
        }

        // 1) 设备属性（写前先校验，挡掉驱动抛出的 ObjC 异常 —— Swift catch 不到，会直接 SIGABRT）
        do {
            try device.lockForConfiguration()
            if Self.isFrameDurationSupported(dur, by: device.activeFormat) {
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
            } else {
                Self.log("采集卡帧率: \(dur.value)/\(dur.timescale) 不在当前规格支持范围，跳过设备侧写入")
            }
            device.unlockForConfiguration()
        } catch {
            Self.log("采集卡帧率: 设备侧写入失败 \(error)")
        }

        // 2) 输出连接属性（这一步才是真正生效的那一下）
        if let c = connection {
            if c.isVideoMinFrameDurationSupported { c.videoMinFrameDuration = dur }
            if c.isVideoMaxFrameDurationSupported { c.videoMaxFrameDuration = dur }
        }

        // 3) 读回核对：把真实落地的值打出来，而不是只打「我设置了什么」
        let devDur = device.activeVideoMinFrameDuration
        let connDur = connection?.videoMinFrameDuration ?? .invalid
        Self.log(String(format: "采集卡帧率已锁定(%@): 目标 %.2f fps | 设备读回 %@ | 连接读回 %@",
                        reason, pendingCaptureFPS, Self.fpsText(devDur), Self.fpsText(connDur)))
    }

    func openCapture(videoDevice: AVCaptureDevice, audioDevice: AVCaptureDevice?,
                     format: AVCaptureDevice.Format?, fps: Double, frameDuration: CMTime?) throws {
        shutdownPipeline()

        stateLock.lock()
        stopRequested = false
        seekRequested = nil
        wantPlaying = true
        eofReached = false
        videoDrained = false
        audioDrained = false
        generation &+= 1
        minValidPTS = 0
        _state = .playing
        isCaptureMode = true
        captureFPS = fps > 0 ? fps : 60.0
        stateLock.unlock()

        frameQueue.reopen()
        rifeInputQueue.reopen()
        rifeJobQueues.forEach { $0.reopen() }
        rifeReorder.reopen()
        frameLock.lock()
        pendingFrame = nil
        lastPresentedPTS = -1
        loggedFirstFrame = false
        audioPrebufferDone = false
        captureStartPTS = nil
        actualCaptureFPS = 0
        captureSampleCount = 0
        lastCaptureSampleHostTime = 0
        captureRateWarned = false
        captureColorDescription = "—"
        packed422SkipWarned = false
        frameLock.unlock()
        CadenceDetector.shared.reset()   // 新采集会话：清空假 60 帧 FSM 状态，重新识别
        resetStats()
        clock.reset(to: 0)
        clock.start()

        let session = AVCaptureSession()
        session.beginConfiguration()

        let vInput = try AVCaptureDeviceInput(device: videoDevice)
        if session.canAddInput(vInput) {
            session.addInput(vInput)
        }

        do {
            try videoDevice.lockForConfiguration()
            if let f = format {
                videoDevice.activeFormat = f
            }
            videoDevice.unlockForConfiguration()
        } catch {
            Self.log("配置采集设备 activeFormat 失败: \(error)")
        }

        // 帧时长的应用**不能只做在这里** —— 见下方 startRunning() 之后的说明。
        // 这里先把请求值记下来，启动后再真正落地。
        self.pendingCaptureFrameDuration = frameDuration
        self.pendingCaptureFPS = fps > 0 ? fps : 60.0
        self.captureFPS = fps > 0 ? fps : 60.0

        let vOutput = AVCaptureVideoDataOutput()
        vOutput.alwaysDiscardsLateVideoFrames = true

        // 请求的像素格式 = 所选规格的**原生子类型**，不额外要求驱动做转换。
        //
        // 两个理由：
        //   1. 范围：若设备原生是 420f（全范围）却请求 420v，驱动会把 0–255 压进
        //      16–235，8 位精度白丢约 14%，我们再在着色器里用 255/219 展开，
        //      把量化误差放大成色带。跟随原生格式即可让这条转换链消失。
        //   2. 色度采样率：采集卡的 4:2:2（yuvs）色度不横向减半，而 420v 是 4:2:0
        //      横竖都减半。同一路 HDMI 下 4:2:2 的彩色细节明显更实 ——
        //      强行把 4:2:2 转成 4:2:0 是纯粹的信息损失（OBS 也是直接用原生格式）。
        let nativeSubType: OSType = format.map {
            CMFormatDescriptionGetMediaSubType($0.formatDescription)
        } ?? CMFormatDescriptionGetMediaSubType(videoDevice.activeFormat.formatDescription)
        let requestedPixelFormat: OSType
        switch nativeSubType {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr8_yuvs:
            requestedPixelFormat = nativeSubType
        default:
            requestedPixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        vOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(requestedPixelFormat)
        ]
        let captureQueue = DispatchQueue(label: "com.macrife.capture.video", qos: .userInteractive)
        let outputDelegate = CaptureOutputDelegate(engine: self)
        self.captureOutputDelegate = outputDelegate
        vOutput.setSampleBufferDelegate(outputDelegate, queue: captureQueue)
        if session.canAddOutput(vOutput) {
            session.addOutput(vOutput)
        }

        if let aDev = audioDevice {
            if let aInput = try? AVCaptureDeviceInput(device: aDev), session.canAddInput(aInput) {
                session.addInput(aInput)
                let previewOutput = AVCaptureAudioPreviewOutput()
                previewOutput.volume = storedVolume
                if session.canAddOutput(previewOutput) {
                    session.addOutput(previewOutput)
                    self.captureAudioPreviewOutput = previewOutput
                }
            }
        }

        session.commitConfiguration()
        session.startRunning()
        self.captureSession = session

        // ── 帧率必须在 startRunning() **之后**落地 ──────────────────────────
        //
        // 实测（本机 USB3 Video / UltraSemi UVC 卡）：
        //   设备默认帧率 = 1000000/20000000 = 20 fps
        //   启动前写 activeVideoMin/MaxFrameDuration → 读回 60（看着成功）
        //   session.startRunning() → 静默重置回 20 fps
        //   启动后再写（设备 + 输出连接）→ 稳定保持 60
        //
        // 这就是「面板写 60、实际只有 20」的根因：驱动在启动时会用自身默认值
        // 覆盖设备属性，只有启动后重新写入才生效。原版 MetalPlayer 同样在
        // start 之后靠 repairFrameRateAfterStartIfNeeded 兜这一下。
        self.applyCaptureFrameRate(reason: "启动后修复", device: videoDevice,
                                   connection: vOutput.connection(with: .video))

        let dim = CMVideoFormatDescriptionGetDimensions(videoDevice.activeFormat.formatDescription)
        let w = CGFloat(dim.width > 0 ? dim.width : 1920)
        let h = CGFloat(dim.height > 0 ? dim.height : 1080)
        self.videoSize = CGSize(width: w, height: h)
        self.duration = 0
        self.url = nil

        var vTrack = VideoStreamDetail()
        vTrack.width = Int(w)
        vTrack.height = Int(h)
        vTrack.frameRate = captureFPS
        vTrack.codec = "HDMI 采集"
        vTrack.pixelFormat = "nv12"

        var container = ContainerDetail()
        container.formatName = "采集卡直通"
        container.fileName = videoDevice.localizedName

        var detail = MediaDetail()
        detail.container = container
        detail.video = vTrack
        stateLock.lock()
        self._detail = detail
        stateLock.unlock()

        self.sourceInfo = "采集卡: \(videoDevice.localizedName) · \(Int(w))x\(Int(h)) @ \(Int(captureFPS)) FPS"

        DispatchQueue.main.async { [weak self] in
            self?.startTicker()
        }
    }

    func handleCaptureSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isCaptureMode, !isStopping, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let cmPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let now = clock.currentTime()

        measureActualCaptureRate(sampleBuffer)

        let basePTS: Double
        if let existing = captureStartPTS {
            basePTS = existing
        } else {
            let start = (cmPTS.isFinite && cmPTS > 0) ? cmPTS : 0.0
            captureStartPTS = start
            basePTS = start
            clock.reset(to: 0)
            clock.start()
        }

        let pts = (cmPTS.isFinite && cmPTS >= basePTS) ? (cmPTS - basePTS) : now
        // 色彩**实测**，不再写死。原版对应 VideoColorInfo.resolvedSDR(for:fullRange:is10Bit:)。
        let color = Self.resolveCaptureColor(sampleBuffer: sampleBuffer, buffer: imageBuffer)
        frameLock.lock()
        let colorChanged = (color.description != captureColorDescription)
        if colorChanged { captureColorDescription = color.description }
        frameLock.unlock()
        if colorChanged { Self.log("采集色彩: \(color.description)") }
        let frame = DecodedVideoFrame(
            pixelBuffer: imageBuffer,
            pts: pts,
            isBT709: color.code != 0,
            colorSpaceCode: color.code,
            isFullRange: color.isFullRange,
            isInterpolated: false
        )
        enqueueFrame(frame)
    }

    /// 用相邻样本的**主机时钟**间隔算实测投递帧率，并在与请求值差距过大时告警。
    ///
    /// 为什么要单独测：设备属性、连接属性都可以「设置成功、读回正确」，
    /// 而实际出帧仍然只有目标的三分之一 —— 本机 USB3 Video 卡就踩过这条
    ///（默认 20 fps，启动时把 60 覆盖掉）。只信配置值等于放弃诊断能力。
    private func measureActualCaptureRate(_ sampleBuffer: CMSampleBuffer) {
        let host = CACurrentMediaTime()
        defer { lastCaptureSampleHostTime = host }

        captureSampleCount += 1
        guard lastCaptureSampleHostTime > 0 else { return }
        let dt = host - lastCaptureSampleHostTime
        // 丢弃异常间隔（首次 / 断流恢复 / 长暂停），避免把 EMA 带偏
        guard dt > 0.0005, dt < 0.5 else { return }

        let instant = 1.0 / dt
        frameLock.lock()
        actualCaptureFPS = actualCaptureFPS > 0
            ? actualCaptureFPS * 0.9 + instant * 0.1   // EMA，抗抖动
            : instant
        let measured = actualCaptureFPS
        let shouldWarn = !captureRateWarned && captureSampleCount > 30
            && pendingCaptureFPS > 0 && measured < pendingCaptureFPS * 0.85
        if shouldWarn { captureRateWarned = true }
        frameLock.unlock()

        if shouldWarn {
            Self.log(String(format: "⚠️ 采集帧率不符：请求 %.0f fps，实测仅 %.1f fps（驱动可能在启动后重置了帧时长）",
                            pendingCaptureFPS, measured))
        }
    }

    /// 面板只读：采集卡**实测**投递帧率（0 = 尚未测出）。
    var captureDeliveredFPS: Double {
        frameLock.lock(); defer { frameLock.unlock() }
        return actualCaptureFPS
    }

    /// 面板只读：本次采集解析出的色彩信息（矩阵 / 范围 / 来源）。
    var captureColorInfo: String {
        frameLock.lock(); defer { frameLock.unlock() }
        return captureColorDescription
    }

    /// 打包 4:2:2 + 补帧的组合只提示一次。
    /// 每帧都打会淹掉日志（60 次/秒），而这件事只需被告知一次。
    private var packed422SkipWarned = false
    private func notePacked422InterpolationSkipOnce() {
        frameLock.lock()
        let first = !packed422SkipWarned
        packed422SkipWarned = true
        frameLock.unlock()
        guard first else { return }
        Self.log("⚠️ 当前采集格式是打包 4:2:2（YUY2），补帧链路只支持双平面 NV12 —— 本次已自动降级为直通上屏。"
                 + "需要补帧请在采集面板把分辨率切成 NV12 规格。")
    }

    /// 从样本缓冲**实测**解析色彩信息，而不是沿用写死的 BT.709 / 限制范围。
    ///
    /// 读取顺序（先具体后笼统）：
    ///   1. 像素缓冲的附件（kCVImageBufferYCbCrMatrixKey 等）—— 最可靠
    ///   2. 格式描述扩展（YCbCrMatrix / ColorPrimaries / FullRangeVideo）
    ///   3. 像素格式类型本身：420f = 全范围，420v = 限制范围
    /// 最后套用面板上的「自动 / 手动」覆盖档。
    private static func resolveCaptureColor(sampleBuffer: CMSampleBuffer, buffer: CVBuffer)
        -> (code: Int32, isFullRange: Bool, description: String) {

        var matrixCode: Int32?
        var range: Bool?
        var source = "默认"

        // 3) 像素格式类型是最硬的证据：420f/420f10 必为全范围，420v/420v10 必为限制范围
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        switch fmt {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            range = true; source = "像素格式 \(Self.fourCC(fmt))"
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            range = false; source = "像素格式 \(Self.fourCC(fmt))"
        default:
            break
        }

        // 1) 像素缓冲附件
        if let v = CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)?.takeUnretainedValue() {
            matrixCode = Self.matrixCode(from: v as? String)
            source = "缓冲附件"
        }
        if let v = CVBufferGetAttachment(buffer, kCVImageBufferColorPrimariesKey, nil)?.takeUnretainedValue() {
            _ = v
        }

        // 2) 格式描述扩展
        if let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
            if matrixCode == nil, let m = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String {
                matrixCode = Self.matrixCode(from: m)
                source = "格式扩展"
            }
            if let full = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool, range == nil {
                range = full
                source = "格式扩展"
            }
        }

        // 面板覆盖档优先
        let settings = PlaybackSettings.shared
        var overridden: [String] = []
        if let forced = settings.captureColorRange.forcedFullRange {
            if range != forced { overridden.append("范围") }
            range = forced
        }
        if let forced = settings.captureColorMatrix.shaderCode {
            if matrixCode != forced { overridden.append("矩阵") }
            matrixCode = forced
        }

        let code = matrixCode ?? 1
        let isFull = range ?? false
        let matrixName = code == 2 ? "BT.2020" : (code == 1 ? "BT.709" : "BT.601")
        let rangeName = isFull ? "全范围 0–255" : "限制 16–235"
        var text = "\(matrixName) · \(rangeName) · 来源=\(source)"
        if !overridden.isEmpty { text += " · 已被面板覆盖(\(overridden.joined(separator: "/")))" }
        return (code, isFull, text)
    }

    /// Adobe/AVFoundation 的 YCbCr 矩阵常量字符串 → 着色器代号（0/1/2）。
    private static func matrixCode(from name: String?) -> Int32? {
        guard let name else { return nil }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String { return 1 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String { return 2 }
        if name == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String { return 0 }
        if name == kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String { return 0 }
        return nil
    }

    private static func fourCC(_ v: OSType) -> String {
        let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xff) }
        return String(bytes: bytes, encoding: .ascii) ?? "?"
    }
}

private final class CaptureOutputDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var engine: PlaybackEngine?
    init(engine: PlaybackEngine) {
        self.engine = engine
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine?.handleCaptureSampleBuffer(sampleBuffer)
    }
}

#else

// MARK: - 关闭 USE_FFMPEG 时的占位实现
//
// 保持与外层完全相同的 API 表面，让 UI 层不必写条件编译就能编译通过。

import Foundation
import CoreGraphics

enum PlaybackState: Equatable {
    case idle, opening, playing, paused, ended
    case failed(String)
    var isActive: Bool { self == .playing }
}

protocol PlaybackEngineDelegate: AnyObject {
    func playbackEngine(_ engine: PlaybackEngine, didChange state: PlaybackState)
    func playbackEngine(_ engine: PlaybackEngine, didUpdateTime time: Double, duration: Double)
}

final class PlaybackEngine {
    weak var delegate: PlaybackEngineDelegate?
    private(set) var url: URL?
    private(set) var duration: Double = 0
    private(set) var videoSize: CGSize = .zero
    private(set) var sourceInfo: String = "FFmpeg 未启用"
    var hasVideo: Bool { false }
    var hasAudio: Bool { false }
    var currentTime: Double { 0 }
    var state: PlaybackState = .idle
    var isPlaying: Bool { false }
    var volume: Float = 1

    /// 与真实实现逐条对应（Tab 监看面板用）。
    private(set) var tracks: [TrackInfo] = []
    private(set) var detail = MediaDetail()
    var audioTracks: [TrackInfo] { [] }
    var subtitleTracks: [TrackInfo] { [] }
    var currentAudioStreamIndex: Int? { nil }
    var selectedAudioStreamIndex: Int { -1 }
    var currentSubtitleStreamIndex: Int? { nil }
    var selectedSubtitleStreamIndex: Int { -1 }

    func selectAudioTrack(_ index: Int) {}
    func selectSubtitleTrack(_ index: Int) {}
    func disableSubtitles() {}

    func snapshotCounters() -> PlaybackCounters {
        var c = PlaybackCounters()
        c.stateText = "FFmpeg 未启用"
        return c
    }

    /// 与真实实现同名同义：就地重建管线。占位实现没有管线，如实空转。
    func reloadInPlace() {}

    func open(url: URL) throws {
        throw PlaybackUnavailableError()
    }
    func play() {}
    func pause() {}
    func togglePlayPause() {}
    func seek(to seconds: Double) {}
    func shutdown() {}
    func nextFrameForDisplay() -> DecodedVideoFrame? { nil }
}

struct PlaybackUnavailableError: LocalizedError {
    var errorDescription: String? { "FFmpeg 未启用（缺少 USE_FFMPEG 编译条件）" }
}

#endif
