import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import QuartzCore
import Metal

/// 单一视频处理线程拥有会话；只把计数与状态以快照形式交给 UI。
/// 原帧不经过缩放；中间帧推理分辨率独立可选，放大时保留HUD原始像素。
final class AppleLowLatencyInterpolator {
    private let processingLock = NSLock()
    private var storage: AnyObject?
    private var configurationKey = ""
    private var failedKeys = Set<String>()
    private let statsLock = NSLock()
    private var generated = 0
    private var processingMS = 0.0
    private var status = "Apple 低延迟待命"
    private var active = false

    static func supports(sourceFPS: Double, targetFPS: Double) -> Bool {
        sourceFPS > 0 && abs(targetFPS / sourceFPS - 2) < 0.05
    }

    var snapshot: (frames: Int, status: String, processingSeconds: Double, active: Bool) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (generated, status, generated > 0 ? processingMS / Double(generated) / 1000 : 0, active)
    }

    func reset() {
        processingLock.lock(); defer { processingLock.unlock() }
        storage = nil
        configurationKey = ""
        failedKeys.removeAll()
        statsLock.lock()
        generated = 0
        processingMS = 0
        status = "Apple 低延迟待命"
        active = false
        statsLock.unlock()
    }

    /// A cadence/phase change invalidates the frame pair, not the warmed model.
    func discardPreviousFrame() {
        processingLock.lock(); defer { processingLock.unlock() }
        if #available(macOS 26.0, *) {
            (storage as? AppleInterpolationSession)?.discardPreviousFrame()
        }
    }

    /// nil 表示当前格式/帧率/系统不支持，由播放引擎继续走 RIFE。
    func interpolate(_ frame: DecodedVideoFrame, sourceFPS: Double,
                     targetFPS: Double, maxInferenceHeight: Int = 720) -> [DecodedVideoFrame]? {
        processingLock.lock(); defer { processingLock.unlock() }
        guard Self.supports(sourceFPS: sourceFPS, targetFPS: targetFPS), !frame.isHDR else {
            setStatus("当前帧率或 HDR 使用 RIFE 回退")
            return nil
        }
        guard #available(macOS 26.0, *) else {
            setStatus("Apple 低延迟需要 macOS 26，使用 RIFE 回退")
            return nil
        }
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let inferenceHeight = max(2, maxInferenceHeight)
        let key = "\(width)x\(height)|\(inferenceHeight)|\(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))|\(frame.colorSpaceCode)|\(frame.isFullRange)"
        guard !failedKeys.contains(key) else { return nil }
        do {
            if configurationKey != key {
                storage = nil
                storage = try AppleInterpolationSession(width: width, height: height,
                                                         colorSpaceCode: frame.colorSpaceCode,
                                                         maxInferenceHeight: inferenceHeight)
                configurationKey = key
            }
            guard let session = storage as? AppleInterpolationSession else { return nil }
            let start = CACurrentMediaTime()
            let frames = try session.interpolate(frame)
            let count = frames.filter(\.isInterpolated).count
            statsLock.lock()
            generated += count
            active = true
            if count > 0 { processingMS += (CACurrentMediaTime() - start) * 1000 }
            status = generated > 0
                ? String(format: "Apple %dx%d 补帧 → %dx%d · 处理均耗 %.1f ms", session.width, session.height,
                         width, height, processingMS / Double(generated))
                    + (session.hudProtectionActive ? " · HUD文字保护" : "")
                : "Apple 低延迟预热完成"
            statsLock.unlock()
            return frames
        } catch {
            storage = nil
            configurationKey = ""
            failedKeys.insert(key)
            setStatus("Apple 不可用，使用 RIFE 回退：\(error.localizedDescription)")
            NSLog("[AppleInterpolation] %@", error.localizedDescription)
            return nil
        }
    }

    private func setStatus(_ text: String) {
        statsLock.lock(); status = text; active = false; statsLock.unlock()
    }
}

