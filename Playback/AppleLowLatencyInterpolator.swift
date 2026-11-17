import Foundation
import CoreVideo
import CoreMedia
import VideoToolbox
import QuartzCore
import Metal

/// 单一视频处理线程拥有会话；只把计数与状态以快照形式交给 UI。
/// 原帧不经过缩放；中间帧保留系统模型的真实输出，不用源图回填替代运动。
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
                    + (session.hudProtectionActive ? " · 系统真实中间帧" : "")
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
    private let packedConverter = Packed422GPUConverter()
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
        resizer = try NV12GPUResizer()
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

    }

    func interpolate(_ frame: DecodedVideoFrame) throws -> [DecodedVideoFrame] {
        let detail = CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_422YpCbCr8_yuvs
            ? try packedConverter.convert(frame.pixelBuffer, fullRange: frame.isFullRange) : frame.pixelBuffer
        let small = try Self.buffer(from: sourcePool)
        let format = CVPixelBufferGetPixelFormatType(detail)
        let command: MTLCommandBuffer?
        if let resizer, format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            command = try resizer.makeCommandBuffer()
        } else { command = nil }
        var textureReferences: [CVMetalTexture] = []
        if let command, let resizer {
            textureReferences += try resizer.encodeResize(detail, to: small,
                fullRange: frame.isFullRange, command: command)
        } else {
            try resize(frame.pixelBuffer, to: small, fullRange: frame.isFullRange)
        }
        let prior = previous
        previous = (frame, small)
        guard let prior, frame.pts - prior.frame.pts > 0.001,
              frame.pts - prior.frame.pts < 0.15 else {
            hudProtectionActive = false

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
                fullRange: false, command: command)
            try withExtendedLifetime((parameters, frame, prior, detail, small, intermediate, output)) {
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

/// Format/size conversion only. It never replaces model-generated pixels with
/// an original frame. File/capture model sessions own separate instances.
final class NV12GPUResizer {
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let cache: CVMetalTextureCache
    private var operations = 0

    init() throws {
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw ResizeError.unavailable }
        self.queue=queue
        let library=try device.makeLibrary(source:Self.shader,options:nil)
        guard let function=library.makeFunction(name:"resize_nv12") else { throw ResizeError.unavailable }
        pipeline=try device.makeComputePipelineState(function:function)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache)==kCVReturnSuccess,let cache else { throw ResizeError.unavailable }
        self.cache=cache
    }

    func makeCommandBuffer() throws -> MTLCommandBuffer {
        guard let command=queue.makeCommandBuffer() else { throw ResizeError.unavailable }
        return command
    }

    func resize(_ source: CVPixelBuffer,to destination: CVPixelBuffer,fullRange: Bool) throws {
        let command=try makeCommandBuffer()
        let references=try encodeResize(source,to:destination,fullRange:fullRange,command:command)
        try finish(command,retaining:references)
    }

    func encodeResize(_ source: CVPixelBuffer,to destination: CVPixelBuffer,fullRange: Bool,
                      command: MTLCommandBuffer) throws -> [CVMetalTexture] {
        var references: [CVMetalTexture]=[]
        func texture(_ buffer: CVPixelBuffer,_ plane: Int) throws -> MTLTexture {
            var ref: CVMetalTexture?
            guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,buffer,nil,plane==0 ? .r8Unorm : .rg8Unorm,
                CVPixelBufferGetWidthOfPlane(buffer,plane),CVPixelBufferGetHeightOfPlane(buffer,plane),plane,&ref)==kCVReturnSuccess,
                let ref,let texture=CVMetalTextureGetTexture(ref) else { throw ResizeError.unavailable }
            references.append(ref);return texture
        }
        let textures=try [texture(source,0),texture(source,1),texture(destination,0),texture(destination,1)]
        guard let encoder=command.makeComputeCommandEncoder() else { throw ResizeError.unavailable }
        encoder.setComputePipelineState(pipeline)
        for (i,t) in textures.enumerated() { encoder.setTexture(t,index:i) }
        var range: UInt32=fullRange ? 1 : 0
        encoder.setBytes(&range,length:4,index:0)
        encoder.dispatchThreads(MTLSize(width:CVPixelBufferGetWidth(destination),height:CVPixelBufferGetHeight(destination),depth:1),
                                threadsPerThreadgroup:MTLSize(width:16,height:16,depth:1))
        encoder.endEncoding()
        for key in [kCVImageBufferYCbCrMatrixKey,kCVImageBufferColorPrimariesKey,kCVImageBufferTransferFunctionKey] {
            if let value=CVBufferCopyAttachment(source,key,nil) { CVBufferSetAttachment(destination,key,value,.shouldPropagate) }
        }
        operations+=1
        if operations % 120 == 0 { CVMetalTextureCacheFlush(cache,0) }
        return references
    }

    func finish(_ command: MTLCommandBuffer,retaining references: [CVMetalTexture]) throws {
        command.commit();command.waitUntilCompleted()
        withExtendedLifetime(references) {}
        guard command.status == .completed else { throw command.error ?? ResizeError.unavailable }
    }

    private enum ResizeError: Error { case unavailable }
    private static let shader="""
    #include <metal_stdlib>
    using namespace metal;
    float4 resize_sample(texture2d<float,access::sample> image,float2 uv,float2 outputSize) {
        constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
        if (image.get_width()<=outputSize.x && image.get_height()<=outputSize.y) return image.sample(s,uv);
        float4 value=0;
        for (int y=0;y<4;++y) for (int x=0;x<4;++x)
            value+=image.sample(s,uv+(float2(x,y)/4.0f-0.375f)/outputSize);
        return value/16.0f;
    }
    kernel void resize_nv12(texture2d<float,access::sample> yIn [[texture(0)]],
        texture2d<float,access::sample> uvIn [[texture(1)]],texture2d<float,access::write> yOut [[texture(2)]],
        texture2d<float,access::write> uvOut [[texture(3)]],constant uint &fullRange [[buffer(0)]],
        uint2 p [[thread_position_in_grid]]) {
        if (p.x<yOut.get_width() && p.y<yOut.get_height()) {
            float2 size=float2(yOut.get_width(),yOut.get_height());
            float y=resize_sample(yIn,(float2(p)+0.5f)/size,size).r;
            if (fullRange) y=(16+219*y)/255;
            yOut.write(float4(y,0,0,1),p);
        }
        if (p.x<uvOut.get_width() && p.y<uvOut.get_height()) {
            float2 size=float2(uvOut.get_width(),uvOut.get_height());
            float2 uv=resize_sample(uvIn,(float2(p)+0.5f)/size,size).rg;
            if (fullRange) uv=(uv-128.0f/255)*224.0f/255+128.0f/255;
            uvOut.write(float4(uv,0,1),p);
        }
    }
    """
}
