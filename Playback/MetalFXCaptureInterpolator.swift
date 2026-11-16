import Foundation
import CoreVideo
import VideoToolbox
import Metal
import MetalFX
import Vision
import QuartzCore

/// Experimental image-only bridge. Capture has neither engine motion nor depth:
/// Vision estimates backward image flow; a constant depth plane is an explicit
/// approximation, not reconstructed scene geometry. Only SDR 2X is supported.
final class MetalFXCaptureInterpolator {
    private let processingLock = NSLock()
    private let statsLock = NSLock()
    private var storage: AnyObject?
    private var configurationKey = ""
    private var failures: [String: String] = [:]
    private var generated = 0
    private var processingSeconds = 0.0
    private var status = "MetalFX 实验性补帧待命"
    private var active = false

    var snapshot: (frames: Int, status: String, processingSeconds: Double, active: Bool) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (generated, status, generated > 0 ? processingSeconds / Double(generated) : 0, active)
    }

    func reset() {
        processingLock.lock(); defer { processingLock.unlock() }
        storage = nil
        configurationKey = ""
        failures.removeAll()
        statsLock.lock()
        generated = 0; processingSeconds = 0
        status = "MetalFX 实验性补帧待命"; active = false
        statsLock.unlock()
    }

    func discardPreviousFrame() {
        processingLock.lock(); defer { processingLock.unlock() }
        if #available(macOS 26.0, *) { (storage as? MetalFXCaptureSession)?.discardPreviousFrame() }
    }

    func interpolate(_ frame: DecodedVideoFrame, sourceFPS: Double, targetFPS: Double,
                     maxInferenceHeight: Int) -> [DecodedVideoFrame]? {
        processingLock.lock(); defer { processingLock.unlock() }
        guard AppleLowLatencyInterpolator.supports(sourceFPS: sourceFPS, targetFPS: targetFPS), !frame.isHDR else {
            discardSessionHistory()
            setStatus("MetalFX 仅支持 SDR 2X，使用 RIFE 回退")
            return nil
        }
        guard #available(macOS 26.0, *) else {
            setStatus("MetalFX 补帧需要 macOS 26，使用 RIFE 回退")
            return nil
        }
        let sourceWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
        let key = "\(sourceWidth)x\(sourceHeight)|\(maxInferenceHeight)|\(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))|\(frame.colorSpaceCode)|\(frame.isFullRange)"
        if let failure = failures[key] { setStatus(failure); return nil }
        do {
            if configurationKey != key {
                storage = nil
                storage = try MetalFXCaptureSession(sourceWidth: sourceWidth, sourceHeight: sourceHeight,
                    maxInferenceHeight: maxInferenceHeight, colorSpaceCode: frame.colorSpaceCode)
                configurationKey = key
            }
            guard let session = storage as? MetalFXCaptureSession else { return nil }
            let start = CACurrentMediaTime()
            let frames = try session.interpolate(frame)
            let count = frames.filter(\.isInterpolated).count
            statsLock.lock()
            generated += count
            if count > 0 { processingSeconds += CACurrentMediaTime() - start }
            active = true
            status = String(format: "MetalFX 实验性 %dx%d · 估算光流 / 平面深度", session.width, session.height)
            if generated > 0 { status += String(format: " · 处理均耗 %.1f ms", processingSeconds * 1000 / Double(generated)) }
            if session.hudProtectionActive { status += " · HUD文字保护" }
            statsLock.unlock()
            return frames
        } catch {
            storage = nil; configurationKey = ""
            let failure = "MetalFX 不可用，使用 RIFE 回退：\(error.localizedDescription)"
            failures[key] = failure
            setStatus(failure)
            NSLog("[MetalFXCapture] %@", error.localizedDescription)
            return nil
        }
    }

    private func discardSessionHistory() {
        if #available(macOS 26.0, *) { (storage as? MetalFXCaptureSession)?.discardPreviousFrame() }
    }

    private func setStatus(_ text: String) {
        statsLock.lock(); status = text; active = false; statsLock.unlock()
    }
}

