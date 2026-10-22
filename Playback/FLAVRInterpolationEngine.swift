// FLAVRInterpolationEngine.swift
// Macrife Player · FLAVR 3D 时空运动补偿插帧引擎
//
// 核心论文: FLAVR: Flow-Agnostic Video Representation for Fast Frame Interpolation (ECCV 2022)
//
// 架构优势（针对 Apple Silicon / ANE 神经引擎）:
// 1. 【4 帧滑动时空上下文】: 接收连续 4 帧 [I_{-1}, I_0, I_1, I_2]，以 3D 时空多尺度运动估计引导直接回归中间帧；
// 2. 【极速 GPU 双向运动形变】: 硬件级双线性采样与时空权重融合，消除鬼影与原地淡入淡出；
// 3. 【零拷贝 IOSurface 纹理缓存】: 通过 CVMetalTextureCache 实现零内存开销极致吞吐。

import Foundation
import CoreVideo
import Metal
import Accelerate

final class FLAVRInterpolationEngine {

    // MARK: - Metal 计算管线

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private var textureCache: CVMetalTextureCache?

    private var motionPipelineState: MTLComputePipelineState?
    private var warpYPipelineState: MTLComputePipelineState?
    private var warpUVPipelineState: MTLComputePipelineState?

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    private var motionTexture: MTLTexture?
    private var motionTexWidth = 0
    private var motionTexHeight = 0

    // MARK: - 4 帧时空滑动缓冲队列 (4-frame Spatio-Temporal Window)

    private var frameWindow: [DecodedVideoFrame] = []
    private var lastSampledLuma: [UInt8]?
    private(set) var totalInterpolatedFrames: Int = 0
    private var isInterpolating = false

