//  PlaybackStats.swift
//  MetalPlayer 重建工程 —— 「性能监看」面板的数据源（Phase 2 增补）
//
//  这个文件是 Tab 监看面板的下半部分：**运行时性能数据**。
//  与 `MediaDetail.swift`（静态参数快照）分工明确：
//      MediaDetail     —— 开文件时取一次，之后不变（容器/编码/分辨率…）
//      PlaybackStats   —— 每次面板刷新都重采样（FPS/队列/CPU/内存…）
//
//  为什么拆成「引擎原始计数」+「采样器」两层：
//    引擎只负责**单调递增地计数**（解了多少帧、上屏多少帧、丢了多少帧），
//    这不依赖时间；FPS 是「计数对时间求导」，是采样侧的活。
//    这样引擎热路径上只多一条 `+= 1`，不需要在解码线程里读时钟。
//
//  刻意放在 `#if USE_FFMPEG` **之外**：关掉开关时面板仍要能显示
//  「FFmpeg 未启用」，而 CPU/内存这些系统指标与 FFmpeg 无关。

import Foundation
import Metal

// MARK: - 队列容量（三条管线队列，用于显示 `12/200` 这样的占用）

/// 队列容量与占用。容量是固定值，和 `PlaybackEngine` 里的定义保持一致。
struct PipelineQueueDepths {
    var videoPacket = 0, videoPacketCapacity = 200
    var audioPacket = 0, audioPacketCapacity = 600
    var frame = 0, frameCapacity = 24

    static let empty = PipelineQueueDepths()
}

// MARK: - 引擎侧原始计数（单调递增，不含时间）

/// 引擎热路径只更新的东西。全是不依赖时间戳的计数器 + 几个标量。
struct PlaybackCounters {
    var decodedVideoFrames = 0
    var presentedFrames = 0
    /// 因为「迟到」被丢弃的帧（见 `nextFrameForDisplay` 里那段）。
    var droppedFrames = 0
    var queues = PipelineQueueDepths.empty
    /// 已排进播放器的音频末端时间（秒）。
    var audioScheduledEnd: Double = 0
    /// 最近一次上屏的帧 pts（秒），-1 表示还没有。
    var lastPresentedPTS: Double = -1
    /// 当前播放时钟（秒）。
    var currentTime: Double = 0
    var isPlaying = false
    /// 状态机的人话描述（"播放中" / "已暂停" …）。
    var stateText = "空闲"
    /// 是否走了音频主时钟。
    var usesAudioClock = false
    /// 当前是否处于 GPU 硬件加速解码。
    var isHardwareDecode = false
    /// 当前视频解码器名称（如 "h264", "hevc" 等）。
    var videoDecoderName = ""
    /// RIFE AI 补帧活跃状态与插帧计数
    var rifeActive = false
    var rifeInterpolatedFrames = 0
    var rifeStatusText = "待命"
    /// MetalFX 空间超分辨率
    var metalFXActive = false
    var metalFXStatusText = "MetalFX 关闭"
    /// Anime4K 动漫增强
    var anime4kActive = false
    var anime4kStatusText = "Anime4K 关闭"
    /// 采集卡：**实测**投递帧率（设备/连接属性读回值 ≠ 真实出帧，见 openCapture 注释）
    var captureDeliveredFPS: Double = 0
    /// 采集卡：本次解析出的色彩信息（矩阵 / 范围 / 来源）
    var captureColorInfo = ""

    static let empty = PlaybackCounters()
}

// MARK: - 采样后的可显示数据

/// 面板真正要显示的一组数。`StatsSampler` 把计数器转成这里的 FPS 等。
struct PlaybackRuntimeStats {
    var renderFPS: Double = 0
    var decodeFPS: Double = 0
    var presentedFrames = 0
    var decodedFrames = 0
    var droppedFrames = 0
    var queues = PipelineQueueDepths.empty
    var audioScheduledEnd: Double = 0
    var lastPresentedPTS: Double = -1
    var currentTime: Double = 0
    var avDrift: Double = 0
    var isPlaying = false
    var stateText = "空闲"
    var usesAudioClock = false
    var isHardwareDecode = false
    var videoDecoderName = ""
    var rifeActive = false
    var rifeInterpolatedFrames = 0
    var rifeStatusText = "待命"
    var metalFXActive = false
    var metalFXStatusText = "MetalFX 关闭"
    var anime4kActive = false
    var anime4kStatusText = "Anime4K 关闭"

    /// 采集卡实测投递帧率（0 = 非采集模式或尚未测出）
    var captureDeliveredFPS: Double = 0
    /// 采集卡解析出的色彩信息（矩阵 / 范围 / 来源）
    var captureColorInfo = ""

    var cpuPercent: Double = 0
    /// 常驻物理内存（RSS）
    var memoryMB: Double = 0
    /// 内核物理足迹（不含 IOSurface）
    var footprintMB: Double = 0
    /// 被压缩的量
    var compressedMB: Double = 0
    var gpuName = "—"
}

// MARK: - 采样器

/// 把单调计数器按时间求导，得到 FPS；顺带采一次系统指标。
///
/// 用法：面板可见时每 ~0.5s 调一次 `sample(_:)`。
/// 第一次调用没有历史数据，FPS 会是 0 —— 这是对的（还没有可测的区间），
/// 不要用「假装是 60」之类的方式填充。
final class StatsSampler {

    private var lastSampleTime: TimeInterval = 0
    private var lastPresented = 0
    private var lastDecoded = 0
    private var lastPresentedPTS: Double = -1