@available(macOS 26.0, *)
private final class AppleInterpolationSession {
    let width: Int
    let height: Int
    private let processor = VTFrameProcessor()
    private let transfer: VTPixelTransferSession
    private let sourcePool: CVPixelBufferPool
    private let intermediatePool: CVPixelBufferPool
    private let outputPool: CVPixelBufferPool
    private let resizer: NV12GPUResizer?
    private var previous: (frame: DecodedVideoFrame, small: CVPixelBuffer)?
    private(set) var hudProtectionActive = false

    init(width sourceWidth: Int, height sourceHeight: Int, colorSpaceCode: Int32, maxInferenceHeight: Int) throws {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else { throw Failure.unsupported }
        let dimensions = InferenceGeometry.fit(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                                               maxHeight: maxInferenceHeight)
        width = dimensions.width
        height = dimensions.height
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) else {
            throw Failure.unsupported
        }
        sourcePool = try Self.makePool(configuration.sourcePixelBufferAttributes)
        intermediatePool = try Self.makePool(configuration.destinationPixelBufferAttributes)
        outputPool = try Self.makePool([
            kCVPixelBufferWidthKey as String: sourceWidth,
            kCVPixelBufferHeightKey as String: sourceHeight,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        resizer = try? NV12GPUResizer()
        var session: VTPixelTransferSession?
        try Self.check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &session))
        guard let session else { throw Failure.unsupported }
        transfer = session
        try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue))
        try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal))
        let matrix = colorSpaceCode == 0 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
            : (colorSpaceCode == 2 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: matrix))
        try processor.startSession(configuration: configuration)
        NSLog("[AppleInterpolation] 会话就绪: %dx%d → %dx%d（原帧保留）", width, height, sourceWidth, sourceHeight)
    }

    deinit {
        processor.endSession()
        VTPixelTransferSessionInvalidate(transfer)
    }

    func discardPreviousFrame() {
        previous = nil
        resizer?.resetDetailHistory()
    }

    func interpolate(_ frame: DecodedVideoFrame) throws -> [DecodedVideoFrame] {
        let small = try Self.buffer(from: sourcePool)
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let command: MTLCommandBuffer?
        if let resizer, format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            command = try resizer.makeCommandBuffer()
        } else { command = nil }
        var textureReferences: [CVMetalTexture] = []
        if let command, let resizer {
            textureReferences += try resizer.encodeResize(frame.pixelBuffer, to: small,
                fullRange: frame.isFullRange, command: command)
        } else {
            try resize(frame.pixelBuffer, to: small, fullRange: frame.isFullRange)
        }
        let prior = previous
        previous = (frame, small)
        guard let prior, frame.pts - prior.frame.pts > 0.001,
              frame.pts - prior.frame.pts < 0.15 else {
            hudProtectionActive = false
            resizer?.resetDetailHistory()
            if let command, let resizer { try resizer.finish(command, retaining: textureReferences) }
            return [frame]
        }
        let dt = frame.pts - prior.frame.pts

        let middlePTS = prior.frame.pts + dt * 0.5
        let intermediate = try Self.buffer(from: intermediatePool)
        guard let source = VTFrameProcessorFrame(buffer: small, presentationTimeStamp: Self.time(frame.pts)),
              let reference = VTFrameProcessorFrame(buffer: prior.small, presentationTimeStamp: Self.time(prior.frame.pts)),
              let destination = VTFrameProcessorFrame(buffer: intermediate, presentationTimeStamp: Self.time(middlePTS)),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: source, previousFrame: reference, interpolationPhase: [0.5], destinationFrames: [destination]) else {
            throw Failure.unsupported
        }
        let output = try Self.buffer(from: outputPool)
        if let command, let resizer {
            // 缩小、ML 补帧、放大进入同一个 GPU 批次，只同步等待一次。
            processor.process(with: command, parameters: parameters)
            textureReferences += try resizer.encodeResize(intermediate, to: output,
                fullRange: false, command: command,
                preserving: (prior.frame.pixelBuffer, frame.pixelBuffer, frame.isFullRange))
            try withExtendedLifetime((parameters, frame, prior, small, intermediate, output)) {
                try resizer.finish(command, retaining: textureReferences)
            }
            hudProtectionActive = true
        } else {
            hudProtectionActive = false
            let done = DispatchSemaphore(value: 0)
            var failure: Error?
            processor.process(parameters: parameters) { _, error in
                failure = error
                done.signal()
            }
            done.wait()
            if let failure { throw failure }
            try resize(intermediate, to: output, fullRange: false)
        }
        let middle = DecodedVideoFrame(pixelBuffer: output, pts: middlePTS,
                                      isBT709: frame.isBT709, colorSpaceCode: frame.colorSpaceCode,
                                      isFullRange: false, isInterpolated: true)
        return [middle, frame]
    }

    private func resize(_ source: CVPixelBuffer, to destination: CVPixelBuffer, fullRange: Bool) throws {
        let format = CVPixelBufferGetPixelFormatType(source)
        if let resizer, format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            try resizer.resize(source, to: destination, fullRange: fullRange)
        } else {
            try Self.check(VTPixelTransferSessionTransferImage(transfer, from: source, to: destination))
        }
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 1_000_000)
    }

    private static func makePool(_ attributes: [String: Any]) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        var attributes = attributes
        attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw Failure.status(status) }
        return pool
    }

    private static func buffer(from pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw Failure.status(status) }
        return buffer
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw Failure.status(status) }
    }

    private enum Failure: LocalizedError {
        case unsupported
        case status(Int32)
        var errorDescription: String? {
            switch self {
            case .unsupported: return "系统或像素格式不支持低延迟补帧"
            case .status(let code): return "VideoToolbox 错误 \(code)"
            }
        }
    }
}