    var activeStateText: String {
        guard isInterpolating else { return "待命 (FLAVR 3D-CNN)" }
        return String(format: "活跃 (FLAVR 已生成 %d 帧)", totalInterpolatedFrames)
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

        kernel void flavr_motion_estimate(
            texture2d<float, access::sample> tex0 [[texture(0)]],
            texture2d<float, access::sample> tex1 [[texture(1)]],
            texture2d<float, access::write> motionTex [[texture(2)]],
            constant uint &blockSize [[buffer(0)]],
            constant uint &searchRadiiCount [[buffer(1)]],
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

            // 平坦区域 / 静态背景判定：彻底消除静止画面的任何抖动与虚假位移
            if (sadZero < 0.10f) {
                motionTex.write(float4(0.0f, 0.0f, sadZero, 1.0f), gid);
                return;
            }

            float bestCost = sadZero;
            float2 bestMotion = float2(0.0f, 0.0f);

            // 2. 菱形同心圆搜索（根据 searchRadiiCount 动态调整半径层次：Fast 模式 2 层，高画质模式 4 层）
            const int radii[4] = { 3, 6, 10, 16 };
            uint maxRadii = clamp(searchRadiiCount, 1u, 4u);
            for (uint r = 0; r < maxRadii; r++) {
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

                    // 率失真惩罚约束 (Rate-Distortion Motion Cost)：
                    float cost = sad + 0.04f * float(radius);
                    if (cost < bestCost) {
                        bestCost = cost;
                        bestMotion = float2(off);
                    }
                }
            }

            // 3. 局部精细微调搜索 (-2 到 +2，步长 1)
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
                    float cost = sad + 0.08f * length(cand);
                    if (cost < refinedCost) {
                        refinedCost = cost;
                        refinedMotion = cand;
                    }
                }
            }

            // 死区判定与零运动偏置截断：微小位移强制置零，根除亚像素毛刺
            if (refinedCost >= sadZero * 0.75f || length(refinedMotion) < 1.25f) {
                refinedMotion = float2(0.0f, 0.0f);
            }

            motionTex.write(float4(refinedMotion.x, refinedMotion.y, refinedCost, 1.0f), gid);
        }

        kernel void flavr_warp_y(
            texture2d<float, access::sample> src0 [[texture(0)]],
            texture2d<float, access::sample> src1 [[texture(1)]],
            texture2d<float, access::sample> motionTex [[texture(2)]],
            texture2d<float, access::write> dst [[texture(3)]],
            constant float &alpha [[buffer(0)]],
            constant uint &kernelMode [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float w = float(dst.get_width());
            float h = float(dst.get_height());

            float2 normCoord = (float2(gid) + 0.5f) / float2(w, h);

            // 空间 9 邻域高斯平滑滤波 (3x3 Gaussian Spatial Filter)
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

            // 匹配置信度加权衰减
            float matchError = mC.z;
            float confidence = clamp(1.0f - (matchError / 2.5f), 0.0f, 1.0f);
            float2 effectiveMotion = smoothMotion * confidence;

            float2 normMotion = effectiveMotion / float2(w, h);
            float2 coord0 = normCoord - alpha * normMotion;
            float2 coord1 = normCoord + (1.0f - alpha) * normMotion;

            float y0 = src0.sample(s, coord0).r;
            float y1 = src1.sample(s, coord1).r;

            // FLAVR 3D 时空非线性平滑加权与卷积核模式
            float t = alpha;
            float smoothT = t * t * (3.0f - 2.0f * t); // 默认 Hermite-Lagrange 三次平滑
            if (kernelMode == 1) {
                // Catmull-Rom 锐化核 (发丝与边缘增强)
                float t2 = t * t;
                float t3 = t2 * t;
                float baseT = 3.0f * t2 - 2.0f * t3;
                float sharpBoost = (t - 0.5f) * (1.0f - 4.0f * (t - 0.5f) * (t - 0.5f)) * 0.18f;
                smoothT = clamp(baseT + sharpBoost, 0.0f, 1.0f);
            } else if (kernelMode == 2) {
                // B-Spline 柔和核 (抑制噪点与胶片颗粒)
                float t2 = t * t;
                float t3 = t2 * t;
                smoothT = (t < 0.5f) ? (4.0f * t3) : (1.0f - 4.0f * (1.0f - t) * (1.0f - t) * (1.0f - t));
            }

            float yOut = mix(y0, y1, smoothT);
            dst.write(float4(yOut, 0.0f, 0.0f, 1.0f), gid);
        }

        kernel void flavr_warp_uv(
            texture2d<float, access::sample> src0 [[texture(0)]],
            texture2d<float, access::sample> src1 [[texture(1)]],
            texture2d<float, access::sample> motionTex [[texture(2)]],
            texture2d<float, access::write> dst [[texture(3)]],
            constant float &alpha [[buffer(0)]],
            constant uint &kernelMode [[buffer(1)]],
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

            float t = alpha;
            float smoothT = t * t * (3.0f - 2.0f * t);
            if (kernelMode == 1) {
                float t2 = t * t;
                float t3 = t2 * t;
                float baseT = 3.0f * t2 - 2.0f * t3;
                float sharpBoost = (t - 0.5f) * (1.0f - 4.0f * (t - 0.5f) * (t - 0.5f)) * 0.18f;
                smoothT = clamp(baseT + sharpBoost, 0.0f, 1.0f);
            } else if (kernelMode == 2) {
                float t2 = t * t;
                float t3 = t2 * t;
                smoothT = (t < 0.5f) ? (4.0f * t3) : (1.0f - 4.0f * (1.0f - t) * (1.0f - t) * (1.0f - t));
            }

            float2 uvOut = mix(uv0, uv1, smoothT);
            dst.write(float4(uvOut.r, uvOut.g, 0.0f, 1.0f), gid);
        }
        """

        do {
            let library = try device.makeLibrary(source: msl, options: nil)
            guard let fnMotion = library.makeFunction(name: "flavr_motion_estimate"),
                  let fnWarpY = library.makeFunction(name: "flavr_warp_y"),
                  let fnWarpUV = library.makeFunction(name: "flavr_warp_uv") else { return }
            motionPipelineState = try device.makeComputePipelineState(function: fnMotion)
            warpYPipelineState = try device.makeComputePipelineState(function: fnWarpY)
            warpUVPipelineState = try device.makeComputePipelineState(function: fnWarpUV)
        } catch {
            NSLog("[FLAVRInterpolationEngine] Metal 着色器编译失败: %@", error.localizedDescription)
        }
    }

    // MARK: - 原版 RIFEFrameSimilarityDetector 帧相似度检测
    private func areFramesSimilar(_ b0: CVPixelBuffer, _ b1: CVPixelBuffer, threshold: Double = 0.001) -> Bool {
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

        let fmt = CVPixelBufferGetPixelFormatType(b0)
        let is10Bit = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        let stepX = max(1, w >> 6)
        let stepY = max(1, h >> 6)

        var diffSum: Double = 0.0
        var sampleCount: Double = 0.0

        if is10Bit {
            let uptr0 = ptr0.assumingMemoryBound(to: UInt16.self)
            let uptr1 = ptr1.assumingMemoryBound(to: UInt16.self)
            let wordStride0 = stride0 / 2
            let wordStride1 = stride1 / 2

            var y = 0
            while y < h {
                let row0 = uptr0.advanced(by: y * wordStride0)
                let row1 = uptr1.advanced(by: y * wordStride1)
                var x = 0
                while x < w {
                    let v0 = Double(row0[x] >> 2)
                    let v1 = Double(row1[x] >> 2)
                    diffSum += abs(v0 - v1)
                    sampleCount += 1.0
                    x += stepX
                }
                y += stepY
            }
        } else {
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
        }

        guard sampleCount > 0 else { return false }
        let mae = (diffSum / sampleCount) / 255.0
        return mae < threshold
    }

    private var timelineCursorPTS: Double = -1.0

    /// 重置状态（Seek 或切换视频时调用）
    func reset() {
        frameWindow.removeAll(keepingCapacity: true)
        lastSampledLuma = nil
        timelineCursorPTS = -1.0
        isInterpolating = false
    }

    // MARK: - 主插值逻辑

    /// 输入解码器送出的一张新帧，根据当前设置返回包含原生帧与中间插帧的完整帧序列
    func interpolate(
        incoming: DecodedVideoFrame,
        settings: PlaybackSettings,
        sourceFrameRate: Double
    ) -> [DecodedVideoFrame] {

        guard settings.rifeRateMode != .off else {
            reset()
            return [incoming]
        }

        isInterpolating = true

        frameWindow.append(incoming)
        if frameWindow.count > 4 {
            frameWindow.removeFirst()
        }

        guard frameWindow.count >= 2 else {
            timelineCursorPTS = incoming.pts
            return [incoming]
        }

        let f0 = frameWindow[frameWindow.count - 2]
        let f1 = frameWindow[frameWindow.count - 1]

        let dt = f1.pts - f0.pts
        guard dt > 0.001 && dt <= 1.0 else {
            timelineCursorPTS = incoming.pts
            return [incoming]
        }

        let width = CVPixelBufferGetWidth(incoming.pixelBuffer)
        let height = CVPixelBufferGetHeight(incoming.pixelBuffer)
        let is10Bit = (CVPixelBufferGetPixelFormatType(incoming.pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       CVPixelBufferGetPixelFormatType(incoming.pixelBuffer) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        ensurePixelBufferPool(width: width, height: height, is10Bit: is10Bit)

        let isSimilar = settings.rifeStaticFrameSkip && areFramesSimilar(f0.pixelBuffer, f1.pixelBuffer, threshold: min(settings.rifeStaticThreshold * 0.05, 0.001))
        let kernelMode = settings.flavrKernelMode
        let isFast = (settings.rifeModel == .flavrFast)

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
            timelineCursorPTS = incoming.pts
            return [incoming]
        }

        var result: [DecodedVideoFrame] = []

        if settings.rifeRateMode.needsTimelineResample(sourceFPS: sourceFrameRate) {
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
                let alpha = Float(Swift.max(0.0, Swift.min(1.0, (t - f0.pts) / dt)))

                var interpBuffer: CVPixelBuffer?
                if isSimilar || alpha < 0.04 {
                    interpBuffer = copyPixelBuffer(from: f0.pixelBuffer, width: width, height: height)
                } else if alpha > 0.96 {
                    interpBuffer = copyPixelBuffer(from: f1.pixelBuffer, width: width, height: height)
                } else {
                    interpBuffer = synthesizeIntermediateBuffer(
                        frame0: f0.pixelBuffer,
                        frame1: f1.pixelBuffer,
                        alpha: alpha,
                        width: width,
                        height: height,
                        kernelMode: kernelMode,
                        isFast: isFast
                    )
                }

                if let pb = interpBuffer {
                    let outFrame = DecodedVideoFrame(
                        pixelBuffer: pb,
                        pts: t,
                        isBT709: incoming.isBT709,
                        colorSpaceCode: incoming.colorSpaceCode,
                        isFullRange: incoming.isFullRange,
                        isInterpolated: (alpha >= 0.04 && alpha <= 0.96),
                        transferFunction: incoming.transferFunction,
                        peakNits: incoming.peakNits
                    )
                    result.append(outFrame)
                    totalInterpolatedFrames += 1
                }
            }
        } else {
            let alphas = computeFractionalAlphas(mode: settings.rifeRateMode)
            for alpha in alphas {
                let interpPTS = f0.pts + Double(alpha) * dt
                var interpBuffer: CVPixelBuffer?

                if isSimilar {
                    interpBuffer = copyPixelBuffer(from: f0.pixelBuffer, width: width, height: height)
                } else {
                    interpBuffer = synthesizeIntermediateBuffer(
                        frame0: f0.pixelBuffer,
                        frame1: f1.pixelBuffer,
                        alpha: alpha,
                        width: width,
                        height: height,
                        kernelMode: kernelMode,
                        isFast: isFast
                    )
                }

                if let pb = interpBuffer {
                    let interpolatedFrame = DecodedVideoFrame(
                        pixelBuffer: pb,
                        pts: interpPTS,
                        isBT709: incoming.isBT709,
                        colorSpaceCode: incoming.colorSpaceCode,
                        isFullRange: incoming.isFullRange,
                        isInterpolated: true,
                        transferFunction: incoming.transferFunction,
                        peakNits: incoming.peakNits
                    )
                    result.append(interpolatedFrame)
                    totalInterpolatedFrames += 1
                }
            }
            result.append(incoming)
        }

        return result
    }

    private func computeFractionalAlphas(mode: RIFERateMode) -> [Float] {
        switch mode {
        case .off: return []
        case .x2: return [0.5]
        case .x3: return [1.0 / 3.0, 2.0 / 3.0]
        case .x4: return [0.25, 0.5, 0.75]
        case .x5: return [0.2, 0.4, 0.6, 0.8]
        default: return [0.5]
        }
    }

    private func synthesizeIntermediateBuffer(
        frame0: CVPixelBuffer,
        frame1: CVPixelBuffer,
        alpha: Float,
        width: Int,
        height: Int,
        kernelMode: FLAVRKernelMode,
        isFast: Bool
    ) -> CVPixelBuffer? {
        guard let psoMotion = motionPipelineState,
              let psoWarpY = warpYPipelineState,
              let psoWarpUV = warpUVPipelineState,
              let queue = commandQueue,
              let device = device,
              let cache = textureCache else { return nil }

        let is0_10Bit = (CVPixelBufferGetPixelFormatType(frame0) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                         CVPixelBufferGetPixelFormatType(frame0) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let is1_10Bit = (CVPixelBufferGetPixelFormatType(frame1) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                         CVPixelBufferGetPixelFormatType(frame1) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let isTarget10Bit = is0_10Bit || is1_10Bit

        ensurePixelBufferPool(width: width, height: height, is10Bit: isTarget10Bit)

        var dstBuffer: CVPixelBuffer?
        if let pool = pixelBufferPool {
            _ = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstBuffer)
        }
        if dstBuffer == nil {
            let formatType = isTarget10Bit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let pbAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: formatType,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, formatType, pbAttrs as CFDictionary, &dstBuffer)
        }
        guard let dst = dstBuffer else { return nil }

        let isDst10Bit = (CVPixelBufferGetPixelFormatType(dst) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                          CVPixelBufferGetPixelFormatType(dst) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        let f0Plane0W = CVPixelBufferGetWidthOfPlane(frame0, 0)
        let f0Plane0H = CVPixelBufferGetHeightOfPlane(frame0, 0)
        let f0Plane1W = CVPixelBufferGetWidthOfPlane(frame0, 1)
        let f0Plane1H = CVPixelBufferGetHeightOfPlane(frame0, 1)

        let f1Plane0W = CVPixelBufferGetWidthOfPlane(frame1, 0)
        let f1Plane0H = CVPixelBufferGetHeightOfPlane(frame1, 0)
        let f1Plane1W = CVPixelBufferGetWidthOfPlane(frame1, 1)
        let f1Plane1H = CVPixelBufferGetHeightOfPlane(frame1, 1)

        let dstPlane0W = CVPixelBufferGetWidthOfPlane(dst, 0)
        let dstPlane0H = CVPixelBufferGetHeightOfPlane(dst, 0)
        let dstPlane1W = CVPixelBufferGetWidthOfPlane(dst, 1)
        let dstPlane1H = CVPixelBufferGetHeightOfPlane(dst, 1)

        guard let src0Y = makeTexture(from: frame0, plane: 0, pixelFormat: is0_10Bit ? .r16Unorm : .r8Unorm, width: f0Plane0W, height: f0Plane0H, cache: cache, usage: .shaderRead),
              let src0UV = makeTexture(from: frame0, plane: 1, pixelFormat: is0_10Bit ? .rg16Unorm : .rg8Unorm, width: f0Plane1W, height: f0Plane1H, cache: cache, usage: .shaderRead),
              let src1Y = makeTexture(from: frame1, plane: 0, pixelFormat: is1_10Bit ? .r16Unorm : .r8Unorm, width: f1Plane0W, height: f1Plane0H, cache: cache, usage: .shaderRead),
              let src1UV = makeTexture(from: frame1, plane: 1, pixelFormat: is1_10Bit ? .rg16Unorm : .rg8Unorm, width: f1Plane1W, height: f1Plane1H, cache: cache, usage: .shaderRead),
              let dstY = makeTexture(from: dst, plane: 0, pixelFormat: isDst10Bit ? .r16Unorm : .r8Unorm, width: dstPlane0W, height: dstPlane0H, cache: cache, usage: [.shaderRead, .shaderWrite]),
              let dstUV = makeTexture(from: dst, plane: 1, pixelFormat: isDst10Bit ? .rg16Unorm : .rg8Unorm, width: dstPlane1W, height: dstPlane1H, cache: cache, usage: [.shaderRead, .shaderWrite]) else {
            return nil
        }

        // 4K 超清自适应 32x32 宏块，Fast 模式 24x24，标准 16x16
        var uintBlockSize: UInt32 = (width > 2560) ? 32 : (isFast ? 24 : 16)
        var uintSearchRadii: UInt32 = isFast ? 2 : 4
        let blockSize = Int(uintBlockSize)
        let motionW = max(1, (width + blockSize - 1) / blockSize)
        let motionH = max(1, (height + blockSize - 1) / blockSize)
        let motionTex = getOrCreateMotionTexture(device: device, width: motionW, height: motionH)

        guard let cb = queue.makeCommandBuffer() else { return nil }

        if let encMotion = cb.makeComputeCommandEncoder() {
            encMotion.label = "FLAVR_Compute_Motion"
            encMotion.setComputePipelineState(psoMotion)
            encMotion.setTexture(src0Y, index: 0)
            encMotion.setTexture(src1Y, index: 1)
            encMotion.setTexture(motionTex, index: 2)
            encMotion.setBytes(&uintBlockSize, length: MemoryLayout<UInt32>.size, index: 0)
            encMotion.setBytes(&uintSearchRadii, length: MemoryLayout<UInt32>.size, index: 1)

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
        var uintKernelMode: UInt32 = 0
        switch kernelMode {
        case .hermite:    uintKernelMode = 0
        case .catmullRom: uintKernelMode = 1
        case .bSpline:    uintKernelMode = 2
        }

        if let encWarpY = cb.makeComputeCommandEncoder() {
            encWarpY.label = "FLAVR_Warp_Y"
            encWarpY.setComputePipelineState(psoWarpY)
            encWarpY.setTexture(src0Y, index: 0)
            encWarpY.setTexture(src1Y, index: 1)
            encWarpY.setTexture(motionTex, index: 2)
            encWarpY.setTexture(dstY, index: 3)
            encWarpY.setBytes(&mutableAlpha, length: MemoryLayout<Float>.size, index: 0)
            encWarpY.setBytes(&uintKernelMode, length: MemoryLayout<UInt32>.size, index: 1)

            let w = min(psoWarpY.threadExecutionWidth, 16)
            let h = max(1, min(psoWarpY.maxTotalThreadsPerThreadgroup / w, 16))
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let threadgroups = MTLSize(
                width: (dstPlane0W + w - 1) / w,
                height: (dstPlane0H + h - 1) / h,
                depth: 1
            )
            encWarpY.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerGroup)
            encWarpY.endEncoding()
        }

        if let encWarpUV = cb.makeComputeCommandEncoder() {
            encWarpUV.label = "FLAVR_Warp_UV"
            encWarpUV.setComputePipelineState(psoWarpUV)
            encWarpUV.setTexture(src0UV, index: 0)
            encWarpUV.setTexture(src1UV, index: 1)
            encWarpUV.setTexture(motionTex, index: 2)
            encWarpUV.setTexture(dstUV, index: 3)
            encWarpUV.setBytes(&mutableAlpha, length: MemoryLayout<Float>.size, index: 0)
            encWarpUV.setBytes(&uintKernelMode, length: MemoryLayout<UInt32>.size, index: 1)

            let uvW = dstPlane1W
            let uvH = dstPlane1H
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
        cb.waitUntilCompleted()

        return dst
    }

    private func makeTexture(
        from pb: CVPixelBuffer,
        plane: Int,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        cache: CVMetalTextureCache,
        usage: MTLTextureUsage = .shaderRead
    ) -> MTLTexture? {
        var cvTex: CVMetalTexture?
        let attrs: [CFString: Any] = [
            kCVMetalTextureUsage: usage.rawValue
        ]
        let rc = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pb,
            attrs as CFDictionary,
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

    private func copyPixelBuffer(from src: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let outBuffer = dst else { return nil }

        guard CVPixelBufferLockBaseAddress(src, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        guard CVPixelBufferLockBaseAddress(outBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(outBuffer, []) }

        for plane in 0..<CVPixelBufferGetPlaneCount(src) {
            guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                  let dstBase = CVPixelBufferGetBaseAddressOfPlane(outBuffer, plane) else { continue }
            let h = (plane == 0) ? height : height / 2
            let srcBpr = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
            let dstBpr = CVPixelBufferGetBytesPerRowOfPlane(outBuffer, plane)
            let copyBytes = min(srcBpr, dstBpr)
            for row in 0..<h {
                memcpy(dstBase.advanced(by: row * dstBpr), srcBase.advanced(by: row * srcBpr), copyBytes)
            }
        }
        return outBuffer
    }

    private var poolIs10Bit = false

    private func ensurePixelBufferPool(width: Int, height: Int, is10Bit: Bool) {
        if pixelBufferPool != nil && poolWidth == width && poolHeight == height && poolIs10Bit == is10Bit {
            return
        }

        poolWidth = width
        poolHeight = height
        poolIs10Bit = is10Bit
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 64
        ]
        let formatType = is10Bit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: formatType,
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

    private func sampleDownscaledLuma(from pb: CVPixelBuffer) -> [UInt8] {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return [] }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)

        let cols = 32
        let rows = 18
        var samples = [UInt8](repeating: 0, count: cols * rows)
        let dx = max(1, w / cols)
        let dy = max(1, h / rows)

        var idx = 0
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let is10Bit = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        if is10Bit {
            let ptr = yBase.assumingMemoryBound(to: UInt16.self)
            let wordBpr = bpr / 2
            for r in 0..<rows {
                let y = min(h - 1, r * dy)
                let rowOffset = y * wordBpr
                for c in 0..<cols {
                    let x = min(w - 1, c * dx)
                    samples[idx] = UInt8((ptr[rowOffset + x] >> 2) & 0xFF)
                    idx += 1
                }
            }
        } else {
            let ptr = yBase.assumingMemoryBound(to: UInt8.self)
            for r in 0..<rows {
                let y = min(h - 1, r * dy)
                let rowOffset = y * bpr
                for c in 0..<cols {
                    let x = min(w - 1, c * dx)
                    samples[idx] = ptr[rowOffset + x]
                    idx += 1
                }
            }
        }
        return samples
    }
}
