// Anime4KPostProcessor.swift
// Macrife Player · Phase 5 Anime4K 动漫线稿锐化与自适应降噪计算处理器

import Foundation
import Metal
import CoreVideo
import simd

final class Anime4KPostProcessor {

    private let device: MTLDevice
    private(set) var preset: Anime4KPreset
    private var loggedErrors: Set<String> = []

    private var lineRefinePipelineState: MTLComputePipelineState?
    private var bilateralDenoisePipelineState: MTLComputePipelineState?

    private var intermediateTexture: MTLTexture?
    private var outputTexture: MTLTexture?
    private var lastWidth: Int = 0
    private var lastHeight: Int = 0

    // MARK: - 嵌套类型 ProfileStats
    struct ProfileStats {
        var totalFrames: Int = 0
        var totalComputeTimeMs: Double = 0.0

        mutating func reset() {
            totalFrames = 0
            totalComputeTimeMs = 0.0
        }
    }

    private(set) var stats = ProfileStats()

    // MARK: - 初始化

    init(device: MTLDevice, preset: Anime4KPreset = .default) {
        self.device = device
        self.preset = preset
        buildPipelines()
    }

    private func buildPipelines() {
        let mslSource = """
        #include <metal_stdlib>
        using namespace metal;

        // 计算亮度
        inline float get_luminance(float4 c) {
            return dot(c.rgb, float3(0.299f, 0.587f, 0.114f));
        }

        // Pass 1: 线稿检测与法向边缘收敛 (Line Thinning & Refine)
        kernel void anime4k_line_refine(
            texture2d<float, access::read> inTex [[texture(0)]],
            texture2d<float, access::write> outTex [[texture(1)]],
            constant float &sharpness [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
                return;
            }

            int w = inTex.get_width();
            int h = inTex.get_height();
            int x = int(gid.x);
            int y = int(gid.y);

            float4 center = inTex.read(uint2(x, y));

            // 3x3 采样邻域亮度
            float l00 = get_luminance(inTex.read(uint2(max(x - 1, 0), max(y - 1, 0))));
            float l10 = get_luminance(inTex.read(uint2(x, max(y - 1, 0))));
            float l20 = get_luminance(inTex.read(uint2(min(x + 1, w - 1), max(y - 1, 0))));

            float l01 = get_luminance(inTex.read(uint2(max(x - 1, 0), y)));
            float l11 = get_luminance(center);
            float l21 = get_luminance(inTex.read(uint2(min(x + 1, w - 1), y)));

            float l02 = get_luminance(inTex.read(uint2(max(x - 1, 0), min(y + 1, h - 1))));
            float l12 = get_luminance(inTex.read(uint2(x, min(y + 1, h - 1))));
            float l22 = get_luminance(inTex.read(uint2(min(x + 1, w - 1), min(y + 1, h - 1))));

            // Sobel 梯度
            float gx = (l20 + 2.0f * l21 + l22) - (l00 + 2.0f * l01 + l02);
            float gy = (l02 + 2.0f * l12 + l22) - (l00 + 2.0f * l10 + l20);
            float grad = sqrt(gx * gx + gy * gy);

            // 边缘保护与线条加深
            if (grad > 0.05f) {
                float edgeFactor = clamp(grad * sharpness * 1.5f, 0.0f, 1.0f);
                // 模拟暗化收紧轮廓线
                float3 darkened = center.rgb * (1.0f - edgeFactor * 0.35f);
                outTex.write(float4(darkened, center.a), gid);
            } else {
                outTex.write(center, gid);
            }
        }

        // Pass 2: 自适应平坦区双边平滑降噪 (Bilateral Denoise)
        kernel void anime4k_bilateral_denoise(
            texture2d<float, access::read> inTex [[texture(0)]],
            texture2d<float, access::write> outTex [[texture(1)]],
            constant float &denoise [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]])
        {
            if (gid.x >= outTex.get_width() || gid.y >= outTex.get_height()) {
                return;
            }

            int w = inTex.get_width();
            int h = inTex.get_height();
            int x = int(gid.x);
            int y = int(gid.y);

            float4 center = inTex.read(uint2(x, y));
            float centerLum = get_luminance(center);

            float4 sumColor = center;
            float sumWeight = 1.0f;
            float sigmaColor = max(0.01f, (1.0f - denoise) * 0.15f + 0.02f);

            // 邻域 4 连通双边采样
            const int2 offsets[4] = { int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
            for (int i = 0; i < 4; i++) {
                int nx = clamp(x + offsets[i].x, 0, w - 1);
                int ny = clamp(y + offsets[i].y, 0, h - 1);
                float4 neighbor = inTex.read(uint2(nx, ny));
                float neighborLum = get_luminance(neighbor);

                float diff = abs(centerLum - neighborLum);
                float weight = exp(-(diff * diff) / (2.0f * sigmaColor * sigmaColor));
                sumColor += neighbor * weight;
                sumWeight += weight;
            }

            float4 result = sumColor / sumWeight;
            outTex.write(float4(result.rgb, center.a), gid);
        }
        """

        do {
            let library = try device.makeLibrary(source: mslSource, options: nil)
            if let f1 = library.makeFunction(name: "anime4k_line_refine") {
                lineRefinePipelineState = try device.makeComputePipelineState(function: f1)
            }
            if let f2 = library.makeFunction(name: "anime4k_bilateral_denoise") {
                bilateralDenoisePipelineState = try device.makeComputePipelineState(function: f2)
            }
        } catch {
            logErrorOnce("Metal Anime4K 着色器编译失败: \(error.localizedDescription)")
        }
    }

