//  CoreMLRIFEEngine.swift
//  Macrife Player —— Phase 4+ 真·RIFE 神经网络补帧引擎（CoreML + Metal 混合）
//
//  为什么重写而不是继续修 RIFEInterpolationEngine：那是手写块匹配近似，
//  运动质量到不了真 RIFE 的水平（用户实测 4K 上「效果只好了一点点」）。
//  本引擎接 models.dat 里的 CoreML 权重（encode + block0..4 分块导出），
//  推理架构移植自离线转码工程 /Users/teeate/Dev/Macrife（用户实测「补帧效果超级好」）：
//
//    · CoreML 只跑卷积（encode ×2 + block0..4），warp / concat / blend 用 Metal kernel
//      —— CoreML 不支持 grid_sample，warp 必须拆出来（两边工程独立验证过同一结论）；
//    · 零拷贝：CoreML 分配的 MLMultiArray 页对齐，用 makeBuffer(bytesNoCopy:) 包成
//      MTLBuffer，输入由 Metal 直接写进 CoreML 原生数组、输出直接包给下一个 kernel；
//    · 源分辨率融合（blendAtSource）：光流/mask 在模型分辨率（576×1024）上算
//      （卷积成本不变），warp/blend 用原始源分辨率帧做 —— 输出细节来自原图，
//      一套 576p 模型服务任意源分辨率（含 4K，离线工程实测 4K 过 576p 档
//      若无此路径只剩 55% 锐度）；
//    · 逐对复用：cur 帧的转换 + encode 结果在下一对里当作 prev 复用，每对省
//      一次转换 + 一次 encode（实时性的关键，x2@24fps 每秒只付 25 次 encode）。
//
//  与离线工程的差异（本文件适配点）：
//    · 输入是解码器直出的 NV12 CVPixelBuffer（离线工程是 BGRA 文件帧），
//      新增 nv12_to_rgb_nchw 内核（BT.601/709 · limited/full range 都支持）；
//    · 输出直接写回 NV12 池缓冲，走播放器原有渲染/上屏链路；
//    · 档位映射到 models.dat 的已编译 .mlmodelc（无需再 compile）；
//    · 引擎初始化在后台队列（CoreML 加载 + ANE 编译是秒级），未就绪时调用方
//      回落到旧的块匹配引擎，就绪后自动热切换；
//    · 档位固定 576p tier：实时回放算力优先，细节由 blendAtSource 保底。
//
//  通道拼接顺序（离线工程验证过，错一位就全是鬼影）：
//    block0 输入 15ch = [img0(3) | img1(3) | f0(4) | f1(4) | ts(1)]
//    blockN 输入 24ch = [w0(3) | w1(3) | wf0(4) | wf1(4) | ts(1) | mask(1) | feat(8)]

import Foundation
import CoreML
import CoreVideo
import Metal
import IOSurface

// MARK: - 引擎门面（模式逻辑 + 状态，对齐旧引擎语义）

final class CoreMLRIFEEngine {

    static let shared = CoreMLRIFEEngine()

    /// 插值目标：一对源帧之间的一个时间戳点。
    /// runChain=true 跑神经网络链；false 直接拷贝 f0（静止帧/网格端点）。
    struct RifeTick {
        let pts: Double
        let alpha: Float
        let runChain: Bool
    }

    // MARK: 对外状态（供 PlaybackEngine 路由与统计）

    private let countLock = NSLock()
    private var interpolatedFrames = 0
    var totalInterpolatedFrames: Int {
        countLock.lock(); defer { countLock.unlock() }
        return interpolatedFrames
    }
    var activeStateText: String {
        lock.lock(); defer { lock.unlock() }
        if permanentlyFailed { return "真模型不可用 (\(failureReason))" }
        if engines.isEmpty { return "真模型加载中…" }
        return String(format: "真模型活跃 x%d (已生成 %d 帧)", engines.count, interpolatedFrames)
    }

    /// 初始化系统性失败（模型缺失 / 零拷贝不可用）——调用方此后不再尝试本引擎。
    private(set) var permanentlyFailed = false
    private var failureReason = ""

    private var warnedPixelFormat = false

    // MARK: 引擎实例与并发
    //
    // 多 worker 并行（对齐原版 RIFEMultiPairReorderBuffer 架构）：
    // 每个Engine 持有独立模型实例 + 独立 Metal 工作区，互不共享可变状态，
    // 因此可以在各自的 worker 线程上同时跑不同帧对。微基准（M1 Pro）：
    // .all 单链 28.7ms，双实例并发聚合 44 对/s（近线性），是补帧跑满 x2 的关键。

    private let lock = NSLock()
    private var engines: [Engine] = []
    /// engines[i] 的互斥锁：双实例时各 worker 独占一把零争抢；
    /// 若初始化只成功了一个实例，两 worker 在同一把锁上退化为串行（正确性优先）。
    private var engineLocks: [NSLock] = []
    /// engines 对应的配置指纹（模型档 + 源分辨率 + 色彩参数）
    private var engineConfig: String = ""
    private var pendingConfig: String?
    private let initQueue = DispatchQueue(label: "com.macrife.coremlrife.init", qos: .userInitiated)

    private init() {}

    /// 内存排查遥测：各引擎实例的池缓冲取用次数、转换次数，以及**取到手的是
    /// 新 IOSurface 还是回收复用的旧缓冲**。
    ///
    /// 判据：池若正常工作，复用数应占绝大多数、新 surface 数应收敛到并发持有
    /// 峰值（几十）；若「新」与「取用」同速增长，说明每块输出缓冲都被下游长期
    /// 扣住，池只能不停新建 —— 这正是活动监视器里 IOSurface 线性膨胀的成因
    ///（phys_footprint 不计 IOSurface，所以足迹采样看起来是平的）。
    func poolStatsText() -> String {
        lock.lock(); defer { lock.unlock() }
        return engines.enumerated().map { i, e in
            "E\(i):取\(e.poolCreateCount)/新\(e.surfaceNewCount)/复用\(e.surfaceReuseCount)/转换\(e.convertOpCount)"
        }.joined(separator: " ")
    }

    // MARK: 档位映射

    /// rifeModel 设置 → models.dat 里的模型目录名。FLAVR/DRBA 不归本引擎管。
    /// 档位固定 576p tier：实时回放算力优先，细节由 blendAtSource 保底。
    private static func variantName(for model: RIFEModelChoice) -> String? {
        // MP_RIFE_VARIANT 环境变量可强制指定档位目录（A/B 测试用）
        if let forced = ProcessInfo.processInfo.environment["MP_RIFE_VARIANT"] {
            return forced.isEmpty ? nil : forced
        }
        switch model {
        case .lite425:   return "rife_425_lite_fp16_576p_blocks"
        case .full425:   return "rife_425_fp16_576p_blocks"
        case .v426:      return "rife_426_fp16_576p_blocks"
        case .heavy426:  return "rife_426_heavy_fp16_576p_blocks"
        case .flavr2x, .flavrFast, .distilDRBA: return nil
        }
    }

    private func configKey(settings: PlaybackSettings, w: Int, h: Int,
                           fullRange: Bool, bt709: Bool) -> String {
        "\(settings.rifeModel.rawValue)|\(w)x\(h)|\(fullRange ? 1 : 0)|\(bt709 ? 1 : 0)"
    }

    // MARK: 对外接口

    /// 当前是否有**配置匹配**的引擎可插帧（PlaybackEngine 的路由判据）。
    func isReady(settings: PlaybackSettings, sourceWidth: Int, sourceHeight: Int,
                 fullRange: Bool, bt709: Bool) -> Bool {
        guard !permanentlyFailed,
              settings.rifeRateMode != .off,
              Self.variantName(for: settings.rifeModel) != nil,
              sourceWidth > 0, sourceHeight > 0 else { return false }
        lock.lock(); defer { lock.unlock() }
        return !engines.isEmpty && engineConfig == configKey(settings: settings,
                                                             w: sourceWidth, h: sourceHeight,
                                                             fullRange: fullRange, bt709: bt709)
    }

    /// 若没有匹配配置的引擎，异步拉起初始化（模型加载 + ANE 编译，秒级 ×2 实例）。
    func prewarmIfNeeded(settings: PlaybackSettings, sourceWidth: Int, sourceHeight: Int,
                         fullRange: Bool, bt709: Bool) {
        guard !permanentlyFailed,
              settings.rifeRateMode != .off,
              let variant = Self.variantName(for: settings.rifeModel),
              sourceWidth > 0, sourceHeight > 0 else { return }
        let key = configKey(settings: settings, w: sourceWidth, h: sourceHeight,
                            fullRange: fullRange, bt709: bt709)
        lock.lock()
        if !engines.isEmpty && engineConfig == key { lock.unlock(); return }
        if pendingConfig == key { lock.unlock(); return }
        pendingConfig = key
        lock.unlock()

        initQueue.async { [weak self] in
            guard let self else { return }
            // 双实例：worker 并行推理（见 engines 注释）。第二个实例编译失败
            // 不至于全灭 —— 成功几个用几个（runPair 会按实例数取模并串行化）。
            var built: [Engine] = []
            var buildError: Error?
            var usedVariant = variant
            for _ in 0..<2 {
                do {
                    let eng = try Engine(modelVariant: usedVariant,
                                         sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                         fullRange: fullRange, bt709: bt709)
                    eng.warmup()
                    built.append(eng)
                } catch {
                    if built.isEmpty { buildError = error }
                    NSLog("[CoreMLRIFE] 引擎实例 %d 构建失败: %@", built.count + 1, String(describing: error))
                }
            }
            // 档位本身不兼容（例如 heavy 是 16 通道特征，本链路按 4 通道拼）：
            // 整档重试一次 4 通道档位，别让用户对着「补帧像没开」一头雾水。
            if built.isEmpty, usedVariant != Engine.fallbackVariant {
                let reason = buildError.map { String(describing: $0) } ?? ""
                if reason.contains("档位不兼容") || reason.contains("通道") {
                    NSLog("[CoreMLRIFE] %@ 档位不可用，自动回落到 %@", usedVariant, Engine.fallbackVariant)
                    usedVariant = Engine.fallbackVariant
                    for _ in 0..<2 {
                        do {
                            let eng = try Engine(modelVariant: usedVariant,
                                                 sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                                 fullRange: fullRange, bt709: bt709)
                            eng.warmup()
                            built.append(eng)
                        } catch {
                            if built.isEmpty { buildError = error }
                            NSLog("[CoreMLRIFE] 回落档位实例构建失败: %@", String(describing: error))
                        }
                    }
                }
            }
            guard !built.isEmpty else {
                self.lock.lock()
                self.pendingConfig = nil
                let msg = buildError.map { String(describing: $0) } ?? "未知错误"
                if msg.contains("ZERO_COPY") || msg.contains("模型目录不存在") {
                    self.permanentlyFailed = true
                    self.failureReason = msg
                }
                self.lock.unlock()
                NSLog("[CoreMLRIFE] 引擎初始化失败，继续用块匹配引擎: %@", msg)
                return
            }
            self.lock.lock()
            self.engines = built
            self.engineLocks = built.map { _ in NSLock() }
            self.engineConfig = key
            self.pendingConfig = nil
            self.lock.unlock()
            // 报**实际生效**的档位：回落时 variant 还是用户选的那个，
            // 打它出来会让人以为 heavy 真的跑起来了（排查时差点被这条骗过）。
            NSLog("[CoreMLRIFE] 真模型引擎就绪 x%d: %@ (%dx%d 源)%@", built.count, usedVariant,
                  sourceWidth, sourceHeight,
                  usedVariant == variant ? "" : " 〔由 \(variant) 回落〕")
        }
    }