    /// 系统指标采样器（进程自身）。
    private let system = SystemMetricsSampler()

    func sample(_ counters: PlaybackCounters) -> PlaybackRuntimeStats {
        var out = PlaybackRuntimeStats()
        out.presentedFrames = counters.presentedFrames
        out.decodedFrames = counters.decodedVideoFrames
        out.droppedFrames = counters.droppedFrames
        out.queues = counters.queues
        out.audioScheduledEnd = counters.audioScheduledEnd
        out.lastPresentedPTS = counters.lastPresentedPTS
        out.currentTime = counters.currentTime
        // 音视频偏差 = 画面落后/超前时钟多少。正数表示画面比时钟旧（正常，
        // 因为上屏本来就是「等到 pts 到点才显示」）。
        if counters.lastPresentedPTS >= 0 {
            out.avDrift = counters.currentTime - counters.lastPresentedPTS
        }
        out.isPlaying = counters.isPlaying
        out.stateText = counters.stateText
        out.usesAudioClock = counters.usesAudioClock
        out.isHardwareDecode = counters.isHardwareDecode
        out.videoDecoderName = counters.videoDecoderName
        out.rifeActive = counters.rifeActive
        out.rifeInterpolatedFrames = counters.rifeInterpolatedFrames
        out.rifeStatusText = counters.rifeStatusText
        out.metalFXActive = counters.metalFXActive
        out.metalFXStatusText = counters.metalFXStatusText
        out.anime4kActive = counters.anime4kActive
        out.anime4kStatusText = counters.anime4kStatusText
        out.captureDeliveredFPS = counters.captureDeliveredFPS
        out.captureColorInfo = counters.captureColorInfo

        let now = Date.timeIntervalSinceReferenceDate
        if lastSampleTime > 0 {
            let dt = now - lastSampleTime
            if dt > 0.05 {
                out.renderFPS = Double(counters.presentedFrames - lastPresented) / dt
                out.decodeFPS = Double(counters.decodedVideoFrames - lastDecoded) / dt
            }
        }
        lastSampleTime = now
        lastPresented = counters.presentedFrames
        lastDecoded = counters.decodedVideoFrames
        lastPresentedPTS = counters.lastPresentedPTS

        // 值可能是负的（计数器被复位过，例如换文件）：负数没有意义，钳到 0，
        // 免得面板上出现 `-1234.5 fps` 这种一看就是坏掉的东西。
        out.renderFPS = max(0, out.renderFPS)
        out.decodeFPS = max(0, out.decodeFPS)

        let sys = system.sample()
        out.cpuPercent = sys.cpuPercent
        out.memoryMB = sys.memoryMB
        out.footprintMB = sys.footprintMB
        out.compressedMB = sys.compressedMB
        out.gpuName = SystemMetricsSampler.gpuName()
        return out
    }

    /// 换文件 / 关文件时调用：清掉历史，下一轮重新起算，
    /// 否则新旧文件的计数器差会被算成一瞬间的超高 FPS。
    func reset() {
        lastSampleTime = 0
        lastPresented = 0
        lastDecoded = 0
        lastPresentedPTS = -1
    }
}

// MARK: - 系统指标

/// 进程自身的 CPU / 内存占用。
///
/// 为什么不读「整机 CPU」：播放器用户关心的是「这个 app 吃多少」，
/// 整机数字混着别的进程，看不出播放器本身的开销。
struct SystemMetricsSample {
    var cpuPercent: Double = 0
    /// 常驻物理内存（RSS）：Activity Monitor 观感最直接的那个数
    var memoryMB: Double = 0
    /// 内核物理足迹：不含 IOSurface 后备页
    var footprintMB: Double = 0
    /// 被压缩器压住的量
    var compressedMB: Double = 0
}

final class SystemMetricsSampler {

    private var lastWall: TimeInterval = 0
    private var lastCPUSeconds: Double = 0

    /// 缓存一次 GPU 名（`MTLCreateSystemDefaultDevice` 不该每次刷新都调）。
    private static let cachedGPUName: String = {
        MTLCreateSystemDefaultDevice()?.name ?? "—"
    }()

    static func gpuName() -> String { cachedGPUName }

    func sample() -> SystemMetricsSample {
        var out = SystemMetricsSample()

        let now = Date.timeIntervalSinceReferenceDate
        let cpuSeconds = Self.processCPUSeconds()
        if lastWall > 0 {
            let dt = now - lastWall
            // dt 太小会让百分比剧烈抖动；0.05s 以下直接沿用上次的结论。
            if dt > 0.05 {
                out.cpuPercent = (cpuSeconds - lastCPUSeconds) / dt * 100
            }
        }
        lastWall = now
        lastCPUSeconds = cpuSeconds

        // 三个口径一起采样：只报一个会得出相反结论（IOSurface 不计入
        // phys_footprint，补帧链路恰恰大量用它）。详见 MemoryFootprint。
        out.memoryMB = Self.residentMemoryMB()
        out.footprintMB = MemoryFootprint.currentMB()
        out.compressedMB = MemoryFootprint.compressedMB()
        return out
    }

    /// 进程累计 CPU 时间（user + sys），秒。
    ///
    /// 用 `getrusage` 而不是 `host_statistics`：后者给的是**整机** CPU，
    /// 前者拿到的正是「本进程烧了多少 CPU 秒」，除以墙钟就是占用率。
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + sys
    }

    /// 常驻内存（resident size），MB。
    private static func residentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size
                                           / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024 * 1024)
    }
}