    // MARK: - API 兼容方法

    func logErrorOnce(_ message: String) {
        guard !loggedErrors.contains(message) else { return }
        loggedErrors.insert(message)
        NSLog("[Anime4KPostProcessor] %@", message)
    }

    func invalidateTimeline(reason: String) {
        intermediateTexture = nil
        outputTexture = nil
        lastWidth = 0
        lastHeight = 0
    }

    func setPreset(_ newPreset: Anime4KPreset) {
        self.preset = newPreset
    }

    // MARK: - 实时处理管线

    /// 在给定的 CommandBuffer 中执行 Anime4K 二次元动漫画质增强计算
    func process(commandBuffer: MTLCommandBuffer, inputTexture: MTLTexture) -> MTLTexture {
        guard preset.isEnabled,
              let lineState = lineRefinePipelineState,
              let denoiseState = bilateralDenoisePipelineState else {
            return inputTexture
        }

        let width = inputTexture.width
        let height = inputTexture.height

        ensureTextures(width: width, height: height)

        guard let interTex = intermediateTexture, let outTex = outputTexture else {
            return inputTexture
        }

        // Pass 1: 线稿锐化
        if let encoder1 = commandBuffer.makeComputeCommandEncoder() {
            encoder1.label = "Anime4K_LineRefine"
            encoder1.setComputePipelineState(lineState)
            encoder1.setTexture(inputTexture, index: 0)
            encoder1.setTexture(interTex, index: 1)
            var sharpness = preset.lineSharpness
            encoder1.setBytes(&sharpness, length: MemoryLayout<Float>.size, index: 0)

            let w = lineState.threadExecutionWidth
            let h = max(1, lineState.maxTotalThreadsPerThreadgroup / w)
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let groups = MTLSize(
                width: (width + w - 1) / w,
                height: (height + h - 1) / h,
                depth: 1
            )
            encoder1.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            encoder1.endEncoding()
        }

        // Pass 2: 自适应平滑降噪
        if let encoder2 = commandBuffer.makeComputeCommandEncoder() {
            encoder2.label = "Anime4K_BilateralDenoise"
            encoder2.setComputePipelineState(denoiseState)
            encoder2.setTexture(interTex, index: 0)
            encoder2.setTexture(outTex, index: 1)
            var denoise = preset.denoiseStrength
            encoder2.setBytes(&denoise, length: MemoryLayout<Float>.size, index: 0)

            let w = denoiseState.threadExecutionWidth
            let h = max(1, denoiseState.maxTotalThreadsPerThreadgroup / w)
            let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
            let groups = MTLSize(
                width: (width + w - 1) / w,
                height: (height + h - 1) / h,
                depth: 1
            )
            encoder2.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            encoder2.endEncoding()
        }

        stats.totalFrames += 1
        return outTex
    }

    private func ensureTextures(width: Int, height: Int) {
        if intermediateTexture != nil, lastWidth == width, lastHeight == height {
            return
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private

        intermediateTexture = device.makeTexture(descriptor: desc)
        outputTexture = device.makeTexture(descriptor: desc)
        lastWidth = width
        lastHeight = height
    }
}