    /// 重置状态（Seek 或切换视频时调用）。各 Engine 的 pair 缓存以缓冲区
    /// 对象身份为键，seek 后新缓冲自然 miss；这里清掉残余引用防串帧。
    func reset() {
        lock.lock(); engines.forEach { $0.resetPairState() }; lock.unlock()
    }

    /// 打包 4:2:2（YUY2）→ NV12：让采集卡也能进真·RIFE 链路。
    /// 引擎尚未就绪（模型加载期）返回 nil，调用方回落到直通并提示一次。
    func convertPacked422ToNV12(_ pb: CVPixelBuffer) -> CVPixelBuffer? {
        lock.lock()
        let eng = engines.first
        lock.unlock()
        guard let eng else { return nil }
        return eng.convertPacked422ToNV12(from: pb)
    }

    // MARK: 成对插值接口（多 worker 并行的执行单元）

    /// 跑一个帧对：f0/f1 之间按 ticks（时间戳+alpha，由调度线程按序算好）
    /// 依次出帧，返回以 f0 开头的完整输出序列（f0 原样带回，保序由重排缓冲负责）。
    /// 只允许对应 worker 线程调用 —— engines[i] 仅属于 worker i。
    func runPair(workerIndex: Int,
                 f0: DecodedVideoFrame, f1: DecodedVideoFrame,
                 ticks: [RifeTick],
                 settings: PlaybackSettings) -> [DecodedVideoFrame] {
        lock.lock()
        let ei = (workerIndex >= 0 && !engines.isEmpty) ? workerIndex % engines.count : -1
        let eng = ei >= 0 ? engines[ei] : nil
        let elock = ei >= 0 && ei < engineLocks.count ? engineLocks[ei] : nil
        lock.unlock()
        guard let eng else { return [f0] }
        elock?.lock()
        defer { elock?.unlock() }

        var result: [DecodedVideoFrame] = []

        // f0 也过一遍与插值帧相同的往返内核 —— 三类帧（源/拷贝/插值）像素
        // 处理完全一致，消除 48fps 交替时的局部亮度闪烁（见 roundtripNV12 注释）。
        // 往返失败（极少）回退解码器直出帧。
        let f0Uniform: DecodedVideoFrame
        if let pb = eng.roundtripNV12(from: f0.pixelBuffer) {
            f0Uniform = DecodedVideoFrame(pixelBuffer: pb, pts: f0.pts,
                                          isBT709: f0.isBT709,
                                          colorSpaceCode: f0.colorSpaceCode,
                                          isFullRange: f0.isFullRange,
                                          isInterpolated: false)
        } else {
            f0Uniform = f0
        }
        result.append(f0Uniform)

        func chainFrame(timestep: Float, pts: Double) -> DecodedVideoFrame? {
            guard let pb = eng.runChain(f0: f0.pixelBuffer, f1: f1.pixelBuffer,
                                        timestep: timestep) else { return nil }
            countLock.lock(); interpolatedFrames += 1; countLock.unlock()
            return DecodedVideoFrame(pixelBuffer: pb, pts: pts,
                                     isBT709: f1.isBT709,
                                     colorSpaceCode: f1.colorSpaceCode,
                                     isFullRange: f1.isFullRange,
                                     isInterpolated: true)
        }

        func copyFrame(from src: CVPixelBuffer, pts: Double) -> DecodedVideoFrame? {
            // 与插值帧同一套往返内核（不再用 memcpy 直拷，保证亮度一致）
            guard let pb = eng.roundtripNV12(from: src) else { return nil }
            countLock.lock(); interpolatedFrames += 1; countLock.unlock()
            return DecodedVideoFrame(pixelBuffer: pb, pts: pts,
                                     isBT709: f1.isBT709,
                                     colorSpaceCode: f1.colorSpaceCode,
                                     isFullRange: f1.isFullRange,
                                     isInterpolated: false)
        }

        for tick in ticks {
            let frame: DecodedVideoFrame?
            if tick.runChain {
                frame = chainFrame(timestep: tick.alpha, pts: tick.pts)
            } else {
                frame = copyFrame(from: f0.pixelBuffer, pts: tick.pts)
            }
            if let frame { result.append(frame) }
        }
        return result
    }

    static func fractionalAlphas(mode: RIFERateMode) -> [Float] {
        switch mode {
        case .x2: return [0.5]
        case .x3: return [1.0/3.0, 2.0/3.0]
        case .x4: return [0.25, 0.5, 0.75]
        case .x5: return [0.2, 0.4, 0.6, 0.8]
        default: return [0.5]
        }
    }

    // MARK: 帧间统计（与旧引擎逐行同构；调度线程调用，无共享状态）

    static func areFramesSimilar(_ b0: CVPixelBuffer, _ b1: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(b0)
        let h = CVPixelBufferGetHeight(b0)
        guard w == CVPixelBufferGetWidth(b1), h == CVPixelBufferGetHeight(b1), w > 0, h > 0 else {
            return false
        }
        guard CVPixelBufferLockBaseAddress(b0, .readOnly) == kCVReturnSuccess,
              CVPixelBufferLockBaseAddress(b1, .readOnly) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(b0, .readOnly)
            CVPixelBufferUnlockBaseAddress(b1, .readOnly)
            return false
        }
        defer {
            CVPixelBufferUnlockBaseAddress(b0, .readOnly)
            CVPixelBufferUnlockBaseAddress(b1, .readOnly)
        }
        guard let p0 = CVPixelBufferGetBaseAddressOfPlane(b0, 0),
              let p1 = CVPixelBufferGetBaseAddressOfPlane(b1, 0) else { return false }
        let stride0 = CVPixelBufferGetBytesPerRowOfPlane(b0, 0)
        let stride1 = CVPixelBufferGetBytesPerRowOfPlane(b1, 0)
        let stepX = max(1, w >> 6)
        let stepY = max(1, h >> 6)
        let u0 = p0.assumingMemoryBound(to: UInt8.self)
        let u1 = p1.assumingMemoryBound(to: UInt8.self)
        var diffSum: Double = 0
        var count: Double = 0
        var y = 0
        while y < h {
            let row0 = u0.advanced(by: y * stride0)
            let row1 = u1.advanced(by: y * stride1)
            var x = 0
            while x < w {
                diffSum += abs(Double(row0[x]) - Double(row1[x]))
                count += 1
                x += stepX
            }
            y += stepY
        }
        guard count > 0 else { return false }
        return (diffSum / count) / 255.0 < 0.003
    }

    static func sampleDownscaledLuma(from pb: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = yBase.assumingMemoryBound(to: UInt8.self)
        let cols = 32, rows = 18
        var samples = [UInt8](repeating: 0, count: cols * rows)
        let dx = max(1, w / cols)
        let dy = max(1, h / rows)
        var idx = 0
        for r in 0..<rows {
            let y = min(h - 1, r * dy)
            let rowOffset = y * bpr
            for c in 0..<cols {
                let x = min(w - 1, c * dx)
                samples[idx] = ptr[rowOffset + x]
                idx += 1
            }
        }
        return samples
    }
}

// MARK: - 推理引擎本体（移植自离线工程 RIFEEngine，NV12 适配）

private final class Engine: @unchecked Sendable {

    enum EngineError: Error {
        case setup(String), zeroCopy(String), kernel(String), output(String)
    }

    // MARK: Metal
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipes: [String: MTLComputePipelineState] = [:]
    private var pending: MTLCommandBuffer?
    private var textureCache: CVMetalTextureCache?
    private let pageSize: Int

    // MARK: 模型
    private let encodeModel: MLModel
    private var blocks: [MLModel] = []

    // MARK: 尺寸与色彩
    let modelW: Int
    let modelH: Int
    let srcW: Int
    let srcH: Int
    private let fullRange: Bool
    private let bt709: Bool

    // MARK: 持久缓冲（零拷贝 CoreML 原生数组）
    private struct Store { let array: MLMultiArray; let buffer: MTLBuffer }
    private var encodeIn: [Store] = []
    private var block0In: Store!
    private var blockNIn: Store!
    private var flowAcc: Store!
    private var warped0: MTLBuffer!
    private var warped1: MTLBuffer!
    private var wf0: MTLBuffer!
    private var wf1: MTLBuffer!
    private var segCh15: MTLBuffer!
    private var segCh24: MTLBuffer!
    /// CoreML 每次推理新分配的输出数组必须留住，否则包在它上面的 MTLBuffer 会悬空。
    private var retained: [String: MLMultiArray] = [:]

    // 模型分辨率 RGB 三槽环（f0 / f1 各占一槽，逐对缓存复用占第三槽）
    private var imgRing: [Store] = []
    private var imgCursor = 0

    // 源分辨率融合缓冲
    private var fullRing: [MTLBuffer] = []
    private var fullCursor = 0
    private var warped0Full: MTLBuffer!
    private var warped1Full: MTLBuffer!
    private var flowFull: MTLBuffer!
    private var maskFull: MTLBuffer!
    private var outRGBFull: MTLBuffer!