/// NV12 两平面直接采样与写出，不经 CPU/RGB 往返；每次缩放只提交一个 command buffer。
final class NV12GPUResizer {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let staticDetailPipeline: MTLComputePipelineState
    private let detailMaskPipeline: MTLComputePipelineState
    private let dilateMaskPipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private var operations = 0
    private var detailHistory: [MTLTexture] = []
    private var horizontalDetailMask: MTLTexture?
    private var detailHistoryIndex = 0
    private var hasDetailHistory = false

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw ResizeError.unavailable
        }
        self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "resize_nv12"),
              let staticFunction = library.makeFunction(name: "resize_nv12_preserving_static"),
              let maskFunction = library.makeFunction(name: "stationary_hud_mask"),
              let dilateFunction = library.makeFunction(name: "dilate_hud_horizontal") else { throw ResizeError.unavailable }
        pipeline = try device.makeComputePipelineState(function: function)
        staticDetailPipeline = try device.makeComputePipelineState(function: staticFunction)
        detailMaskPipeline = try device.makeComputePipelineState(function: maskFunction)
        dilateMaskPipeline = try device.makeComputePipelineState(function: dilateFunction)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw ResizeError.unavailable }
        self.cache = cache
    }

    func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else { throw ResizeError.unavailable }
        return command
    }

    func resetDetailHistory() { hasDetailHistory = false }

    /// Detect stationary foreground strokes instead of requiring the entire
    /// background neighbourhood to be unchanged. Expand over antialiasing,
    /// outlines and displaced AI ghosts; keep a short, fading mask history.
    private func encodeHUDMask(previous: MTLTexture, current: MTLTexture,
                               command: MTLCommandBuffer) throws -> MTLTexture {
        let width = (current.width + 1) / 2, height = (current.height + 1) / 2
        if detailHistory.first?.width != width || detailHistory.first?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            guard let a = queue.device.makeTexture(descriptor: descriptor),
                  let b = queue.device.makeTexture(descriptor: descriptor),
                  let horizontal = queue.device.makeTexture(descriptor: descriptor) else { throw ResizeError.unavailable }
            detailHistory = [a, b]
            horizontalDetailMask = horizontal
            detailHistoryIndex = 0
            hasDetailHistory = false
        }
        let next = 1 - detailHistoryIndex
        guard let horizontalDetailMask, let encoder = command.makeComputeCommandEncoder() else { throw ResizeError.unavailable }
        encoder.setComputePipelineState(detailMaskPipeline)
        encoder.setTexture(previous, index: 0)
        encoder.setTexture(current, index: 1)
        encoder.setTexture(detailHistory[detailHistoryIndex], index: 2)
        encoder.setTexture(detailHistory[next], index: 3)
        var hasHistory: UInt32 = hasDetailHistory ? 1 : 0
        encoder.setBytes(&hasHistory, length: MemoryLayout<UInt32>.size, index: 0)
        let grid = MTLSize(width: width, height: height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
        encoder.endEncoding()
        guard let dilate = command.makeComputeCommandEncoder() else { throw ResizeError.unavailable }
        dilate.setComputePipelineState(dilateMaskPipeline)
        dilate.setTexture(detailHistory[next], index: 0)
        dilate.setTexture(horizontalDetailMask, index: 1)
        dilate.dispatchThreads(grid, threadsPerThreadgroup: group)
        dilate.endEncoding()
        detailHistoryIndex = next
        hasDetailHistory = true
        return horizontalDetailMask
    }

    func resize(_ source: CVPixelBuffer, to destination: CVPixelBuffer, fullRange: Bool) throws {
        let command = try makeCommandBuffer()
        let references = try encodeResize(source, to: destination, fullRange: fullRange, command: command)
        try finish(command, retaining: references)
    }

    func encodeResize(_ source: CVPixelBuffer, to destination: CVPixelBuffer,
                      fullRange: Bool, command: MTLCommandBuffer,
                      preserving originals: (previous: CVPixelBuffer, current: CVPixelBuffer, fullRange: Bool)? = nil) throws -> [CVMetalTexture] {
        var references: [CVMetalTexture] = []
        func texture(_ buffer: CVPixelBuffer, plane: Int) throws -> MTLTexture {
            var reference: CVMetalTexture?
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil,
                plane == 0 ? .r8Unorm : .rg8Unorm, width, height, plane, &reference) == kCVReturnSuccess,
                  let reference, let texture = CVMetalTextureGetTexture(reference) else { throw ResizeError.unavailable }
            references.append(reference)
            return texture
        }
        let inputY = try texture(source, plane: 0), inputUV = try texture(source, plane: 1)
        let outputY = try texture(destination, plane: 0), outputUV = try texture(destination, plane: 1)
        let detailTextures: [MTLTexture]
        // The packed-422 fallback still uses the ordinary scaler. NV12 capture
        // keeps original full-resolution detail without another GPU pass or wait.
        if let originals, [originals.previous, originals.current].allSatisfy({
            let format = CVPixelBufferGetPixelFormatType($0)
            return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }) {
            detailTextures = try [texture(originals.previous, plane: 0), texture(originals.previous, plane: 1),
                                  texture(originals.current, plane: 0), texture(originals.current, plane: 1)]
        } else { detailTextures = [] }
        let hudMask = detailTextures.isEmpty ? nil
            : try encodeHUDMask(previous: detailTextures[0], current: detailTextures[2], command: command)
        guard let encoder = command.makeComputeCommandEncoder() else {
            throw ResizeError.unavailable
        }
        encoder.setComputePipelineState(detailTextures.isEmpty ? pipeline : staticDetailPipeline)
        encoder.setTexture(inputY, index: 0)
        encoder.setTexture(inputUV, index: 1)
        encoder.setTexture(outputY, index: 2)
        encoder.setTexture(outputUV, index: 3)
        var range: UInt32 = fullRange ? 1 : 0
        encoder.setBytes(&range, length: MemoryLayout<UInt32>.size, index: 0)
        if !detailTextures.isEmpty {
            for (index, texture) in detailTextures.enumerated() { encoder.setTexture(texture, index: index + 4) }
            var originalRange: UInt32 = originals!.fullRange ? 1 : 0
            encoder.setBytes(&originalRange, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.setTexture(hudMask, index: 8)
        }
        encoder.dispatchThreads(MTLSize(width: outputY.width, height: outputY.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        // 只传播色彩元数据；源 clean aperture 的像素尺寸不适用于缩放后的缓冲。
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(destination, key, value, .shouldPropagate)
            }
        }
        operations += 1
        if operations % 120 == 0 { CVMetalTextureCacheFlush(cache, 0) }
        return references
    }

    func finish(_ command: MTLCommandBuffer, retaining references: [CVMetalTexture]) throws {
        command.commit()
        command.waitUntilCompleted()
        withExtendedLifetime(references) {}
        if let error = command.error { throw error }
    }

    private enum ResizeError: Error { case unavailable }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    float4 stroke_contrast(texture2d<float, access::sample> image, uint2 p) {
        int2 limit = int2(image.get_width(), image.get_height()) - 1;
        float v = image.read(p).r;
        float l = image.read(uint2(clamp(int2(p) + int2(-2, 0), int2(0), limit))).r;
        float r = image.read(uint2(clamp(int2(p) + int2(2, 0), int2(0), limit))).r;
        float t = image.read(uint2(clamp(int2(p) + int2(0, -2), int2(0), limit))).r;
        float b = image.read(uint2(clamp(int2(p) + int2(0, 2), int2(0), limit))).r;
        return float4(min(v-l, v-r), min(v-t, v-b), min(l-v, r-v), min(t-v, b-v));
    }

    kernel void stationary_hud_mask(texture2d<float, access::sample> previous [[texture(0)]],
                                    texture2d<float, access::sample> current [[texture(1)]],
                                    texture2d<float, access::read> history [[texture(2)]],
                                    texture2d<float, access::write> result [[texture(3)]],
                                    constant uint &hasHistory [[buffer(0)]],
                                    uint2 p [[thread_position_in_grid]]) {
        if (p.x >= result.get_width() || p.y >= result.get_height()) return;
        float weight = 0;
        for (uint dy = 0; dy < 2; ++dy) {
            for (uint dx = 0; dx < 2; ++dx) {
                uint2 q = min(p * 2 + uint2(dx, dy), uint2(current.get_width()-1, current.get_height()-1));
                float2 uv = float2(q) / float2(current.get_width(), current.get_height());
                // HUDs occupy screen margins. Keep central gameplay on the AI
                // path; broad terrain texture must not become a held overlay.
                if (uv.x >= 0.25f && uv.x <= 0.75f && uv.y >= 0.20f && uv.y <= 0.75f) continue;
                float4 matched = min(stroke_contrast(previous, q), stroke_contrast(current, q));
                float contrast = max(max(matched.x, matched.y), max(matched.z, matched.w));
                float delta = abs(previous.read(q).r - current.read(q).r);
                if (contrast >= 12.0f / 255.0f && delta <= 4.0f / 255.0f + contrast * 0.25f) weight = 1;
            }
        }
        if (hasHistory) weight = max(weight, history.read(p).r * 0.75f);
        result.write(float4(weight, 0, 0, 1), p);
    }

    kernel void dilate_hud_horizontal(texture2d<float, access::read> input [[texture(0)]],
                                      texture2d<float, access::write> output [[texture(1)]],
                                      uint2 p [[thread_position_in_grid]]) {
        if (p.x >= output.get_width() || p.y >= output.get_height()) return;
        float weight = 0;
        for (int dx = -3; dx <= 3; ++dx) {
            uint x = uint(clamp(int(p.x) + dx, 0, int(input.get_width()) - 1));
            weight = max(weight, input.read(uint2(x, p.y)).r);
        }
        output.write(float4(weight, 0, 0, 1), p);
    }

    float hud_weight(uint2 p, uint2 size, texture2d<float, access::sample> horizontalMask) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(p) + 0.5f) / float2(size);
        float weight = 0;
        for (int dy = -3; dy <= 3; ++dy) {
            weight = max(weight, horizontalMask.sample(s, uv + float2(0, float(dy) / horizontalMask.get_height())).r);
        }
        return weight;
    }

    // A local change mask keeps moving edges on the AI path. Reuse full-size
    // source detail only where both source frames agree, including chroma.
    float static_weight(uint2 p,
                        texture2d<float, access::sample> previousY,
                        texture2d<float, access::sample> previousUV,
                        texture2d<float, access::sample> currentY,
                        texture2d<float, access::sample> currentUV) {
        float difference = 0;
        int2 limit = int2(currentY.get_width(), currentY.get_height()) - 1;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                uint2 q = uint2(clamp(int2(p) + int2(dx, dy), int2(0), limit));
                difference = max(difference, abs(currentY.read(q).r - previousY.read(q).r));
            }
        }
        float2 chroma = abs(currentUV.read(p / 2).rg - previousUV.read(p / 2).rg);
        difference = max(difference, max(chroma.x, chroma.y));
        return 1.0f - smoothstep(1.0f / 255.0f, 4.0f / 255.0f, difference);
    }

    kernel void resize_nv12_preserving_static(
                            texture2d<float, access::sample> yIn [[texture(0)]],
                            texture2d<float, access::sample> uvIn [[texture(1)]],
                            texture2d<float, access::write> yOut [[texture(2)]],
                            texture2d<float, access::write> uvOut [[texture(3)]],
                            texture2d<float, access::sample> previousY [[texture(4)]],
                            texture2d<float, access::sample> previousUV [[texture(5)]],
                            texture2d<float, access::sample> currentY [[texture(6)]],
                            texture2d<float, access::sample> currentUV [[texture(7)]],
                            texture2d<float, access::sample> hudMask [[texture(8)]],
                            constant uint &fullRange [[buffer(0)]],
                            constant uint &originalFullRange [[buffer(1)]],
                            uint2 p [[thread_position_in_grid]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        if (p.x < yOut.get_width() && p.y < yOut.get_height()) {
            float2 uv = (float2(p) + 0.5f) / float2(yOut.get_width(), yOut.get_height());
            float ai = yIn.sample(s, uv).r;
            float original = currentY.read(p).r;
            if (fullRange) ai = (16.0f + 219.0f * ai) / 255.0f;
            if (originalFullRange) original = (16.0f + 219.0f * original) / 255.0f;
            float weight = max(static_weight(p, previousY, previousUV, currentY, currentUV),
                               hud_weight(p, uint2(yOut.get_width(), yOut.get_height()), hudMask));
            yOut.write(float4(mix(ai, original, weight), 0, 0, 1), p);
        }
        if (p.x < uvOut.get_width() && p.y < uvOut.get_height()) {
            float2 uv = (float2(p) + 0.5f) / float2(uvOut.get_width(), uvOut.get_height());
            float2 ai = uvIn.sample(s, uv).rg;
            float2 original = currentUV.read(p).rg;
            if (fullRange) ai = (ai - 128.0f / 255.0f) * (224.0f / 255.0f) + 128.0f / 255.0f;
            if (originalFullRange) original = (original - 128.0f / 255.0f) * (224.0f / 255.0f) + 128.0f / 255.0f;
            float weight = max(static_weight(p * 2 + 1, previousY, previousUV, currentY, currentUV),
                               hud_weight(p * 2 + 1, uint2(yOut.get_width(), yOut.get_height()), hudMask));
            uvOut.write(float4(mix(ai, original, weight), 0, 1), p);
        }
    }

    kernel void resize_nv12(texture2d<float, access::sample> yIn [[texture(0)]],
                            texture2d<float, access::sample> uvIn [[texture(1)]],
                            texture2d<float, access::write> yOut [[texture(2)]],
                            texture2d<float, access::write> uvOut [[texture(3)]],
                            constant uint &fullRange [[buffer(0)]],
                            uint2 p [[thread_position_in_grid]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        if (p.x < yOut.get_width() && p.y < yOut.get_height()) {
            float2 uv = (float2(p) + 0.5f) / float2(yOut.get_width(), yOut.get_height());
            float y = yIn.sample(linearSampler, uv).r;
            if (fullRange) y = (16.0f + 219.0f * y) / 255.0f;
            yOut.write(float4(y, 0, 0, 1), p);
        }
        if (p.x < uvOut.get_width() && p.y < uvOut.get_height()) {
            float2 uv = (float2(p) + 0.5f) / float2(uvOut.get_width(), uvOut.get_height());
            float2 color = uvIn.sample(linearSampler, uv).rg;
            if (fullRange) color = (color - 128.0f / 255.0f) * (224.0f / 255.0f) + 128.0f / 255.0f;
            uvOut.write(float4(color, 0, 1), p);
        }
    }
    """
}
