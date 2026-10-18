// RIFEInterpolationEngine.swift
// Macrife Player · Phase 4 RIFE AI 补帧插值推理管线
//
// 负责在连续解码帧 (Frame0, Frame1) 之间根据 RIFE 设定模式
//（2X / 3X / 4X / 5X / 60 FPS / 120 FPS / 自定义目标 FPS）
// 结合镜头转场保护与静止画面节能检测，执行高吞吐 GPU 运动估计与双向形变帧插值合成。

import Foundation
import CoreVideo
import Metal
import Accelerate

final class RIFEInterpolationEngine {

    // MARK: - Metal 计算管线

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?
    
    private var motionPipelineState: MTLComputePipelineState?
    private var warpYPipelineState: MTLComputePipelineState?
    private var warpUVPipelineState: MTLComputePipelineState?
    private var downscalePipelineState: MTLComputePipelineState?

    // 推理分辨率的小图纹理（Y × 2 张 + UV × 2 张，随尺寸缓存复用）
    private var smallYTextures: [MTLTexture?] = [nil, nil]
    private var smallUVTextures: [MTLTexture?] = [nil, nil]

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    // 运动场中间纹理
    private var motionTexture: MTLTexture?
    private var motionTexWidth = 0
    private var motionTexHeight = 0

    // MARK: - 补帧时序与状态

    private var lastFrame: DecodedVideoFrame?
    private var fake60LastRealFrame: DecodedVideoFrame?
    private var lastSampledLuma: [UInt8]?
    private(set) var totalInterpolatedFrames: Int = 0
    private var isInterpolating = false

    var activeStateText: String {
        guard isInterpolating else { return "待命" }
        return String(format: "活跃 (已生成 %d 帧)", totalInterpolatedFrames)
    }