    // 逐对复用缓存：cur 帧的转换/encode 结果下一对变 prev
    private var cachedPB: CVPixelBuffer?
    private var cachedImg: MTLBuffer?
    private var cachedFull: MTLBuffer?
    private var cachedFeatArray: MLMultiArray?
    private var cachedFeatBuffer: MTLBuffer?
    private var cachedSlot = -1
    private var srcImg0: MTLBuffer?
    private var srcImg1: MTLBuffer?
    private var srcFull0: MTLBuffer?
    private var srcFull1: MTLBuffer?
    private var f0Buf: MTLBuffer?
    private var f1Buf: MTLBuffer?
    private var chainPreparedKey: (CVPixelBuffer, CVPixelBuffer)?

    // 输出像素缓冲池（NV12 @ 源分辨率）
    private var pool: CVPixelBufferPool?
    private var nv12Scratch: MTLBuffer?
    private let poolLock = NSLock()

    private struct Params { var width: UInt32 = 0; var height: UInt32 = 0; var channels: UInt32 = 0 }
    private struct ConcatParams {
        var width: UInt32 = 0; var height: UInt32 = 0
        var segCount: UInt32 = 0; var tsSegIndex: UInt32 = 0; var tsValue: Float = 0
    }
    private struct NCHWResizeParams {
        var srcWidth: UInt32 = 0; var srcHeight: UInt32 = 0
        var dstWidth: UInt32 = 0; var dstHeight: UInt32 = 0
        var channels: UInt32 = 0
    }
    private struct FlowUpscaleParams {
        var srcWidth: UInt32 = 0; var srcHeight: UInt32 = 0
        var dstWidth: UInt32 = 0; var dstHeight: UInt32 = 0
        var scaleX: Float = 1; var scaleY: Float = 1
    }
    private struct NV12InParams {
        var srcWidth: UInt32 = 0; var srcHeight: UInt32 = 0
        var dstWidth: UInt32 = 0; var dstHeight: UInt32 = 0
        var fullRange: Float = 0     // 1.0 = full range
        var is709: Float = 0         // 1.0 = BT.709
    }
    private struct NV12OutParams {
        var width: UInt32 = 0; var height: UInt32 = 0
        var yStride: UInt32 = 0; var uvOffset: UInt32 = 0; var uvStride: UInt32 = 0
        var fullRange: Float = 0
        var is709: Float = 0
    }

    /// 与 Metal 端 `YUY2ConvParams` 完全同布局（4 × UInt32 = 16 字节）。
    private struct YUY2ConvParams {
        var width: UInt32 = 0; var height: UInt32 = 0
        var yStride: UInt32 = 0; var uvStride: UInt32 = 0
    }

    init(modelVariant: String, sourceWidth: Int, sourceHeight: Int,
         fullRange: Bool, bt709: Bool) throws {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            throw EngineError.setup("没有可用的 Metal 设备")
        }
        device = dev; queue = q
        pageSize = Int(getpagesize())
        srcW = sourceWidth; srcH = sourceHeight
        self.fullRange = fullRange
        self.bt709 = bt709