@available(macOS 26.0, *)
private final class MetalFXCaptureSession {
    let width: Int
    let height: Int
    private let device: MTLDevice
    private let effect: MTLFXFrameInterpolator
    private let resizer: NV12GPUResizer
    private let cache: CVMetalTextureCache
    private let toRGB: MTLComputePipelineState
    private let fromRGB: MTLComputePipelineState
    private let depth: MTLTexture
    private let result: MTLTexture
    private let sourcePool: CVPixelBufferPool
    private let outputPool: CVPixelBufferPool
    private let transfer: VTPixelTransferSession
    private let colorSpaceCode: Int32
    private var previous: (frame: DecodedVideoFrame, small: CVPixelBuffer, color: MTLTexture)?
    private var resetHistory = true
    private(set) var hudProtectionActive = false

    init(sourceWidth: Int, sourceHeight: Int, maxInferenceHeight: Int, colorSpaceCode: Int32) throws {
        guard let device = MTLCreateSystemDefaultDevice(), MTLFXFrameInterpolatorDescriptor.supportsDevice(device) else {
            throw Failure.unavailable("当前 GPU 不支持 MetalFX 补帧")
        }
        self.device = device
        self.colorSpaceCode = colorSpaceCode
        let size = InferenceGeometry.fit(sourceWidth: sourceWidth, sourceHeight: sourceHeight, maxHeight: maxInferenceHeight)
        width = size.width; height = size.height
        let descriptor = MTLFXFrameInterpolatorDescriptor()
        descriptor.inputWidth = size.width; descriptor.inputHeight = size.height
        descriptor.outputWidth = size.width; descriptor.outputHeight = size.height
        descriptor.colorTextureFormat = .rgba16Float
        descriptor.outputTextureFormat = .rgba16Float
        descriptor.motionTextureFormat = .rg32Float
        descriptor.depthTextureFormat = .r32Float
        descriptor.uiTextureFormat = .rgba16Float
        guard let effect = descriptor.makeFrameInterpolator(device: device) else {
            throw Failure.unavailable("MetalFX 补帧器创建失败")
        }
        self.effect = effect
        effect.motionVectorScaleX = 1; effect.motionVectorScaleY = 1
        effect.isDepthReversed = false
        effect.nearPlane = 0.1; effect.farPlane = 100
        effect.fieldOfView = 60; effect.aspectRatio = Float(size.width) / Float(size.height)
        effect.jitterOffsetX = 0; effect.jitterOffsetY = 0
        effect.isUITextureComposited = false
        resizer = try NV12GPUResizer()
        var cache: CVMetalTextureCache?
        try Self.check(CVMetalTextureCacheCreate(nil, nil, device, nil, &cache))
        guard let cache else { throw Failure.unavailable("Metal 纹理缓存创建失败") }
        self.cache = cache
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let inputFunction = library.makeFunction(name: "metalfx_nv12_to_rgb"),
              let outputFunction = library.makeFunction(name: "metalfx_rgb_to_nv12") else {
            throw Failure.unavailable("色彩转换内核创建失败")
        }
        toRGB = try device.makeComputePipelineState(function: inputFunction)
        fromRGB = try device.makeComputePipelineState(function: outputFunction)
        depth = try Self.texture(device, format: .r32Float, width: size.width, height: size.height,
                                 usage: effect.depthTextureUsage.union(.shaderWrite))
        result = try Self.texture(device, format: .rgba16Float, width: size.width, height: size.height,
                                  usage: effect.outputTextureUsage.union(.shaderRead))
        sourcePool = try Self.pool(width: size.width, height: size.height)
        outputPool = try Self.pool(width: sourceWidth, height: sourceHeight)
        var transfer: VTPixelTransferSession?
        try Self.check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer))
        guard let transfer else { throw Failure.unavailable("像素转换会话创建失败") }
        self.transfer = transfer
        try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue))
        let matrix = colorSpaceCode == 0 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
            : (colorSpaceCode == 2 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        try Self.check(VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix, value: matrix))
    }

    deinit { VTPixelTransferSessionInvalidate(transfer) }

    func discardPreviousFrame() {
        previous = nil; resetHistory = true; hudProtectionActive = false
        resizer.resetDetailHistory()
    }

    func interpolate(_ frame: DecodedVideoFrame) throws -> [DecodedVideoFrame] {
        let small = try Self.buffer(sourcePool)
        let color = try Self.texture(device, format: .rgba16Float, width: width, height: height,
                                     usage: effect.colorTextureUsage.union([.shaderRead, .shaderWrite]))
        let format = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
        let nv12 = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let prepare = try resizer.makeCommandBuffer()
        var references: [CVMetalTexture] = []
        if nv12 {
            references += try resizer.encodeResize(frame.pixelBuffer, to: small,
                fullRange: frame.isFullRange, command: prepare)
        } else {
            try Self.check(VTPixelTransferSessionTransferImage(transfer, from: frame.pixelBuffer, to: small))
        }
        let y = try texture(small, format: .r8Unorm, plane: 0, references: &references)
        let uv = try texture(small, format: .rg8Unorm, plane: 1, references: &references)
        guard let convert = prepare.makeComputeCommandEncoder() else { throw Failure.encoding }
        convert.setComputePipelineState(toRGB)
        convert.setTexture(y, index: 0); convert.setTexture(uv, index: 1)
        convert.setTexture(color, index: 2); convert.setTexture(depth, index: 3)
        var matrix = colorSpaceCode
        convert.setBytes(&matrix, length: MemoryLayout<Int32>.size, index: 0)
        dispatch(convert, width: width, height: height)
        convert.endEncoding()
        try resizer.finish(prepare, retaining: references)

        guard let prior = previous, frame.pts - prior.frame.pts > 0.001, frame.pts - prior.frame.pts < 0.15 else {
            discardPreviousFrame()
            previous = (frame, small, color)
            return [frame]
        }

        // Apple's VNGenerateOpticalFlowRequest header example: handler is
        // fromImage, targeted buffer is toImage. Current -> previous gives the
        // backward pixel displacement MetalFX expects. No raw network output.
        let flow: CVPixelBuffer = try autoreleasepool {
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: prior.small, options: [:])
            request.revision = VNGenerateOpticalFlowRequestRevision1
            request.computationAccuracy = .low
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
            request.keepNetworkOutput = false
            let handler = VNImageRequestHandler(cvPixelBuffer: small, options: [:])
            try handler.perform([request])
            guard let flow = request.results?.first?.pixelBuffer else { throw Failure.unavailable("光流估算没有输出") }
            guard CVPixelBufferGetWidth(flow) == width, CVPixelBufferGetHeight(flow) == height else {
                throw Failure.unavailable("光流尺寸不匹配")
            }
            return flow
        }
        let command = try resizer.makeCommandBuffer()
        references = []
        let motion = try texture(flow, format: .rg32Float, plane: 0, references: &references)
        // Vision owns this buffer. Copy it into a texture carrying all usage
        // bits required by MetalFX, rather than assuming cache texture usage.
        let motionInput = try Self.texture(device, format: .rg32Float, width: width, height: height,
                                           usage: effect.motionTextureUsage.union(.shaderRead))
        guard let blit = command.makeBlitCommandEncoder() else { throw Failure.encoding }
        blit.copy(from: motion, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: motionInput, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        effect.colorTexture = color; effect.prevColorTexture = prior.color
        effect.motionTexture = motionInput; effect.depthTexture = depth
        effect.outputTexture = result
        effect.deltaTime = Float(frame.pts - prior.frame.pts)
        effect.shouldResetHistory = resetHistory
        effect.encode(commandBuffer: command)

        let intermediate = try Self.buffer(sourcePool)
        let output = try Self.buffer(outputPool)
        let outY = try texture(intermediate, format: .r8Unorm, plane: 0, references: &references)
        let outUV = try texture(intermediate, format: .rg8Unorm, plane: 1, references: &references)
        guard let restore = command.makeComputeCommandEncoder() else { throw Failure.encoding }
        restore.setComputePipelineState(fromRGB)
        restore.setTexture(result, index: 0); restore.setTexture(outY, index: 1); restore.setTexture(outUV, index: 2)
        restore.setBytes(&matrix, length: MemoryLayout<Int32>.size, index: 0)
        dispatch(restore, width: width, height: height)
        restore.endEncoding()
        references += try resizer.encodeResize(intermediate, to: output, fullRange: false, command: command,
            preserving: (prior.frame.pixelBuffer, frame.pixelBuffer, frame.isFullRange))
        try withExtendedLifetime((flow, motionInput, intermediate, prior, frame, small, color, output)) {
            try resizer.finish(command, retaining: references)
        }
        for key in [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let value = CVBufferCopyAttachment(small, key, nil) { CVBufferSetAttachment(output, key, value, .shouldPropagate) }
        }
        previous = (frame, small, color)
        resetHistory = false
        hudProtectionActive = nv12 && CVPixelBufferIsPlanar(prior.frame.pixelBuffer)
        let middle = DecodedVideoFrame(pixelBuffer: output, pts: (prior.frame.pts + frame.pts) * 0.5,
            isBT709: frame.isBT709, colorSpaceCode: frame.colorSpaceCode, isFullRange: false, isInterpolated: true)
        return [middle, frame]
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, width: Int, height: Int) {
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
    }

    private func texture(_ buffer: CVPixelBuffer, format: MTLPixelFormat, plane: Int,
                         references: inout [CVMetalTexture]) throws -> MTLTexture {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, plane) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, plane) : CVPixelBufferGetHeight(buffer)
        var reference: CVMetalTexture?
        try Self.check(CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, plane, &reference))
        guard let reference, let texture = CVMetalTextureGetTexture(reference) else { throw Failure.encoding }
        references.append(reference)
        return texture
    }

    private static func texture(_ device: MTLDevice, format: MTLPixelFormat, width: Int, height: Int,
                                usage: MTLTextureUsage) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private; descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw Failure.encoding }
        return texture
    }

    private static func pool(width: Int, height: Int) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        try check(CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &pool))
        guard let pool else { throw Failure.encoding }; return pool
    }

    private static func buffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        try check(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer))
        guard let buffer else { throw Failure.encoding }; return buffer
    }

    private static func check(_ result: OSStatus) throws {
        if result != noErr { throw Failure.unavailable("系统处理错误 \(result)") }
    }

    private enum Failure: LocalizedError {
        case unavailable(String), encoding
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): return reason
            case .encoding: return "Metal 资源或命令创建失败"
            }
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    float2 kr_kb(int matrix) {
        return matrix == 0 ? float2(0.299, 0.114) : (matrix == 2 ? float2(0.2627, 0.0593) : float2(0.2126, 0.0722));
    }
    kernel void metalfx_nv12_to_rgb(texture2d<float, access::read> y [[texture(0)]],
        texture2d<float, access::sample> uv [[texture(1)]], texture2d<float, access::write> rgb [[texture(2)]],
        texture2d<float, access::write> depth [[texture(3)]], constant int &matrix [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= rgb.get_width() || p.y >= rgb.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 c = (uv.sample(s, (float2(p) + 0.5) / float2(rgb.get_width(), rgb.get_height())).rg * 255.0 - 128.0) / 224.0;
        float l = (y.read(p).r * 255.0 - 16.0) / 219.0;
        float2 k = kr_kb(matrix); float kg = 1.0 - k.x - k.y;
        float r = l + 2.0 * (1.0 - k.x) * c.y;
        float b = l + 2.0 * (1.0 - k.y) * c.x;
        float g = (l - k.x * r - k.y * b) / kg;
        rgb.write(float4(clamp(float3(r,g,b), 0.0, 1.0), 1.0), p);
        // No scene geometry comes through HDMI. Explicit flat-plane approximation.
        depth.write(float4(0.5), p);
    }
    kernel void metalfx_rgb_to_nv12(texture2d<float, access::read> rgb [[texture(0)]],
        texture2d<float, access::write> y [[texture(1)]], texture2d<float, access::write> uv [[texture(2)]],
        constant int &matrix [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= y.get_width() || p.y >= y.get_height()) return;
        float2 k = kr_kb(matrix); float3 weights = float3(k.x, 1.0-k.x-k.y, k.y);
        float3 c = clamp(rgb.read(p).rgb, 0.0, 1.0);
        float l = dot(c, weights);
        y.write(float4((16.0 + 219.0*l)/255.0), p);
        if ((p.x & 1) == 0 && (p.y & 1) == 0) {
            float3 average = (c + clamp(rgb.read(p+uint2(1,0)).rgb,0.0,1.0)
                + clamp(rgb.read(p+uint2(0,1)).rgb,0.0,1.0) + clamp(rgb.read(p+uint2(1,1)).rgb,0.0,1.0)) * 0.25;
            float ly = dot(average, weights);
            float2 chroma = float2((average.b-ly)/(2.0*(1.0-k.y)), (average.r-ly)/(2.0*(1.0-k.x)));
            uv.write(float4((128.0 + 224.0*chroma)/255.0, 0.0, 1.0), p/2);
        }
    }
    """
}