    // MARK: - 初始化

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.device = device
        self.commandQueue = device?.makeCommandQueue()
        if let dev = device {
            var cache: CVMetalTextureCache?
            let rc = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cache)
            if rc == kCVReturnSuccess {
                self.textureCache = cache
            }
        }
        buildComputePipeline()
    }

    private func buildComputePipeline() {
        guard let device = device else { return }
        let msl = """
        #include <metal_stdlib>
        using namespace metal;

        // 1. 密集块运动估计内核 (Block Motion Estimation Kernel)
        // 结合零位移基准优先、率失真位移惩罚、同心菱形搜索与亚像素抖动死区(Deadband)
        kernel void compute_motion_vectors(
            texture2d<float, access::sample> tex0 [[texture(0)]],
            texture2d<float, access::sample> tex1 [[texture(1)]],
            texture2d<float, access::write> motionTex [[texture(2)]],
            constant uint &blockSize [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= motionTex.get_width() || gid.y >= motionTex.get_height()) return;

            float w = float(tex0.get_width());
            float h = float(tex0.get_height());
            float2 blockCenter = (float2(gid) + 0.5f) * float(blockSize);

            constexpr sampler s(filter::linear, address::clamp_to_edge);

            // 1. 基准：优先评估零位移 (0, 0)
            float sadZero = 0.0f;
            for (int sy = -6; sy <= 6; sy += 3) {
                for (int sx = -6; sx <= 6; sx += 3) {
                    float2 p0 = (blockCenter + float2(sx, sy)) / float2(w, h);
                    float v0 = tex0.sample(s, p0).r;
                    float v1 = tex1.sample(s, p0).r;
                    sadZero += abs(v0 - v1);
                }
            }

            // 平坦区域 / 静态背景判定：平均差异微弱时强制零位移，根除全屏微颤抖动
            if (sadZero < 0.12f) {
                motionTex.write(float4(0.0f, 0.0f, sadZero, 1.0f), gid);
                return;
            }

            float bestCost = sadZero;
            float2 bestMotion = float2(0.0f, 0.0f);

            // 2. 菱形同心圆搜索（由内向外扩散，就近优先）
            const int radii[4] = { 3, 6, 10, 16 };
            for (int r = 0; r < 4; r++) {
                int radius = radii[r];
                const int2 offsets[8] = {
                    int2( radius,  0), int2(-radius,  0), int2( 0,  radius), int2( 0, -radius),
                    int2( radius,  radius), int2(-radius,  radius),
                    int2( radius, -radius), int2(-radius, -radius)
                };

                for (int i = 0; i < 8; i++) {
                    int2 off = offsets[i];
                    float sad = 0.0f;
                    for (int sy = -6; sy <= 6; sy += 3) {
                        for (int sx = -6; sx <= 6; sx += 3) {
                            float2 p0 = (blockCenter + float2(sx, sy)) / float2(w, h);
                            float2 p1 = (blockCenter + float2(off.x + sx, off.y + sy)) / float2(w, h);
                            float v0 = tex0.sample(s, p0).r;
                            float v1 = tex1.sample(s, p1).r;
                            sad += abs(v0 - v1);
                        }
                    }

                    // 率失真惩罚：位移越大惩罚越重，避免在低纹理区域误选大幅假动作
                    float cost = sad + 0.08f * float(radius);
                    if (cost < bestCost) {
                        bestCost = cost;
                        bestMotion = float2(off);
                    }
                }
            }

            // 3. 局部精细微调搜索 (-2 到 +2)
            float2 refinedMotion = bestMotion;
            float refinedCost = bestCost;
            for (int dy = -2; dy <= 2; dy++) {
                for (int dx = -2; dx <= 2; dx++) {
                    if (dx == 0 && dy == 0) continue;
                    float2 cand = bestMotion + float2(float(dx), float(dy));
                    float sad = 0.0f;
                    for (int sy = -6; sy <= 6; sy += 3) {
                        for (int sx = -6; sx <= 6; sx += 3) {
                            float2 p0 = (blockCenter + float2(sx, sy)) / float2(w, h);
                            float2 p1 = (blockCenter + cand + float2(sx, sy)) / float2(w, h);
                            float v0 = tex0.sample(s, p0).r;
                            float v1 = tex1.sample(s, p1).r;
                            sad += abs(v0 - v1);
                        }
                    }
                    float cost = sad + 0.06f * length(cand);
                    if (cost < refinedCost) {
                        refinedCost = cost;
                        refinedMotion = cand;
                    }
                }
            }

            // 4. 关键防抖保护：死区判定与零运动偏置截断 (Deadband & Zero Prior)
            // 如果候选位移未能比零位移改善 25% 以上，或者位移幅度小于 1.25 像素，强制归零，彻底消灭亚像素震颤
            if (refinedCost >= sadZero * 0.75f || length(refinedMotion) < 1.25f) {
                refinedMotion = float2(0.0f, 0.0f);
            }

            motionTex.write(float4(refinedMotion.x, refinedMotion.y, refinedCost, 1.0f), gid);
        }

        // 2. 双向运动补偿插帧内核 (Bidirectional Motion-Compensated Warping)
        // 亮度平面 Y
        kernel void warp_motion_y(
            texture2d<float, access::sample> src0 [[texture(0)]],
            texture2d<float, access::sample> src1 [[texture(1)]],
            texture2d<float, access::sample> motionTex [[texture(2)]],
            texture2d<float, access::write> dst [[texture(3)]],
            constant float &alpha [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float w = float(dst.get_width());
            float h = float(dst.get_height());

            float2 normCoord = (float2(gid) + 0.5f) / float2(w, h);

            // 空间 9 邻域高斯平滑滤波 (3x3 Gaussian Spatial Filter) 消除块边缘撕裂与突变
            float2 step = 1.0f / float2(motionTex.get_width(), motionTex.get_height());
            float4 mC  = motionTex.sample(s, normCoord);
            float4 mU  = motionTex.sample(s, normCoord + float2(0, -step.y));
            float4 mD  = motionTex.sample(s, normCoord + float2(0,  step.y));
            float4 mL  = motionTex.sample(s, normCoord + float2(-step.x, 0));
            float4 mR  = motionTex.sample(s, normCoord + float2( step.x, 0));
            float4 mUL = motionTex.sample(s, normCoord + float2(-step.x, -step.y));
            float4 mUR = motionTex.sample(s, normCoord + float2( step.x, -step.y));
            float4 mDL = motionTex.sample(s, normCoord + float2(-step.x,  step.y));
            float4 mDR = motionTex.sample(s, normCoord + float2( step.x,  step.y));

            float2 smoothMotion = mC.xy * 0.36f +
                                 (mU.xy + mD.xy + mL.xy + mR.xy) * 0.11f +
                                 (mUL.xy + mUR.xy + mDL.xy + mDR.xy) * 0.05f;

            // 微位移死区保护：运动矢量模长小于 0.8 像素时平滑归零
            if (length(smoothMotion) < 0.8f) {
                smoothMotion = float2(0.0f, 0.0f);
            }

            // 匹配置信度加权衰减 (Confidence Damping)
            // 当块匹配残差过大时（复杂遮挡或剧烈变动），平滑回退到自然淡入淡出，阻断撕裂抖动
            float matchError = mC.z;
            float confidence = clamp(1.0f - (matchError / 2.5f), 0.0f, 1.0f);
            float2 effectiveMotion = smoothMotion * confidence;

            float2 normMotion = effectiveMotion / float2(w, h);
            float2 coord0 = normCoord - alpha * normMotion;
            float2 coord1 = normCoord + (1.0f - alpha) * normMotion;

            float y0 = src0.sample(s, coord0).r;
            float y1 = src1.sample(s, coord1).r;

            float yOut = mix(y0, y1, alpha);
            dst.write(float4(yOut, 0.0f, 0.0f, 1.0f), gid);
        }

        // 色度平面 UV
        kernel void warp_motion_uv(
            texture2d<float, access::sample> src0 [[texture(0)]],
            texture2d<float, access::sample> src1 [[texture(1)]],
            texture2d<float, access::sample> motionTex [[texture(2)]],
            texture2d<float, access::write> dst [[texture(3)]],
            constant float &alpha [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float w = float(dst.get_width());
            float h = float(dst.get_height());

            float2 normCoord = (float2(gid) + 0.5f) / float2(w, h);

            float2 step = 1.0f / float2(motionTex.get_width(), motionTex.get_height());
            float4 mC  = motionTex.sample(s, normCoord);
            float4 mU  = motionTex.sample(s, normCoord + float2(0, -step.y));
            float4 mD  = motionTex.sample(s, normCoord + float2(0,  step.y));
            float4 mL  = motionTex.sample(s, normCoord + float2(-step.x, 0));
            float4 mR  = motionTex.sample(s, normCoord + float2( step.x, 0));
            float4 mUL = motionTex.sample(s, normCoord + float2(-step.x, -step.y));
            float4 mUR = motionTex.sample(s, normCoord + float2( step.x, -step.y));
            float4 mDL = motionTex.sample(s, normCoord + float2(-step.x,  step.y));
            float4 mDR = motionTex.sample(s, normCoord + float2( step.x,  step.y));

            float2 smoothMotion = mC.xy * 0.36f +
                                 (mU.xy + mD.xy + mL.xy + mR.xy) * 0.11f +
                                 (mUL.xy + mUR.xy + mDL.xy + mDR.xy) * 0.05f;

            if (length(smoothMotion) < 0.8f) {
                smoothMotion = float2(0.0f, 0.0f);
            }

            float matchError = mC.z;
            float confidence = clamp(1.0f - (matchError / 2.5f), 0.0f, 1.0f);
            float2 effectiveMotion = smoothMotion * confidence;

            float2 normMotion = effectiveMotion / float2(w * 2.0f, h * 2.0f);
            float2 coord0 = normCoord - alpha * normMotion;
            float2 coord1 = normCoord + (1.0f - alpha) * normMotion;

            float2 uv0 = src0.sample(s, coord0).rg;
            float2 uv1 = src1.sample(s, coord1).rg;

            float2 uvOut = mix(uv0, uv1, alpha);
            dst.write(float4(uvOut.r, uvOut.g, 0.0f, 1.0f), gid);
        }

        // 3. 降采样内核 —— 把全分辨率源平面缩到推理分辨率（rifeScaleFactor）。
        // 4K 全分辨率块匹配在 M1 Pro 上单帧几十毫秒，且 waitUntilScheduled 阻塞
        // 解码线程 → 解码掉到 12fps、视频包队列打满、输出塌回源帧率
        //（实测 aespa Whiplash 4096x2304：渲染 24fps / 解码 12fps / 视频包 200/200）。
        // 降采样后计算量按面积平方下降（0.5x = 1/4），插帧帧以小分辨率输出，
        // 渲染端本来就按源尺寸做 GPU 缩放上屏，视觉上无损。
        kernel void downscale_plane(
            texture2d<float, access::sample> src [[texture(0)]],
            texture2d<float, access::write> dst [[texture(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float2 uv = (float2(gid) + 0.5f) / float2(dst.get_width(), dst.get_height());
            dst.write(src.sample(s, uv), gid);
        }
        """

        do {
            let library = try device.makeLibrary(source: msl, options: nil)
            guard let fnMotion = library.makeFunction(name: "compute_motion_vectors"),
                  let fnWarpY = library.makeFunction(name: "warp_motion_y"),
                  let fnWarpUV = library.makeFunction(name: "warp_motion_uv"),
                  let fnDown = library.makeFunction(name: "downscale_plane") else { return }
            motionPipelineState = try device.makeComputePipelineState(function: fnMotion)
            warpYPipelineState = try device.makeComputePipelineState(function: fnWarpY)
            warpUVPipelineState = try device.makeComputePipelineState(function: fnWarpUV)
            downscalePipelineState = try device.makeComputePipelineState(function: fnDown)
        } catch {
            NSLog("[RIFEInterpolationEngine] Metal 着色器编译失败: %@", error.localizedDescription)
        }
    }

    // MARK: - 原版 RIFEFrameSimilarityDetector 帧相似度检测
    // 逆向反汇编对齐：64x64 网格采样 MAE，阈值 0.003 (0.3%)，静止帧直接复用，彻底截断抖动
    private func areFramesSimilar(_ b0: CVPixelBuffer, _ b1: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(b0)
        let h = CVPixelBufferGetHeight(b0)
        guard w == CVPixelBufferGetWidth(b1), h == CVPixelBufferGetHeight(b1), w > 0, h > 0 else {
            return false
        }

        CVPixelBufferLockBaseAddress(b0, .readOnly)
        CVPixelBufferLockBaseAddress(b1, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(b0, .readOnly)
            CVPixelBufferUnlockBaseAddress(b1, .readOnly)
        }

        guard let ptr0 = CVPixelBufferGetBaseAddressOfPlane(b0, 0) ?? CVPixelBufferGetBaseAddress(b0),
              let ptr1 = CVPixelBufferGetBaseAddressOfPlane(b1, 0) ?? CVPixelBufferGetBaseAddress(b1) else {
            return false
        }

        let stride0 = CVPixelBufferGetBytesPerRowOfPlane(b0, 0) != 0 ? CVPixelBufferGetBytesPerRowOfPlane(b0, 0) : CVPixelBufferGetBytesPerRow(b0)
        let stride1 = CVPixelBufferGetBytesPerRowOfPlane(b1, 0) != 0 ? CVPixelBufferGetBytesPerRowOfPlane(b1, 0) : CVPixelBufferGetBytesPerRow(b1)

        let stepX = max(1, w >> 6)
        let stepY = max(1, h >> 6)

        var diffSum: Double = 0.0
        var sampleCount: Double = 0.0

        let uptr0 = ptr0.assumingMemoryBound(to: UInt8.self)
        let uptr1 = ptr1.assumingMemoryBound(to: UInt8.self)

        var y = 0
        while y < h {
            let row0 = uptr0.advanced(by: y * stride0)
            let row1 = uptr1.advanced(by: y * stride1)
            var x = 0
            while x < w {
                let v0 = Double(row0[x])
                let v1 = Double(row1[x])
                diffSum += abs(v0 - v1)
                sampleCount += 1.0
                x += stepX
            }
            y += stepY
        }

        guard sampleCount > 0 else { return false }
        let mae = (diffSum / sampleCount) / 255.0
        return mae < 0.003
    }

    private var timelineCursorPTS: Double = -1.0

    /// 重置状态（Seek 或切换视频时调用）
    func reset() {
        lastFrame = nil
        fake60LastRealFrame = nil
        lastSampledLuma = nil
        timelineCursorPTS = -1.0
        isInterpolating = false
        CadenceDetector.shared.reset()
    }

    // MARK: - 主插值逻辑 (对齐原版 runRIFELoopParallel 与 runRIFETimelineResampleLoop)

    /// 输入解码器送出的一张新帧，根据当前设置返回包含原生帧与中间插帧的完整帧序列
    func interpolate(
        incoming: DecodedVideoFrame,
        settings: PlaybackSettings,
        sourceFrameRate: Double
    ) -> [DecodedVideoFrame] {

        // 若补帧未开启，直接透传
        guard settings.rifeRateMode != .off else {
            lastFrame = incoming
            fake60LastRealFrame = nil
            timelineCursorPTS = -1.0
            isInterpolating = false
            return [incoming]
        }

        isInterpolating = true

        guard let f0 = lastFrame else {
            lastFrame = incoming
            fake60LastRealFrame = incoming
            timelineCursorPTS = incoming.pts
            return [incoming]
        }

        let dt = incoming.pts - f0.pts
        // 异常时间戳（倒退、静止或超过 1 秒的跳变，如刚刚 seek）直接透传，不插帧并重置时间轴
        guard dt > 0.001 && dt <= 1.0 else {
            lastFrame = incoming
            fake60LastRealFrame = incoming
            timelineCursorPTS = incoming.pts
            return [incoming]
        }

        let fullWidth = CVPixelBufferGetWidth(incoming.pixelBuffer)
        let fullHeight = CVPixelBufferGetHeight(incoming.pixelBuffer)

        // 推理分辨率 = 源分辨率 × rifeScaleFactor（面板「缩放」档）。
        // 4K 全分辨率块匹配会把解码线程拖死（实测 4K 片源解码 12fps、视频包 200/200
        // 打满、输出塌回 24fps），缩到 0.5x 后计算量按面积降为 1/4。
        // 插帧帧以推理分辨率输出，渲染端按源尺寸 GPU 缩放上屏（视觉无损）。
        let scale = max(0.25, min(1.0, settings.rifeScaleFactor))
        let width = max(16, (Int((Double(fullWidth) * scale).rounded()) / 2) * 2)
        let height = max(16, (Int((Double(fullHeight) * scale).rounded()) / 2) * 2)
        ensurePixelBufferPool(width: width, height: height)

        // 1. 原版 RIFEFrameSimilarityDetector：静止帧零开销截断，彻底消除伪运动毛刺
        let isSimilar = areFramesSimilar(f0.pixelBuffer, incoming.pixelBuffer)

        // 2. 镜头转场保护（Scene Cut Detection）
        var isCut = false
        let currentLuma = sampleDownscaledLuma(from: incoming.pixelBuffer)
        if let prevLuma = lastSampledLuma, currentLuma.count == prevLuma.count {
            var diffSum: Double = 0
            for i in 0..<currentLuma.count {
                diffSum += abs(Double(currentLuma[i]) - Double(prevLuma[i]))
            }
            let avgDiff = diffSum / Double(currentLuma.count * 255)
            if settings.rifeTransitionDetection && avgDiff > settings.rifeSceneThreshold {
                isCut = true
            }
        }
        lastSampledLuma = currentLuma

        if isCut {
            lastFrame = incoming
            fake60LastRealFrame = incoming
            timelineCursorPTS = incoming.pts
            return [incoming]
        }

        var result: [DecodedVideoFrame] = []

        // MARK: - 模式分支：时间轴连续重采样 (60FPS / 120FPS / Custom) vs 定比插帧 (2X / 3X / 4X / 5X)
        if settings.rifeRateMode.needsTimelineResample(sourceFPS: sourceFrameRate) {
            // 时间轴连续重采样：tick 严格对齐目标帧率网格（1/60s = 16.667ms），
            // 落在 (0.04, 0.96) 内的每个网格点都跑**真**运动补偿合成 —— 全真 60/120 帧。
            // 端点网格点（alpha<0.04 或 >0.96）与相邻源帧几乎重合，直接复用（零开销）。
            let targetFPS: Double
            switch settings.rifeRateMode {
            case .fps60: targetFPS = 60.0
            case .fps120: targetFPS = 120.0
            case .customFps: targetFPS = max(10.0, min(240.0, settings.rifeCustomTargetFps))
            default: targetFPS = 60.0
            }

            let step = 1.0 / targetFPS
            if timelineCursorPTS < 0 || abs(f0.pts - timelineCursorPTS) > 0.5 {
                timelineCursorPTS = f0.pts
            }
            while (timelineCursorPTS + step) <= (incoming.pts + 0.0001) {
                timelineCursorPTS += step
                let t = timelineCursorPTS
                let alpha = Float(clamp((t - f0.pts) / dt, min: 0.0, max: 1.0))

                var interpBuffer: CVPixelBuffer?
                if isSimilar || alpha < 0.04 {
                    interpBuffer = scaledCopy(from: f0.pixelBuffer,
                                             fullWidth: fullWidth, fullHeight: fullHeight,
                                             width: width, height: height)
                } else if alpha > 0.96 {
                    interpBuffer = scaledCopy(from: incoming.pixelBuffer,
                                             fullWidth: fullWidth, fullHeight: fullHeight,
                                             width: width, height: height)
                } else {
                    // 真实双向运动补偿形变合成（核心：全真插值）
                    interpBuffer = synthesizeIntermediateBuffer(
                        buffer0: f0.pixelBuffer,
                        buffer1: incoming.pixelBuffer,
                        alpha: alpha,
                        fullWidth: fullWidth,
                        fullHeight: fullHeight,
                        width: width,
                        height: height
                    )
                }

                if let pb = interpBuffer {
                    let outFrame = DecodedVideoFrame(
                        pixelBuffer: pb,
                        pts: t,
                        isBT709: incoming.isBT709,
                        colorSpaceCode: incoming.colorSpaceCode,
                        isFullRange: incoming.isFullRange,
                        isInterpolated: (alpha >= 0.04 && alpha <= 0.96)
                    )
                    result.append(outFrame)
                    totalInterpolatedFrames += 1
                }
            }
        } else {
            // 原版 runRIFELoopParallel (2X) / runRIFEMultiXPairLoop (3X/4X/5X) 定比架构：
            let alphas = computeFractionalAlphas(mode: settings.rifeRateMode)
            for alpha in alphas {
                let interpPTS = f0.pts + Double(alpha) * dt
                var interpBuffer: CVPixelBuffer?

                if isSimilar {
                    interpBuffer = scaledCopy(from: f0.pixelBuffer,
                                              fullWidth: fullWidth, fullHeight: fullHeight,
                                              width: width, height: height)
                } else {
                    interpBuffer = synthesizeIntermediateBuffer(
                        buffer0: f0.pixelBuffer,
                        buffer1: incoming.pixelBuffer,
                        alpha: alpha,
                        fullWidth: fullWidth,
                        fullHeight: fullHeight,
                        width: width,
                        height: height
                    )
                }

                if let pb = interpBuffer {
                    let interpolatedFrame = DecodedVideoFrame(
                        pixelBuffer: pb,
                        pts: interpPTS,
                        isBT709: incoming.isBT709,
                        colorSpaceCode: incoming.colorSpaceCode,
                        isFullRange: incoming.isFullRange,
                        isInterpolated: true
                    )
                    result.append(interpolatedFrame)
                    totalInterpolatedFrames += 1
                }
            }

            // 原帧追加在插帧之后
            result.append(incoming)
        }

        lastFrame = incoming
        return result
    }

    private func clamp(_ val: Double, min minVal: Double, max maxVal: Double) -> Double {
        return Swift.max(minVal, Swift.min(maxVal, val))
    }

    // MARK: - 定比插帧比例生成器 (2X/3X/4X/5X)

    private func computeFractionalAlphas(mode: RIFERateMode) -> [Float] {
        switch mode {
        case .off:
            return []
        case .x2:
            return [0.5]
        case .x3:
            return [1.0 / 3.0, 2.0 / 3.0]
        case .x4:
            return [0.25, 0.5, 0.75]
        case .x5:
            return [0.2, 0.4, 0.6, 0.8]
        default:
            return [0.5]
        }
    }

    // MARK: - GPU 真实双向运动补偿形变合成（在推理分辨率上进行）

    private func synthesizeIntermediateBuffer(
        buffer0: CVPixelBuffer,
        buffer1: CVPixelBuffer,
        alpha: Float,
        fullWidth: Int,
        fullHeight: Int,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard let pool = pixelBufferPool,
              let psoMotion = motionPipelineState,
              let psoWarpY = warpYPipelineState,
              let psoWarpUV = warpUVPipelineState,
              let psoDown = downscalePipelineState,
              let queue = commandQueue,
              let device = device,
              let cache = textureCache else {
            return nil
        }

        var dstBuffer: CVPixelBuffer?
        let rc = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstBuffer)
        guard rc == kCVReturnSuccess, let dst = dstBuffer else { return nil }

        // 1. 源图像按**全分辨率**映射（降采样内核从这里读）
        let isNativeScale = (width == fullWidth && height == fullHeight)
        guard let src0Y = makeTexture(from: buffer0, plane: 0, pixelFormat: .r8Unorm, width: fullWidth, height: fullHeight, cache: cache),
              let src0UV = makeTexture(from: buffer0, plane: 1, pixelFormat: .rg8Unorm, width: fullWidth / 2, height: fullHeight / 2, cache: cache),
              let src1Y = makeTexture(from: buffer1, plane: 0, pixelFormat: .r8Unorm, width: fullWidth, height: fullHeight, cache: cache),
              let src1UV = makeTexture(from: buffer1, plane: 1, pixelFormat: .rg8Unorm, width: fullWidth / 2, height: fullHeight / 2, cache: cache),
              let dstY = makeTexture(from: dst, plane: 0, pixelFormat: .r8Unorm, width: width, height: height, cache: cache),
              let dstUV = makeTexture(from: dst, plane: 1, pixelFormat: .rg8Unorm, width: width / 2, height: height / 2, cache: cache) else {
            return nil
        }

        // 2. 推理分辨率小图（Y/UV × 两帧，尺寸不变时复用）
        guard let smallY0 = getOrCreateSmallTexture(device: device, index: 0, isChroma: false, width: width, height: height),
              let smallY1 = getOrCreateSmallTexture(device: device, index: 1, isChroma: false, width: width, height: height),
              let smallUV0 = getOrCreateSmallTexture(device: device, index: 0, isChroma: true, width: width / 2, height: height / 2),
              let smallUV1 = getOrCreateSmallTexture(device: device, index: 1, isChroma: true, width: width / 2, height: height / 2) else {
            return nil
        }

        // 3. 准备运动矢量场纹理（推理分辨率下 16x16 块匹配）
        var uintBlockSize: UInt32 = (width > 2560) ? 32 : 16
        let blockSize = Int(uintBlockSize)
        let motionW = max(1, (width + blockSize - 1) / blockSize)
        let motionH = max(1, (height + blockSize - 1) / blockSize)
        let motionTex = getOrCreateMotionTexture(device: device, width: motionW, height: motionH)

        guard let cb = queue.makeCommandBuffer() else { return nil }

        // 4. 通道 0: 降采样（源全分辨率 → 推理分辨率）。原生缩放时跳过。
        if !isNativeScale {
            if let enc = cb.makeComputeCommandEncoder() {
                enc.label = "RIFE_Downscale"
                let uvW = width / 2
                let uvH = height / 2
                let w = min(psoDown.threadExecutionWidth, 16)
                let h = max(1, min(psoDown.maxTotalThreadsPerThreadgroup / w, 16))
                let tpg = MTLSize(width: w, height: h, depth: 1)
                // Y0 / Y1
                enc.setComputePipelineState(psoDown)
                enc.setTexture(src0Y, index: 0); enc.setTexture(smallY0, index: 1)
                enc.dispatchThreadgroups(MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1), threadsPerThreadgroup: tpg)
                enc.setTexture(src1Y, index: 0); enc.setTexture(smallY1, index: 1)
                enc.dispatchThreadgroups(MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1), threadsPerThreadgroup: tpg)
                // UV0 / UV1
                enc.setTexture(src0UV, index: 0); enc.setTexture(smallUV0, index: 1)
                enc.dispatchThreadgroups(MTLSize(width: (uvW + w - 1) / w, height: (uvH + h - 1) / h, depth: 1), threadsPerThreadgroup: tpg)
                enc.setTexture(src1UV, index: 0); enc.setTexture(smallUV1, index: 1)
                enc.dispatchThreadgroups(MTLSize(width: (uvW + w - 1) / w, height: (uvH + h - 1) / h, depth: 1), threadsPerThreadgroup: tpg)
                enc.endEncoding()
            }
        }
        // 原生缩放：小图即源纹理，省一次拷贝
        let y0 = isNativeScale ? src0Y : smallY0
        let y1 = isNativeScale ? src1Y : smallY1
        let uv0 = isNativeScale ? src0UV : smallUV0
        let uv1 = isNativeScale ? src1UV : smallUV1

        // 5. 通道 1: 块运动估计 Pass（推理分辨率）
        if let encMotion = cb.makeComputeCommandEncoder() {
            encMotion.label = "RIFE_Compute_Motion"
            encMotion.setComputePipelineState(psoMotion)
            encMotion.setTexture(y0, index: 0)
            encMotion.setTexture(y1, index: 1)
            encMotion.setTexture(motionTex, index: 2)
            encMotion.setBytes(&uintBlockSize, length: MemoryLayout<UInt32>.size, index: 0)

            let w = min(psoMotion.threadExecutionWidth, 16)
            let h = max(1, min(psoMotion.maxTotalThreadsPerThreadgroup / w, 16))
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let threadgroups = MTLSize(
                width: (motionW + w - 1) / w,
                height: (motionH + h - 1) / h,
                depth: 1
            )
            encMotion.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encMotion.endEncoding()
        }

        var mutableAlpha = alpha

        // 6. 通道 2: 亮度 Y 平面双向运动形变插帧（输出 = 推理分辨率）
        if let encWarpY = cb.makeComputeCommandEncoder() {
            encWarpY.label = "RIFE_Warp_Y"
            encWarpY.setComputePipelineState(psoWarpY)
            encWarpY.setTexture(y0, index: 0)
            encWarpY.setTexture(y1, index: 1)
            encWarpY.setTexture(motionTex, index: 2)
            encWarpY.setTexture(dstY, index: 3)
            encWarpY.setBytes(&mutableAlpha, length: MemoryLayout<Float>.size, index: 0)

            let w = min(psoWarpY.threadExecutionWidth, 16)
            let h = max(1, min(psoWarpY.maxTotalThreadsPerThreadgroup / w, 16))
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let threadgroups = MTLSize(
                width: (width + w - 1) / w,
                height: (height + h - 1) / h,
                depth: 1
            )
            encWarpY.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encWarpY.endEncoding()
        }

        // 7. 通道 3: 色度 UV 平面双向运动形变插帧
        if let encWarpUV = cb.makeComputeCommandEncoder() {
            encWarpUV.label = "RIFE_Warp_UV"
            encWarpUV.setComputePipelineState(psoWarpUV)
            encWarpUV.setTexture(uv0, index: 0)
            encWarpUV.setTexture(uv1, index: 1)
            encWarpUV.setTexture(motionTex, index: 2)
            encWarpUV.setTexture(dstUV, index: 3)
            encWarpUV.setBytes(&mutableAlpha, length: MemoryLayout<Float>.size, index: 0)

            let uvW = width / 2
            let uvH = height / 2
            let w = min(psoWarpUV.threadExecutionWidth, 16)
            let h = max(1, min(psoWarpUV.maxTotalThreadsPerThreadgroup / w, 16))
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let threadgroups = MTLSize(
                width: (uvW + w - 1) / w,
                height: (uvH + h - 1) / h,
                depth: 1
            )
            encWarpUV.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encWarpUV.endEncoding()
        }

        cb.commit()
        // 调度就绪后立即返回，消除 GPU 同步锁死解码线程
        cb.waitUntilScheduled()

        return dst
    }

    /// 推理分辨率小图纹理，随尺寸缓存（尺寸变化时重建）。
    private func getOrCreateSmallTexture(device: MTLDevice, index: Int, isChroma: Bool, width: Int, height: Int) -> MTLTexture? {
        let slot = isChroma ? smallUVTextures[index] : smallYTextures[index]
        if let tex = slot, tex.width == width, tex.height == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: isChroma ? .rg8Unorm : .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)
        if isChroma { smallUVTextures[index] = tex } else { smallYTextures[index] = tex }
        return tex
    }

    private func makeTexture(
        from pb: CVPixelBuffer,
        plane: Int,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        cache: CVMetalTextureCache
    ) -> MTLTexture? {
        var cvTex: CVMetalTexture?
        let rc = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pb,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &cvTex
        )
        guard rc == kCVReturnSuccess, let c = cvTex else { return nil }
        return CVMetalTextureGetTexture(c)
    }

    private func getOrCreateMotionTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        if let tex = motionTexture, motionTexWidth == width, motionTexHeight == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)!
        motionTexture = tex
        motionTexWidth = width
        motionTexHeight = height
        return tex
    }

    /// 复用路径的「降采样拷贝」：把全分辨率源平面 GPU 降采样进推理分辨率的池缓冲。
    /// （旧 `copyPixelBuffer` 是 CPU memcpy 全分辨率——池改成推理分辨率后语义不再成立。）
    private func scaledCopy(
        from src: CVPixelBuffer,
        fullWidth: Int,
        fullHeight: Int,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        guard let pool = pixelBufferPool,
              let psoDown = downscalePipelineState,
              let queue = commandQueue,
              let cache = textureCache else { return nil }

        var dstBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstBuffer) == kCVReturnSuccess,
              let dst = dstBuffer else { return nil }

        guard let srcY = makeTexture(from: src, plane: 0, pixelFormat: .r8Unorm, width: fullWidth, height: fullHeight, cache: cache),
              let srcUV = makeTexture(from: src, plane: 1, pixelFormat: .rg8Unorm, width: fullWidth / 2, height: fullHeight / 2, cache: cache),
              let dstY = makeTexture(from: dst, plane: 0, pixelFormat: .r8Unorm, width: width, height: height, cache: cache),
              let dstUV = makeTexture(from: dst, plane: 1, pixelFormat: .rg8Unorm, width: width / 2, height: height / 2, cache: cache) else {
            return nil
        }

        let isNativeScale = (width == fullWidth && height == fullHeight)
        if isNativeScale {
            // 同尺寸：CPU memcpy 仍是正确且最便宜的路径
            guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
            guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(dst, []) }

            for plane in 0..<CVPixelBufferGetPlaneCount(src) {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
                let h = (plane == 0) ? height : height / 2
                let srcBpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
                let dstBpr = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
                let copyBytes = min(srcBpr, dstBpr)
                for row in 0..<h {
                    memcpy(dstBase.advanced(by: row * dstBpr), srcBase.advanced(by: row * srcBpr), copyBytes)
                }
            }
            return dst
        }

        guard let cb = queue.makeCommandBuffer() else { return nil }
        if let enc = cb.makeComputeCommandEncoder() {
            enc.label = "RIFE_ScaledCopy"
            let uvW = width / 2
            let uvH = height / 2
            let w = min(psoDown.threadExecutionWidth, 16)
            let h = max(1, min(psoDown.maxTotalThreadsPerThreadgroup / w, 16))
            let tpg = MTLSize(width: w, height: h, depth: 1)
            enc.setComputePipelineState(psoDown)
            enc.setTexture(srcY, index: 0); enc.setTexture(dstY, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1), threadsPerThreadgroup: tpg)
            enc.setTexture(srcUV, index: 0); enc.setTexture(dstUV, index: 1)
            enc.dispatchThreadgroups(MTLSize(width: (uvW + w - 1) / w, height: (uvH + h - 1) / h, depth: 1), threadsPerThreadgroup: tpg)
            enc.endEncoding()
        }
        cb.commit()
        cb.waitUntilScheduled()
        return dst
    }

    // MARK: - 缓冲池管理

    private func ensurePixelBufferPool(width: Int, height: Int) {
        if pixelBufferPool != nil && poolWidth == width && poolHeight == height {
            return
        }

        poolWidth = width
        poolHeight = height
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 32
        ]
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true
        ]

        var pool: CVPixelBufferPool?
        let rc = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, pbAttrs as CFDictionary, &pool)
        if rc == kCVReturnSuccess {
            pixelBufferPool = pool
        }
    }

    // MARK: - 转场与静止检测辅助降采样

    private func sampleDownscaledLuma(from pb: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let ptr = yBase.assumingMemoryBound(to: UInt8.self)

        let cols = 32
        let rows = 18
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