        var cache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache) == kCVReturnSuccess {
            textureCache = cache
        }

        // 1. 定位模型目录（models.dat 已由 ModelPackageManager 解到磁盘）
        guard let dir = ModelPackageManager.modelDirectory(for: modelVariant) else {
            throw EngineError.setup("模型目录不存在: \(modelVariant)（models.dat 未就绪或档位缺失）")
        }

        // 2. 加载已编译的 .mlmodelc（models.dat 里本来就是编译产物）
        //
        // 计算单元：默认 .all（ANE 主力）。微基准实测（576p 块，M1 Pro）：
        //   .all 28.7ms/链（34.8 对/s）≫ cpuAndGPU 57.6ms（17.4 对/s）；
        //   且双线程并发下 .all 聚合 44 对/s（近线性扩展），GPU 链并发反而退化到 22 对/s。
        //   原版二进制注记 "head/block0/...: CPU+ANE / block3: CPU+GPU" 即 .all 的实际落点。
        // MP_RIFE_UNITS 可覆盖（A/B 用）：gpu|split|cpu
        let names = ["encode", "block0", "block1", "block2", "block3", "block4"]
        func makeConfig(units: MLComputeUnits) -> MLModelConfiguration {
            let c = MLModelConfiguration()
            c.computeUnits = units
            c.allowLowPrecisionAccumulationOnGPU = true
            return c
        }
        let aneConfig = makeConfig(units: .all)
        let gpuConfig = makeConfig(units: .cpuAndGPU)
        let cpuConfig = makeConfig(units: .cpuOnly)
        let splitConfig: (String) -> MLModelConfiguration = { $0 == "block3" ? gpuConfig : aneConfig }
        var loaded: [String: MLModel] = [:]
        for n in names {
            let url = dir.appendingPathComponent("\(n).mlmodelc")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EngineError.setup("缺少 \(n).mlmodelc: \(dir.path)")
            }
            switch ProcessInfo.processInfo.environment["MP_RIFE_UNITS"] {
            case "gpu":   loaded[n] = try MLModel(contentsOf: url, configuration: gpuConfig)
            case "split": loaded[n] = try MLModel(contentsOf: url, configuration: splitConfig(n))
            case "cpu":   loaded[n] = try MLModel(contentsOf: url, configuration: cpuConfig)
            default:      loaded[n] = try MLModel(contentsOf: url, configuration: aneConfig)
            }
        }
        encodeModel = loaded["encode"]!
        blocks = (0...4).compactMap { loaded["block\($0)"] }

        // 3. 从 encode 输入约束读推理分辨率
        guard let c = encodeModel.modelDescription.inputDescriptionsByName["img"]?.multiArrayConstraint,
              c.shape.count == 4, c.shape[2].intValue > 0, c.shape[3].intValue > 0 else {
            throw EngineError.setup("encode 的 img 输入不是 [1,3,H,W]")
        }
        modelH = c.shape[2].intValue
        modelW = c.shape[3].intValue

        // 4. I/O dtype 校验：引擎按 fp16 线性读写，dtype 不匹配只会静默产出垃圾
        try Self.assertFloat16IO(encodeModel, name: "encode")
        for (i, m) in blocks.enumerated() { try Self.assertFloat16IO(m, name: "block\(i)") }

        // 4b. 特征通道数校验 —— 必须在加载期拒绝，不能等到每帧才发现。
        //
        // 本引擎的通道拼接是按 4 通道特征写死的（文件头的 block0 15ch /
        // blockN 24ch）。heavy 档的 encode 输出是 16 通道，走这条路每一帧都
        // 抛「f0 形状 [1,16,H,W] != [1,4,H,W]」然后跳过插帧 —— 表现是**插帧
        // 率归零、日志刷屏**，用户只看到「补帧像没开」，还以为是自己没调好。
        // 在加载期就抛错，上层会回落到 4 通道档位并打一条明确的日志。
        // （顺带：16 通道卷积量是 4 倍，4K 下本来就进不了实时预算。）
        if let ch = Self.encodeFeatureChannels(encodeModel), ch != Self.featureChannels {
            throw EngineError.setup(
                "\(modelVariant) 的 encode 输出 \(ch) 通道，本引擎按 \(Self.featureChannels) 通道拼接，档位不兼容")
        }

        // 5. Metal 内核（离线工程验证过的全套 + 本工程新增的 NV12 互转）
        let library = try dev.makeLibrary(source: Self.metalSource, options: nil)
        for fn in ["warp_nchw", "concat_multi", "copy_nchw", "blend_nchw", "add_nchw",
                   "resize_nchw", "flow_upscale_nchw",
                   "nv12_to_rgb_nchw", "rgb_nchw_to_nv12_y", "rgb_nchw_to_nv12_uv",
                   "yuy2_to_nv12"] {
            guard let f = library.makeFunction(name: fn) else {
                throw EngineError.kernel(fn)
            }
            pipes[fn] = try dev.makeComputePipelineState(function: f)
        }

        // 6. 零拷贝存储（CoreML 原生数组 → MTLBuffer）
        encodeIn = [try makeStore(channels: 3), try makeStore(channels: 3)]
        block0In = try makeStore(channels: 15)
        blockNIn = try makeStore(channels: 24)
        flowAcc = try makeStore(channels: 4)
        warped0 = try modelBuffer(channels: 3)
        warped1 = try modelBuffer(channels: 3)
        wf0 = try modelBuffer(channels: 4)
        wf1 = try modelBuffer(channels: 4)
        imgRing = [try makeStore(channels: 3), try makeStore(channels: 3), try makeStore(channels: 3)]
        segCh15 = try uintBuffer([3, 3, 4, 4, 1])
        segCh24 = try uintBuffer([3, 3, 4, 4, 1, 1, 8])

        // 7. 源分辨率融合缓冲（4K 下 ~400 MB；卷积仍只付模型分辨率的成本）
        fullRing = [try srcBuffer(channels: 3), try srcBuffer(channels: 3), try srcBuffer(channels: 3)]
        warped0Full = try srcBuffer(channels: 3)
        warped1Full = try srcBuffer(channels: 3)
        flowFull = try srcBuffer(channels: 4)
        maskFull = try srcBuffer(channels: 1)
        outRGBFull = try srcBuffer(channels: 3)

        // 8. 输出 NV12 池
        ensurePool()
        NSLog("[CoreMLRIFE] Engine init: %@ 模型 %dx%d, 源 %dx%d",
              modelVariant, modelW, modelH, sourceWidth, sourceHeight)
    }

    /// 本链路拼装所依赖的 encode 特征通道数（见文件头的通道拼接说明）。
    static let featureChannels = 4
    /// 通道数不兼容时回落的档位（4 通道 · 576p · fp16）。
    static let fallbackVariant = "rife_426_fp16_576p_blocks"

    /// 读 encode 模型的特征输出通道数；读不到就返回 nil（不拦）。
    private static func encodeFeatureChannels(_ model: MLModel) -> Int? {
        for n in ["feat", "f", "out_feat", "out_f"] {
            if let c = model.modelDescription.outputDescriptionsByName[n]?.multiArrayConstraint,
               c.shape.count == 4 {
                return c.shape[1].intValue
            }
        }
        return nil
    }

    private static func assertFloat16IO(_ model: MLModel, name: String) throws {
        func check(_ d: MLFeatureDescription, _ tag: String) throws {
            guard let a = d.multiArrayConstraint else { return }
            guard a.dataType == .float16 else {
                throw EngineError.setup("\(name).\(tag) dtype=\(a.dataType.rawValue) 不是 fp16")
            }
        }
        for (k, d) in model.modelDescription.inputDescriptionsByName { try check(d, "in:\(k)") }
        for (k, d) in model.modelDescription.outputDescriptionsByName { try check(d, "out:\(k)") }
    }

    /// 池缓冲创建计数（内存排查遥测：池若正常回收，此值应远小于处理帧数）
    private var poolCreates = 0
    var poolCreateCount: Int {
        poolLock.lock(); defer { poolLock.unlock() }
        return poolCreates
    }
    /// 转换/往返次数（遥测用）
    private var convertOps = 0
    var convertOpCount: Int {
        poolLock.lock(); defer { poolLock.unlock() }
        return convertOps
    }

    // 新/复用判定：记录最近 256 个输出缓冲的 IOSurface ID，取到手时回查。
    private var surfRing = [UInt32](repeating: 0, count: 256)
    private var surfCursor = 0
    private var surfNew = 0
    private var surfReuse = 0
    var surfaceNewCount: Int {
        poolLock.lock(); defer { poolLock.unlock() }
        return surfNew
    }
    var surfaceReuseCount: Int {
        poolLock.lock(); defer { poolLock.unlock() }
        return surfReuse
    }
    /// 取到缓冲后记录：ID 在近期环里出现过 → 复用；否则是新建。
    private func noteSurface(of pb: CVPixelBuffer) {
        guard let raw = CVPixelBufferGetIOSurface(pb) else { return }
        let id = IOSurfaceGetID(unsafeBitCast(raw, to: IOSurfaceRef.self))
        if id == 0 { return }
        if surfRing.contains(id) {
            surfReuse += 1
        } else {
            surfNew += 1
            surfRing[surfCursor] = id
            surfCursor = (surfCursor + 1) % surfRing.count
        }
    }

    private func ensurePool() {
        poolLock.lock(); defer { poolLock.unlock() }
        if pool != nil { return }
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: srcW,
            kCVPixelBufferHeightKey: srcH,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var p: CVPixelBufferPool?
        if CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &p) == kCVReturnSuccess {
            pool = p
        }
    }

    // MARK: 内存

    private func modelBuffer(channels: Int) throws -> MTLBuffer {
        try buffer(width: modelW, height: modelH, channels: channels)
    }
    private func srcBuffer(channels: Int) throws -> MTLBuffer {
        try buffer(width: srcW, height: srcH, channels: channels)
    }
    private func buffer(width w: Int, height h: Int, channels: Int) throws -> MTLBuffer {
        guard let b = device.makeBuffer(length: channels * h * w * 2,
                                        options: .storageModeShared) else {
            throw EngineError.setup("MTLBuffer 分配失败 (\(channels)ch \(w)x\(h))")
        }
        return b
    }
    private func uintBuffer(_ values: [UInt32]) throws -> MTLBuffer {
        guard let b = device.makeBuffer(length: values.count * 4, options: .storageModeShared) else {
            throw EngineError.setup("uint MTLBuffer 分配失败")
        }
        b.contents().assumingMemoryBound(to: UInt32.self).initialize(from: values, count: values.count)
        return b
    }
    private func makeStore(channels: Int) throws -> Store {
        let array = try MLMultiArray(shape: [1, NSNumber(value: channels),
                                             NSNumber(value: modelH), NSNumber(value: modelW)],
                                     dataType: .float16)
        return Store(array: array, buffer: try wrap(array, channels: channels))
    }
    private func wrap(_ array: MLMultiArray, channels: Int) throws -> MTLBuffer {
        let addr = UInt(bitPattern: array.dataPointer)
        guard addr % UInt(pageSize) == 0 else {
            throw EngineError.zeroCopy("ZERO_COPY: MLMultiArray 未页对齐")
        }
        let bytes = channels * modelH * modelW * 2
        let rounded = ((bytes + pageSize - 1) / pageSize) * pageSize
        guard let b = device.makeBuffer(bytesNoCopy: array.dataPointer, length: rounded,
                                        options: .storageModeShared, deallocator: nil) else {
            throw EngineError.zeroCopy("ZERO_COPY: bytesNoCopy 包装失败")
        }
        return b
    }
    /// 接管 CoreML 输出：校验形状 → 留住引用 → 包成 MTLBuffer
    private func retain(_ role: String, _ array: MLMultiArray, channels: Int) throws -> MTLBuffer {
        let s = array.shape.map(\.intValue)
        guard s == [1, channels, modelH, modelW] else {
            throw EngineError.output("\(role) 形状 \(s) != [1,\(channels),\(modelH),\(modelW)]")
        }
        retained[role] = array
        return try wrap(array, channels: channels)
    }

    // MARK: Metal 批提交（buffer + 可选 texture 混绑）

    private func begin() { if pending == nil { pending = queue.makeCommandBuffer() } }

    /// buffers 依序绑到 buffer(0..n-1)，textures 依序绑到 texture(0..m-1)
    private func dispatch(_ name: String, _ args: [(MTLBuffer, Int)],
                          textures: [MTLTexture] = [],
                          bytes: UnsafeRawPointer? = nil, length: Int = 0,
                          grid: MTLSize? = nil) throws {
        if pending == nil { pending = queue.makeCommandBuffer() }
        guard let cmd = pending, let enc = cmd.makeComputeCommandEncoder() else {
            throw EngineError.kernel("encoder 创建失败")
        }
        guard let pipe = pipes[name] else { throw EngineError.kernel(name) }
        enc.setComputePipelineState(pipe)
        for (i, a) in args.enumerated() { enc.setBuffer(a.0, offset: a.1, index: i) }
        if let bytes, length > 0 { enc.setBytes(bytes, length: length, index: args.count) }
        for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
        let g = grid ?? MTLSize(width: modelW, height: modelH, depth: 1)
        guard g.width > 0, g.height > 0 else { enc.endEncoding(); return }
        let tg = MTLSize(width: min(pipe.threadExecutionWidth, max(1, g.width)), height: 1, depth: 1)
        enc.dispatchThreads(g, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }

    private func flushAndWait() throws {
        guard let cmd = pending else { return }
        pending = nil
        let t0 = DispatchTime.now().uptimeNanoseconds
        cmd.commit()
        cmd.waitUntilCompleted()
        metalMS += Self.nowMS(t0)
        if let e = cmd.error { throw EngineError.kernel("Metal 执行失败: \(e)") }
    }

    // MARK: CoreML

    private func predict(_ model: MLModel, inputs: [String: MLMultiArray]) throws -> [String: MLMultiArray] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { inferMS += Self.nowMS(t0) }
        var feats: [String: MLFeatureValue] = [:]
        for (k, v) in inputs { feats[k] = MLFeatureValue(multiArray: v) }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: feats))
        var res: [String: MLMultiArray] = [:]
        for name in out.featureNames {
            if let v = out.featureValue(for: name)?.multiArrayValue { res[name] = v }
        }
        return res
    }
    /// 输出名兼容：models.dat 用裸名（feat/flow/mask/fd），离线工程导出用 out_ 前缀
    private func pick(_ res: [String: MLMultiArray], _ names: String...) -> MLMultiArray? {
        for n in names {
            if let v = res[n] { return v }
            if let v = res["out_\(n)"] { return v }
        }
        return nil
    }

    // MARK: NV12 ↔ RGB

    /// CVMetalTextureCache 内部会保留已创建的纹理条目；长会话高频创建时
    /// 需要周期性 flush 回收，否则缓存本身变成无界增长点（每条目钉一张
    /// IOSurface 纹理）。每 256 次 convert/roundtrip 冲一次（≈5s@48fps）。
    private var texCacheOps = 0

    private func mapNV12Textures(_ pb: CVPixelBuffer) -> (y: MTLTexture, uv: MTLTexture)? {
        guard let cache = textureCache else { return nil }
        texCacheOps += 1
        if texCacheOps % 64 == 0 { CVMetalTextureCacheFlush(cache, 0) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        var yt: CVMetalTexture?, uvt: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                        .r8Unorm, w, h, 0, &yt) == kCVReturnSuccess,
              let yTex = CVMetalTextureGetTexture(yt!),
              CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil,
                                                        .rg8Unorm, w/2, h/2, 1, &uvt) == kCVReturnSuccess,
              let uvTex = CVMetalTextureGetTexture(uvt!) else { return nil }
        // CVMetalTexture 只需活到 command buffer 完成 —— 本引擎所有使用点都在
        // 函数内同步 flushAndWait（见 convertFrame / roundtripNV12），局部变量
        // 存活期天然覆盖。**不要**往 pb 上挂关联对象：那会把每帧 ~14MB 的
        // IOSurface 纹理钉在解码器缓冲上，解码池一轮换就是几十上百 MB 的常驻。
        return (yTex, uvTex)
    }

    /// 一帧 NV12 → RGB NCHW fp16：模型分辨率写进 imgRing 槽位，源分辨率写进 fullRing 槽位
    private func convertFrame(_ pb: CVPixelBuffer, imgSlot: Int, fullSlot: Int) throws -> (img: MTLBuffer, full: MTLBuffer) {
        poolLock.lock(); convertOps += 1; poolLock.unlock()
        guard let texs = mapNV12Textures(pb) else {
            throw EngineError.setup("NV12 纹理映射失败")
        }
        begin()
        var pIn = NV12InParams(srcWidth: UInt32(srcW), srcHeight: UInt32(srcH),
                               dstWidth: UInt32(modelW), dstHeight: UInt32(modelH),
                               fullRange: fullRange ? 1 : 0, is709: bt709 ? 1 : 0)
        try dispatch("nv12_to_rgb_nchw", [(imgRing[imgSlot].buffer, 0)],
                     textures: [texs.y, texs.uv],
                     bytes: &pIn, length: MemoryLayout<NV12InParams>.size)
        var pFull = NV12InParams(srcWidth: UInt32(srcW), srcHeight: UInt32(srcH),
                                 dstWidth: UInt32(srcW), dstHeight: UInt32(srcH),
                                 fullRange: fullRange ? 1 : 0, is709: bt709 ? 1 : 0)
        try dispatch("nv12_to_rgb_nchw", [(fullRing[fullSlot], 0)],
                     textures: [texs.y, texs.uv],
                     bytes: &pFull, length: MemoryLayout<NV12InParams>.size,
                     grid: MTLSize(width: srcW, height: srcH, depth: 1))
        try flushAndWait()
        return (imgRing[imgSlot].buffer, fullRing[fullSlot])
    }

    // MARK: 对级状态与逐对复用

    func resetPairState() {
        cachedPB = nil
        cachedImg = nil
        cachedFull = nil
        cachedFeatArray = nil
        cachedFeatBuffer = nil
        cachedSlot = -1
        srcImg0 = nil
        srcImg1 = nil
        srcFull0 = nil
        srcFull1 = nil
        f0Buf = nil
        f1Buf = nil
        chainPreparedKey = nil
        retained.removeAll(keepingCapacity: true)
    }

    /// prepare 一对帧：转换（带逐对复用）+ encode（带复用），供后续多个 timestep 复用
    private func preparePair(f0: CVPixelBuffer, f1: CVPixelBuffer) throws {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { pairPrepMS += Self.nowMS(t0) }
        retained.removeAll(keepingCapacity: true)

        // ---- f0：与上一对的 f1 同一缓冲对象 → 直接复用其转换/encode 结果 ----
        if cachedPB === f0, let img = cachedImg, let full = cachedFull,
           let featArr = cachedFeatArray, let featBuf = cachedFeatBuffer {
            srcImg0 = img
            srcFull0 = full
            f0Buf = featBuf
            retained["f0"] = featArr   // 包着的 MTLBuffer 在链路里要一直活着
        } else {
            imgCursor = (imgCursor + 1) % imgRing.count
            fullCursor = (fullCursor + 1) % fullRing.count
            let conv = try convertFrame(f0, imgSlot: imgCursor, fullSlot: fullCursor)
            srcImg0 = conv.img
            srcFull0 = conv.full
            let out = try predict(encodeModel, inputs: ["img": imgRing[imgCursor].array])
            guard let fa = pick(out, "feat", "f") else {
                throw EngineError.output("encode/f0 输出缺失")
            }
            f0Buf = try retain("f0", fa, channels: 4)
        }

        // ---- f1：全新转换 + encode，结果存入缓存供下一对复用 ----
        let f1Slot = (imgCursor + 1) % imgRing.count
        let f1FullSlot = (fullCursor + 1) % fullRing.count
        imgCursor = f1Slot
        fullCursor = f1FullSlot
        let conv1 = try convertFrame(f1, imgSlot: f1Slot, fullSlot: f1FullSlot)
        srcImg1 = conv1.img
        srcFull1 = conv1.full
        let out1 = try predict(encodeModel, inputs: ["img": imgRing[f1Slot].array])
        guard let fa1 = pick(out1, "feat", "f") else {
            throw EngineError.output("encode/f1 输出缺失")
        }
        f1Buf = try retain("f1", fa1, channels: 4)

        // 缓存 f1 供下一对当 f0 复用
        cachedPB = f1
        cachedImg = conv1.img
        cachedFull = conv1.full
        cachedFeatArray = fa1
        cachedFeatBuffer = f1Buf
        cachedSlot = f1Slot
    }

    /// runChain 的懒 prepare（timeline 分支同一对帧跑多次 chain）
    private func preparePairIfNeeded(f0: CVPixelBuffer, f1: CVPixelBuffer) throws {
        if let k = chainPreparedKey, k.0 === f0, k.1 === f1, f0Buf != nil, f1Buf != nil {
            return
        }
        try preparePair(f0: f0, f1: f1)
        chainPreparedKey = (f0, f1)
    }

    // MARK: 主链路（单 timestep，离线工程 interpolate() 的移植）

    /// 返回源分辨率 NV12 插值帧；失败返回 nil（调用方直通原帧）
    func runChain(f0: CVPixelBuffer, f1: CVPixelBuffer, timestep: Float) -> CVPixelBuffer? {
        do {
            try preparePairIfNeeded(f0: f0, f1: f1)
            let t0 = DispatchTime.now().uptimeNanoseconds
            let prep0 = pairPrepMS, blk0 = blockMS, ml0 = metalMS, inf0 = inferMS
            let pb = try chain(timestep: timestep)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            chainCount += 1
            chainTotalMS += ms
            prepTotalMS += pairPrepMS - prep0
            blkTotalMS += blockMS - blk0
            mlTotalMS += metalMS - ml0
            infTotalMS += inferMS - inf0
            if chainCount % 30 == 0 {
                let n = Double(chainCount)
                NSLog("[CoreMLRIFE] 链路均耗 %.1f ms (prep %.1f + infer %.1f [block %.1f] + metal %.1f) → 吞吐上限 %.1f fps",
                      chainTotalMS / n, prepTotalMS / n, infTotalMS / n, blkTotalMS / n,
                      mlTotalMS / n, 1000.0 / (chainTotalMS / n))
            }
            return pb
        } catch {
            NSLog("[CoreMLRIFE] 链路失败，本帧跳过插帧: %@", String(describing: error))
            abortNV12Output()
            resetPairState()
            return nil
        }
    }
    private var chainCount = 0
    private var chainTotalMS = 0.0
    private var pairPrepMS = 0.0
    private var blockMS = 0.0
    private var metalMS = 0.0
    private var inferMS = 0.0
    private var prepTotalMS = 0.0
    private var blkTotalMS = 0.0
    private var mlTotalMS = 0.0
    private var infTotalMS = 0.0
    private static func nowMS(_ t0: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    private func chain(timestep: Float) throws -> CVPixelBuffer {
        guard let img0 = srcImg0, let img1 = srcImg1,
              let f0 = f0Buf, let f1 = f1Buf else {
            throw EngineError.output("pair 未准备好")
        }

        let W = UInt32(modelW), H = UInt32(modelH)
        let sz = MemoryLayout<Params>.size
        // 1) concat15 = [img0(3)|img1(3)|f0(4)|f1(4)|ts(1)] → block0
        begin()
        var c15 = ConcatParams(width: W, height: H, segCount: 5, tsSegIndex: 4, tsValue: timestep)
        try dispatch("concat_multi",
                     [(img0, 0), (img1, 0), (f0, 0), (f1, 0), (f0, 0), (f0, 0), (f0, 0),
                      (segCh15, 0), (block0In.buffer, 0)],
                     bytes: &c15, length: MemoryLayout<ConcatParams>.size)
        try flushAndWait()

        let b0t = DispatchTime.now().uptimeNanoseconds
        let b0 = try predict(blocks[0], inputs: ["x": block0In.array])
        blockMS += Self.nowMS(b0t)
        guard let m0 = pick(b0, "mask"), let ft0 = pick(b0, "feat"), let fl0 = pick(b0, "flow") else {
            throw EngineError.output("block0 输出缺失")
        }
        let mask = try retain("mask", m0, channels: 1)
        let feat = try retain("feat", ft0, channels: 8)
        let flow0 = try retain("flow0", fl0, channels: 4)

        // 2) flowAcc = flow0；warp 出 block1 需要的全部中间量 + concat24
        begin()
        var p4c = Params(width: W, height: H, channels: 4)
        try dispatch("copy_nchw", [(flow0, 0), (flowAcc.buffer, 0)], bytes: &p4c, length: sz)
        try warp(img0, flowAcc.buffer, 0, warped0, 3)
        try warp(img1, flowAcc.buffer, 2, warped1, 3)
        try warp(f0, flowAcc.buffer, 0, wf0, 4)
        try warp(f1, flowAcc.buffer, 2, wf1, 4)
        try concat24(timestep: timestep, mask: mask, feat: feat)
        try flushAndWait()
        retained["flow0"] = nil            // 已拷进 flowAcc，可以释放

        // 3) block1..4
        for i in 1...4 {
            let bit = DispatchTime.now().uptimeNanoseconds
            let out = try predict(blocks[i], inputs: ["x": blockNIn.array, "flow": flowAcc.array])
            blockMS += Self.nowMS(bit)
            guard let fd = pick(out, "fd", "flow"), let nm = pick(out, "mask"),
                  let nf = pick(out, "feat") else {
                throw EngineError.output("block\(i) 输出缺失")
            }
            let fdBuf = try retain("fd", fd, channels: 4)
            let nmBuf = try retain("mask", nm, channels: 1)
            let nfBuf = try retain("feat", nf, channels: 8)

            let last = (i == 4)
            begin()
            var p4a = Params(width: W, height: H, channels: 4)
            // flow += fd（原地累加，逐元素读写同一地址，安全）
            try dispatch("add_nchw", [(flowAcc.buffer, 0), (fdBuf, 0), (flowAcc.buffer, 0)],
                         bytes: &p4a, length: sz)
            if last {
                // 源分辨率融合：flow/mask 上采样，warp/blend 用原始源分辨率帧；
                // NV12 写出内核也排进同一批 —— 一次 GPU 往返完成「融合 + 像素写出」
                let outCtx = try prepareNV12Output()
                let tensor = try blendAtSource(out: outRGBFull, mask: nmBuf)
                try enqueueNV12Kernels(from: tensor, ctx: outCtx)
                try flushAndWait()
                try finishNV12Output(ctx: outCtx)
                return outCtx.pixelBuffer
            } else {
                try warp(img0, flowAcc.buffer, 0, warped0, 3)
                try warp(img1, flowAcc.buffer, 2, warped1, 3)
                try warp(f0, flowAcc.buffer, 0, wf0, 4)
                try warp(f1, flowAcc.buffer, 2, wf1, 4)
                try concat24(timestep: timestep, mask: nmBuf, feat: nfBuf)
            }
            try flushAndWait()
        }

        throw EngineError.output("block4 无输出")
    }

    private func warp(_ src: MTLBuffer, _ flow: MTLBuffer, _ channelOffset: Int,
                      _ out: MTLBuffer, _ channels: Int) throws {
        var p = Params(width: UInt32(modelW), height: UInt32(modelH), channels: UInt32(channels))
        try dispatch("warp_nchw",
                     [(src, 0), (flow, channelOffset * modelH * modelW * 2), (out, 0)],
                     bytes: &p, length: MemoryLayout<Params>.size)
    }

    private func concat24(timestep: Float, mask: MTLBuffer, feat: MTLBuffer) throws {
        var c = ConcatParams(width: UInt32(modelW), height: UInt32(modelH), segCount: 7,
                             tsSegIndex: 4, tsValue: timestep)
        try dispatch("concat_multi",
                     [(warped0, 0), (warped1, 0), (wf0, 0), (wf1, 0),
                      (wf0, 0), (mask, 0), (feat, 0),
                      (segCh24, 0), (blockNIn.buffer, 0)],
                     bytes: &c, length: MemoryLayout<ConcatParams>.size)
    }

    /// 光流/mask 上采样到源分辨率 → warp 原始源帧 → blend → outRGBFull（源分辨率融合）
    private func blendAtSource(out: MTLBuffer, mask: MTLBuffer) throws -> MTLBuffer {
        guard let full0 = srcFull0, let full1 = srcFull1 else {
            throw EngineError.output("源分辨率帧缺失")
        }
        let mw = UInt32(modelW), mh = UInt32(modelH)
        let sw = UInt32(srcW), sh = UInt32(srcH)
        let grid = MTLSize(width: srcW, height: srcH, depth: 1)

        var fp = FlowUpscaleParams(srcWidth: mw, srcHeight: mh, dstWidth: sw, dstHeight: sh,
                                   scaleX: Float(srcW) / Float(modelW),
                                   scaleY: Float(srcH) / Float(modelH))
        try dispatch("flow_upscale_nchw", [(flowAcc.buffer, 0), (flowFull, 0)],
                     bytes: &fp, length: MemoryLayout<FlowUpscaleParams>.size, grid: grid)

        var rp = NCHWResizeParams(srcWidth: mw, srcHeight: mh, dstWidth: sw, dstHeight: sh, channels: 1)
        try dispatch("resize_nchw", [(mask, 0), (maskFull, 0)],
                     bytes: &rp, length: MemoryLayout<NCHWResizeParams>.size, grid: grid)

        var p3s = Params(width: sw, height: sh, channels: 3)
        try dispatch("warp_nchw", [(full0, 0), (flowFull, 0), (warped0Full, 0)],
                     bytes: &p3s, length: MemoryLayout<Params>.size, grid: grid)
        try dispatch("warp_nchw", [(full1, 0), (flowFull, 2 * srcH * srcW * 2), (warped1Full, 0)],
                     bytes: &p3s, length: MemoryLayout<Params>.size, grid: grid)
        try dispatch("blend_nchw", [(warped0Full, 0), (warped1Full, 0), (maskFull, 0), (out, 0)],
                     bytes: &p3s, length: MemoryLayout<Params>.size, grid: grid)
        return out
    }

    /// RGB NCHW fp16（源分辨率）→ NV12 池缓冲（优先零拷贝映射）
    /// NV12 输出上下文：像素缓冲 + GPU 可写目标 + 行距参数
    private struct NV12OutCtx {
        let pixelBuffer: CVPixelBuffer
        let out: MTLBuffer
        let needsCopy: Bool
        let params: NV12OutParams
        let yBase: UnsafeMutableRawPointer
        let totalBytes: Int
    }
    /// 在途输出上下文（runChain 出错路径释放锁用）
    private var pendingNV12: NV12OutCtx?

    /// 第 1 段：拿池缓冲并锁住基址，准备 GPU 写目标（零拷贝映射或 scratch）
    private func prepareNV12Output() throws -> NV12OutCtx {
        poolLock.lock()
        var dstPB: CVPixelBuffer?
        let rc = pool != nil ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &dstPB) : kCVReturnError
        poolCreates += 1
        if let got = dstPB { noteSurface(of: got) }
        poolLock.unlock()
        guard rc == kCVReturnSuccess, let pb = dstPB else {
            throw EngineError.output("NV12 池缓冲分配失败")
        }
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
            throw EngineError.output("NV12 基址锁定失败")
        }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            throw EngineError.output("NV12 平面映射失败")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let uvOffset = Int(UInt(bitPattern: uvBase) - UInt(bitPattern: yBase))
        let total = uvOffset + uvStride * (srcH / 2)

        // 尝试零拷贝直写像素缓冲（IOSurface 基址通常页对齐）
        var target = device.makeBuffer(bytesNoCopy: yBase, length: total,
                                       options: .storageModeShared, deallocator: nil)
        var needsCopy = false
        if target == nil {
            if nv12Scratch == nil || nv12Scratch!.length < total {
                nv12Scratch = device.makeBuffer(length: total, options: .storageModeShared)
            }
            target = nv12Scratch
            needsCopy = true
        }
        guard let out = target else {
            CVPixelBufferUnlockBaseAddress(pb, [])
            throw EngineError.output("NV12 输出缓冲分配失败")
        }
        let ctx = NV12OutCtx(pixelBuffer: pb, out: out, needsCopy: needsCopy,
                             params: NV12OutParams(width: UInt32(srcW), height: UInt32(srcH),
                                                   yStride: UInt32(yStride), uvOffset: UInt32(uvOffset),
                                                   uvStride: UInt32(uvStride),
                                                   fullRange: fullRange ? 1 : 0, is709: bt709 ? 1 : 0),
                             yBase: yBase, totalBytes: total)
        pendingNV12 = ctx
        return ctx
    }

    /// 第 2 段：把 RGB→NV12 的两个内核排进**当前已开的 Metal 批**（不 flush）
    private func enqueueNV12Kernels(from tensor: MTLBuffer, ctx: NV12OutCtx) throws {
        var po = ctx.params
        try dispatch("rgb_nchw_to_nv12_y", [(tensor, 0), (ctx.out, 0)],
                     bytes: &po, length: MemoryLayout<NV12OutParams>.size,
                     grid: MTLSize(width: srcW, height: srcH, depth: 1))
        try dispatch("rgb_nchw_to_nv12_uv", [(tensor, 0), (ctx.out, 0)],
                     bytes: &po, length: MemoryLayout<NV12OutParams>.size,
                     grid: MTLSize(width: srcW / 2, height: srcH / 2, depth: 1))
    }

    /// 第 3 段：flush 已完成后调用 —— 需要时拷回并解锁
    private func finishNV12Output(ctx: NV12OutCtx) throws {
        pendingNV12 = nil
        if ctx.needsCopy {
            _ = memcpy(ctx.yBase, ctx.out.contents(), ctx.totalBytes)
        }
        CVPixelBufferUnlockBaseAddress(ctx.pixelBuffer, [])
    }

    /// 出错路径：释放在途输出的基址锁
    private func abortNV12Output() {
        if let ctx = pendingNV12 {
            pendingNV12 = nil
            CVPixelBufferUnlockBaseAddress(ctx.pixelBuffer, [])
        }
    }

    /// NV12 → RGB NCHW → NV12 往返（与插值链路**完全同一套转换内核**）。
    ///
    /// 为什么存在：显示流里会交替出现三种帧 —— 源帧（解码器直出）、静止拷贝、
    /// 插值帧。插值帧天然经过 NV12→RGB→NV12 往返，与解码器直出的源帧存在
    /// ±1~2 LSB 的量化/色度重采样差；48fps 下两类帧逐帧交替，静态区域的
    /// 细微亮度差就会被眼睛捕捉为「局部亮度闪烁」。把源帧/拷贝帧也送进同一套
    /// 往返内核，三类帧像素处理完全一致，交替差归零。
    /// 代价：每对多 ~2-4ms GPU（4K），双 worker 预算内。
    func roundtripNV12(from src: CVPixelBuffer) -> CVPixelBuffer? {
        do {
            poolLock.lock(); convertOps += 1; poolLock.unlock()
            guard let texs = mapNV12Textures(src) else { return nil }
            begin()
            var pFull = NV12InParams(srcWidth: UInt32(srcW), srcHeight: UInt32(srcH),
                                     dstWidth: UInt32(srcW), dstHeight: UInt32(srcH),
                                     fullRange: fullRange ? 1 : 0, is709: bt709 ? 1 : 0)
            try dispatch("nv12_to_rgb_nchw", [(outRGBFull, 0)],
                         textures: [texs.y, texs.uv],
                         bytes: &pFull, length: MemoryLayout<NV12InParams>.size,
                         grid: MTLSize(width: srcW, height: srcH, depth: 1))
            let ctx = try prepareNV12Output()
            try enqueueNV12Kernels(from: outRGBFull, ctx: ctx)
            try flushAndWait()
            try finishNV12Output(ctx: ctx)
            return ctx.pixelBuffer
        } catch {
            NSLog("[CoreMLRIFE] 源帧往返失败，本帧回退直出: %@", String(describing: error))
            abortNV12Output()
            return nil
        }
    }

    /// NV12 全分辨率拷贝（静止帧垫帧用；CPU memcpy，12MB@1080p 亚毫秒）
    func copyNV12(from src: CVPixelBuffer) -> CVPixelBuffer? {
        poolLock.lock()
        var dstPB: CVPixelBuffer?
        let rc = pool != nil ? CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &dstPB) : kCVReturnError
        poolCreates += 1
        if let got = dstPB { noteSurface(of: got) }
        poolLock.unlock()
        guard rc == kCVReturnSuccess, let dst = dstPB else { return nil }

        guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        for plane in 0..<2 {
            guard let sb = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                  let db = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
            let h = plane == 0 ? srcH : srcH / 2
            let sBpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
            let dBpr = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
            if sBpr == dBpr {
                _ = memcpy(db, sb, sBpr * h)
            } else {
                let copyBytes = min(sBpr, dBpr)
                let dbp = db.assumingMemoryBound(to: UInt8.self)
                let sbp = sb.assumingMemoryBound(to: UInt8.self)
                for row in 0..<h {
                    memcpy(dbp + row * dBpr, sbp + row * sBpr, copyBytes)
                }
            }
        }
        return dst
    }

    /// 打包 4:2:2（YUY2 / 'yuvs'）→ 双平面 NV12：让采集卡也能进补帧链路。
    ///
    /// 源按 rg8Unorm 纹理映射（宽=像素宽、高=像素高），偶数像素的 .g = U、
    /// 奇数像素的 .g = V；Y 逐像素拷贝，UV 按 2×2 块做 4:2:2→4:2:0 纵向平均。
    /// 字节原样搬运、不碰色彩范围，色偏由下游 isFullRange / isBT709 统一处理。
    /// 尺寸须与引擎配置一致（采集分辨率固定，引擎按该分辨率预热），否则回落 nil。
    func convertPacked422ToNV12(from src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard w == srcW, h == srcH else { return nil }
        guard let pso = pipes["yuy2_to_nv12"], let cache = textureCache else { return nil }
        ensurePool()
        guard let pool = pool else { return nil }

        var texRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, src, nil,
                                                       .rg8Unorm, w, h, 0, &texRef) == kCVReturnSuccess,
              let tex = CVMetalTextureGetTexture(texRef!) else { return nil }

        var dstPB: CVPixelBuffer?
        poolLock.lock()
        let rc = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstPB)
        poolLock.unlock()
        guard rc == kCVReturnSuccess, let dst = dstPB else { return nil }
        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(dst, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(dst, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
        guard let yBuf = device.makeBuffer(bytesNoCopy: yBase, length: yStride * h,
                                           options: .storageModeShared, deallocator: nil),
              let uvBuf = device.makeBuffer(bytesNoCopy: uvBase, length: uvStride * (h / 2),
                                           options: .storageModeShared, deallocator: nil) else { return nil }

        var params = YUY2ConvParams(width: UInt32(w), height: UInt32(h),
                                    yStride: UInt32(yStride), uvStride: UInt32(uvStride))
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return nil }
        enc.setComputePipelineState(pso)
        enc.setTexture(tex, index: 0)
        enc.setBuffer(yBuf, offset: 0, index: 0)
        enc.setBuffer(uvBuf, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<YUY2ConvParams>.size, index: 2)
        let grid = MTLSize(width: w, height: h, depth: 1)
        let tg = MTLSize(width: min(pso.threadExecutionWidth, max(1, w)), height: 1, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        if let e = cmd.error {
            NSLog("[CoreMLRIFE] yuy2_to_nv12 失败: %@", e.localizedDescription)
            return nil
        }
        return dst
    }

    /// 预热：跑一次 encode，触发 CoreML/ANE 编译，避免第一帧卡顿
    func warmup() {
        let n = 3 * modelH * modelW
        let p = encodeIn[0].buffer.contents().assumingMemoryBound(to: Float16.self)
        for i in 0..<n { p[i] = Float16(0.5) }
        _ = try? predict(encodeModel, inputs: ["img": encodeIn[0].array])
    }
}

// MARK: - Metal 内核（离线工程 RIFEKernels.metal 全套 + 本工程新增 NV12 互转）

private extension Engine {

    static var metalSource: String { """
    #include <metal_stdlib>
    using namespace metal;

    // 张量统一按 NCHW 排布，fp16 存储：index = ((n*C + c)*H + h)*W + w

    struct WarpParams {
        uint width;
        uint height;
        uint channels;
    };

    // 双线性采样，NCHW，坐标 clamp 到边界（对应 grid_sample padding_mode="border"）
    static inline float sample_nchw(const device half *src, uint C, uint H, uint W,
                                    uint c, float x, float y) {
        x = clamp(x, 0.0f, (float)(W - 1));
        y = clamp(y, 0.0f, (float)(H - 1));
        int x0 = (int)floor(x);
        int y0 = (int)floor(y);
        int x1 = min(x0 + 1, (int)W - 1);
        int y1 = min(y0 + 1, (int)H - 1);
        float fx = x - (float)x0;
        float fy = y - (float)y0;
        uint base = c * H * W;
        float v00 = (float)src[base + (uint)y0 * W + (uint)x0];
        float v10 = (float)src[base + (uint)y0 * W + (uint)x1];
        float v01 = (float)src[base + (uint)y1 * W + (uint)x0];
        float v11 = (float)src[base + (uint)y1 * W + (uint)x1];
        return (v00 * (1 - fx) + v10 * fx) * (1 - fy)
             + (v01 * (1 - fx) + v11 * fx) * fy;
    }

    // warp(tenInput, tenFlow)：tenInput [1,C,H,W]，flow [2,H,W]（像素位移）
    kernel void warp_nchw(const device half *input  [[buffer(0)]],
                          const device half *flow   [[buffer(1)]],
                          device half *out          [[buffer(2)]],
                          constant WarpParams &p    [[buffer(3)]],
                          uint2 gid                 [[thread_position_in_grid]]) {
        uint W = p.width, H = p.height, C = p.channels;
        if (gid.x >= W || gid.y >= H) return;
        uint flowOffset = gid.y * W + gid.x;
        float fx = (float)flow[flowOffset];
        float fy = (float)flow[H * W + flowOffset];
        float sx = (float)gid.x + fx;
        float sy = (float)gid.y + fy;
        for (uint c = 0; c < C; c++) {
            out[(c * H + gid.y) * W + gid.x] = (half)sample_nchw(input, C, H, W, c, sx, sy);
        }
    }

    // 多段拼接（各段独立 buffer）；timestep 段用常量填充
    struct ConcatParams {
        uint width;
        uint height;
        uint segCount;
        uint tsSegIndex;
        float tsValue;
    };

    kernel void concat_multi(const device half *s0   [[buffer(0)]],
                             const device half *s1   [[buffer(1)]],
                             const device half *s2   [[buffer(2)]],
                             const device half *s3   [[buffer(3)]],
                             const device half *s4   [[buffer(4)]],
                             const device half *s5   [[buffer(5)]],
                             const device half *s6   [[buffer(6)]],
                             const device uint *segCh [[buffer(7)]],
                             device half *out        [[buffer(8)]],
                             constant ConcatParams &p [[buffer(9)]],
                             uint2 gid               [[thread_position_in_grid]]) {
        uint W = p.width, H = p.height;
        if (gid.x >= W || gid.y >= H) return;
        uint spatial = gid.y * W + gid.x;
        uint plane = H * W;
        uint chOffset = 0;
        for (uint s = 0; s < p.segCount; s++) {
            uint cs = segCh[s];
            uint dstBase = chOffset * plane;
            if (s == p.tsSegIndex) {
                out[dstBase + spatial] = (half)p.tsValue;
            } else {
                const device half *src = s0;
                if (s == 1) src = s1;
                else if (s == 2) src = s2;
                else if (s == 3) src = s3;
                else if (s == 4) src = s4;
                else if (s == 5) src = s5;
                else if (s == 6) src = s6;
                for (uint c = 0; c < cs; c++) {
                    out[dstBase + c * plane + spatial] = src[c * plane + spatial];
                }
            }
            chOffset += cs;
        }
    }

    kernel void copy_nchw(const device half *src [[buffer(0)]],
                          device half *out       [[buffer(1)]],
                          constant WarpParams &p [[buffer(2)]],
                          uint2 gid              [[thread_position_in_grid]]) {
        uint W = p.width, H = p.height, C = p.channels;
        if (gid.x >= W || gid.y >= H) return;
        uint spatial = gid.y * W + gid.x;
        uint plane = H * W;
        for (uint c = 0; c < C; c++) {
            out[c * plane + spatial] = src[c * plane + spatial];
        }
    }

    // 最终融合：merged = warped0 * sigmoid(mask) + warped1 * (1 - sigmoid(mask))
    kernel void blend_nchw(const device half *w0     [[buffer(0)]],
                           const device half *w1     [[buffer(1)]],
                           const device half *mask   [[buffer(2)]],
                           device half *out          [[buffer(3)]],
                           constant WarpParams &p    [[buffer(4)]],
                           uint2 gid                 [[thread_position_in_grid]]) {
        uint W = p.width, H = p.height, C = p.channels;
        if (gid.x >= W || gid.y >= H) return;
        uint spatial = gid.y * W + gid.x;
        float m = (float)mask[spatial];
        float s = 1.0f / (1.0f + exp(-m));
        for (uint c = 0; c < C; c++) {
            uint idx = c * H * W + spatial;
            float a = (float)w0[idx];
            float b = (float)w1[idx];
            out[idx] = (half)(a * s + b * (1.0f - s));
        }
    }

    // flow 残差累加：flow = flow + fd
    kernel void add_nchw(const device half *a      [[buffer(0)]],
                         const device half *b      [[buffer(1)]],
                         device half *out          [[buffer(2)]],
                         constant WarpParams &p    [[buffer(3)]],
                         uint2 gid                 [[thread_position_in_grid]]) {
        uint W = p.width, H = p.height, C = p.channels;
        if (gid.x >= W || gid.y >= H) return;
        uint spatial = gid.y * W + gid.x;
        for (uint c = 0; c < C; c++) {
            uint idx = c * H * W + spatial;
            out[idx] = (half)((float)a[idx] + (float)b[idx]);
        }
    }

    // NCHW fp16 双线性采样（单个通道）
    static inline float sampleNCHW(const device half *src, uint c,
                                   uint sw, uint sh, float fx, float fy) {
        fx = clamp(fx, 0.0f, (float)(sw - 1));
        fy = clamp(fy, 0.0f, (float)(sh - 1));
        uint x0 = (uint)floor(fx), y0 = (uint)floor(fy);
        uint x1 = min(x0 + 1, sw - 1), y1 = min(y0 + 1, sh - 1);
        float ax = fx - (float)x0, ay = fy - (float)y0;
        uint base = c * sh * sw;
        float v00 = (float)src[base + y0 * sw + x0];
        float v10 = (float)src[base + y0 * sw + x1];
        float v01 = (float)src[base + y1 * sw + x0];
        float v11 = (float)src[base + y1 * sw + x1];
        float v0 = v00 * (1 - ax) + v10 * ax;
        float v1 = v01 * (1 - ax) + v11 * ax;
        return v0 * (1 - ay) + v1 * ay;
    }

    struct NCHWResizeParams {
        uint srcWidth;
        uint srcHeight;
        uint dstWidth;
        uint dstHeight;
        uint channels;
    };

    // flow / mask 的 NCHW 双线性上采样（纯几何放大）
    kernel void resize_nchw(const device half *src              [[buffer(0)]],
                            device half *dst                    [[buffer(1)]],
                            constant NCHWResizeParams &p        [[buffer(2)]],
                            uint2 gid                           [[thread_position_in_grid]]) {
        uint W = p.dstWidth, H = p.dstHeight;
        if (gid.x >= W || gid.y >= H) return;
        float fx = ((float)gid.x + 0.5f) * (float)p.srcWidth  / (float)W - 0.5f;
        float fy = ((float)gid.y + 0.5f) * (float)p.srcHeight / (float)H - 0.5f;
        uint dspatial = gid.y * W + gid.x;
        uint dplane = W * H;
        for (uint c = 0; c < p.channels; c++) {
            dst[c * dplane + dspatial] = (half)sampleNCHW(src, c, p.srcWidth, p.srcHeight, fx, fy);
        }
    }

    struct FlowUpscaleParams {
        uint srcWidth;
        uint srcHeight;
        uint dstWidth;
        uint dstHeight;
        float scaleX;
        float scaleY;
    };

    // 4 通道 flow 场 [f0x, f0y, f1x, f1y] 上采样到源分辨率并换算位移倍率
    kernel void flow_upscale_nchw(const device half *src              [[buffer(0)]],
                                  device half *dst                    [[buffer(1)]],
                                  constant FlowUpscaleParams &p       [[buffer(2)]],
                                  uint2 gid                           [[thread_position_in_grid]]) {
        uint W = p.dstWidth, H = p.dstHeight;
        if (gid.x >= W || gid.y >= H) return;
        float fx = ((float)gid.x + 0.5f) * (float)p.srcWidth  / (float)W - 0.5f;
        float fy = ((float)gid.y + 0.5f) * (float)p.srcHeight / (float)H - 0.5f;
        uint dspatial = gid.y * W + gid.x;
        uint dplane = W * H;
        for (uint c = 0; c < 4; c++) {
            float v = sampleNCHW(src, c, p.srcWidth, p.srcHeight, fx, fy);
            v *= ((c & 1u) == 0u) ? p.scaleX : p.scaleY;
            dst[c * dplane + dspatial] = (half)v;
        }
    }

    // ===== 本工程新增：NV12 ↔ RGB NCHW fp16 互转 =====
    //
    // 输入走 CVMetalTexture（IOSurface 零拷贝映射解码器输出），双线性缩放，
    // BT.601/709 · limited/full range 全支持。采样用 align_corners=False 映射。

    struct NV12InParams {
        uint srcWidth;
        uint srcHeight;
        uint dstWidth;
        uint dstHeight;
        float fullRange;
        float is709;
    };

    kernel void nv12_to_rgb_nchw(texture2d<float, access::read> yTex   [[texture(0)]],
                                 texture2d<float, access::read> uvTex  [[texture(1)]],
                                 device half *out                     [[buffer(0)]],
                                 constant NV12InParams &p             [[buffer(1)]],
                                 uint2 gid                            [[thread_position_in_grid]]) {
        uint W = p.dstWidth, H = p.dstHeight;
        if (gid.x >= W || gid.y >= H) return;

        float fx = ((float)gid.x + 0.5f) * (float)p.srcWidth  / (float)W - 0.5f;
        float fy = ((float)gid.y + 0.5f) * (float)p.srcHeight / (float)H - 0.5f;
        fx = clamp(fx, 0.0f, (float)(p.srcWidth - 1));
        fy = clamp(fy, 0.0f, (float)(p.srcHeight - 1));

        float yv = yTex.read(uint2(fx, fy)).r;
        float2 uv = uvTex.read(uint2(fx / 2.0f, fy / 2.0f)).rg;
        float cb = uv.x - 0.5f;
        float cr = uv.y - 0.5f;

        if (p.fullRange < 0.5f) {
            // limited range: Y [16,235]/255, CbCr [16,240]/255
            yv = (yv - 16.0f / 255.0f) * (255.0f / 219.0f);
            float cs = 255.0f / 224.0f;
            cb *= cs;
            cr *= cs;
        }

        float r, g, b;
        if (p.is709 > 0.5f) {
            r = yv + 1.5748f * cr;
            b = yv + 1.8556f * cb;
            g = yv - 0.1873f * cb - 0.4681f * cr;
        } else {
            r = yv + 1.4020f * cr;
            b = yv + 1.7720f * cb;
            g = yv - 0.3441f * cb - 0.7141f * cr;
        }

        uint spatial = gid.y * W + gid.x;
        uint plane = H * W;
        out[spatial]             = (half)clamp(r, 0.0f, 1.0f);
        out[plane + spatial]     = (half)clamp(g, 0.0f, 1.0f);
        out[2 * plane + spatial] = (half)clamp(b, 0.0f, 1.0f);
    }

    struct NV12OutParams {
        uint width;
        uint height;
        uint yStride;    // Y 平面行距（字节）
        uint uvOffset;   // UV 平面相对缓冲基址的字节偏移
        uint uvStride;   // UV 平面行距（字节）
        float fullRange;
        float is709;
    };

    static inline void rgb_to_yuv(float r, float g, float b, bool fullRange, bool is709,
                                  thread float &Y, thread float &Cb, thread float &Cr) {
        if (is709) {
            if (fullRange) {
                Y  = 0.2126f * r + 0.7152f * g + 0.0722f * b;
                Cb = -0.1146f * r - 0.3854f * g + 0.5f * b + 0.5f;
                Cr = 0.5f * r - 0.4542f * g - 0.0458f * b + 0.5f;
            } else {
                Y  = (16.0f + 65.481f * r + 128.553f * g + 24.966f * b) / 255.0f;
                Cb = (128.0f - 37.797f * r - 74.203f * g + 112.0f * b) / 255.0f;
                Cr = (128.0f + 112.0f * r - 93.786f * g - 18.214f * b) / 255.0f;
            }
        } else {
            if (fullRange) {
                Y  = 0.299f * r + 0.587f * g + 0.114f * b;
                Cb = -0.1687f * r - 0.3313f * g + 0.5f * b + 0.5f;
                Cr = 0.5f * r - 0.4187f * g - 0.0813f * b + 0.5f;
            } else {
                Y  = (16.0f + 65.738f * r + 129.057f * g + 25.064f * b) / 255.0f;
                Cb = (128.0f - 37.945f * r - 74.494f * g + 112.439f * b) / 255.0f;
                Cr = (128.0f + 112.439f * r - 94.154f * g - 18.285f * b) / 255.0f;
            }
        }
    }

    kernel void rgb_nchw_to_nv12_y(const device half *src   [[buffer(0)]],
                                   device uchar *out        [[buffer(1)]],
                                   constant NV12OutParams &p [[buffer(2)]],
                                   uint2 gid                [[thread_position_in_grid]]) {
        uint W = p.width, H = p.height;
        if (gid.x >= W || gid.y >= H) return;
        uint plane = W * H;
        float r = (float)src[gid.y * W + gid.x];
        float g = (float)src[plane + gid.y * W + gid.x];
        float b = (float)src[2 * plane + gid.y * W + gid.x];
        float Y, Cb, Cr;
        rgb_to_yuv(r, g, b, p.fullRange > 0.5f, p.is709 > 0.5f, Y, Cb, Cr);
        out[gid.y * p.yStride + gid.x] = (uchar)(clamp(Y, 0.0f, 1.0f) * 255.0f + 0.5f);
    }

    kernel void rgb_nchw_to_nv12_uv(const device half *src   [[buffer(0)]],
                                    device uchar *out        [[buffer(1)]],
                                    constant NV12OutParams &p [[buffer(2)]],
                                    uint2 gid                [[thread_position_in_grid]]) {
        uint W = p.width, H = p.height;
        uint x = gid.x * 2, y = gid.y * 2;
        if (x >= W || y >= H) return;
        uint plane = W * H;
        // 2x2 平均（与 NV12 下采样一致）
        float r = 0.0f, g = 0.0f, b = 0.0f;
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint sx = min(x + dx, W - 1), sy = min(y + dy, H - 1);
                r += (float)src[sy * W + sx];
                g += (float)src[plane + sy * W + sx];
                b += (float)src[2 * plane + sy * W + sx];
            }
        }
        r /= 4.0f; g /= 4.0f; b /= 4.0f;
        float Y, Cb, Cr;
        rgb_to_yuv(r, g, b, p.fullRange > 0.5f, p.is709 > 0.5f, Y, Cb, Cr);
        device uchar *uv = out + p.uvOffset;
        uv[gid.y * p.uvStride + gid.x * 2]     = (uchar)(clamp(Cb, 0.0f, 1.0f) * 255.0f + 0.5f);
        uv[gid.y * p.uvStride + gid.x * 2 + 1] = (uchar)(clamp(Cr, 0.0f, 1.0f) * 255.0f + 0.5f);
    }

    // ===== 打包 4:2:2（YUY2 / 'yuvs'）→ 双平面 NV12 =====
    //
    // 让采集卡（原生输出 YUY2）也能进真·RIFE 链路：推理引擎按双平面 NV12 取纹理，
    // 直接喂打包缓冲会拿到错误输入甚至失败。这里把 YUY2 解包成 NV12
    //（Y 平面逐像素拷贝；UV 平面把 4:2:2 横向半采样按 2x2 块做 4:2:0 纵向平均）。
    // 像素字节原样拷贝、不做色彩范围换算 —— 色彩范围/矩阵由下游 isFullRange /
    // isBT709 统一处理，与源帧完全一致，不会引入色偏。

    struct YUY2ConvParams {
        uint width;
        uint height;
        uint yStride;
        uint uvStride;
    };

    kernel void yuy2_to_nv12(texture2d<float, access::read> src [[texture(0)]],
                             device uchar *yOut         [[buffer(0)]],
                             device uchar *uvOut        [[buffer(1)]],
                             constant YUY2ConvParams &p [[buffer(2)]],
                             uint2 gid                  [[thread_position_in_grid]]) {
        uint x = gid.x, y = gid.y;
        if (x >= p.width || y >= p.height) return;
        // 源映射为 rg8Unorm（宽=像素宽，高=像素高）：偶数 x 的 .g = U，奇数 x 的 .g = V
        float4 s = src.read(uint2(x, y));
        float Y = s.r;
        yOut[y * p.yStride + x] = (uchar)(clamp(Y, 0.0f, 1.0f) * 255.0f + 0.5f);
        if ((x & 1u) == 0u && (y & 1u) == 0u) {
            float U = s.g;
            float V = src.read(uint2(min(x + 1u, p.width - 1u), y)).g;
            // 4:2:2 → 4:2:0：与下一行做纵向平均（仅当存在下一行）
            if (y + 1u < p.height) {
                float Ud = src.read(uint2(x, y + 1u)).g;
                float Vd = src.read(uint2(min(x + 1u, p.width - 1u), y + 1u)).g;
                U = (U + Ud) * 0.5f;
                V = (V + Vd) * 0.5f;
            }
            uint uvIdx = (y / 2u) * p.uvStride + (x / 2u) * 2u;
            uvOut[uvIdx]     = (uchar)(clamp(U, 0.0f, 1.0f) * 255.0f + 0.5f);
            uvOut[uvIdx + 1] = (uchar)(clamp(V, 0.0f, 1.0f) * 255.0f + 0.5f);
        }
    }
    """ }
}
