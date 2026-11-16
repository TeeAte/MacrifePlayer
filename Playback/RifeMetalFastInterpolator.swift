import Foundation
import CoreVideo
import VideoToolbox
import QuartzCore
import RifeMetal

/// Owned by the video processing thread. A stream retains the previous frame's
/// encoder features; UI/display threads only read the separately locked snapshot.
final class RifeMetalFastInterpolator {
    private let processingLock = NSLock()
    private let statsLock = NSLock()
    private var session: RifeMetalFastSession?
    private var configurationKey = ""
    private var failures: [String: String] = [:]
    private var generated = 0
    private var elapsed = 0.0
    private var status = "RifeMetal Fast 待命"
    private var active = false

    var snapshot: (frames: Int, status: String, processingSeconds: Double, active: Bool) {
        statsLock.lock(); defer { statsLock.unlock() }
        return (generated, status, generated > 0 ? elapsed / Double(generated) : 0, active)
    }

    func reset() {
        processingLock.lock(); defer { processingLock.unlock() }
        session = nil; configurationKey = ""; failures.removeAll()
        statsLock.lock()
        generated = 0; elapsed = 0; status = "RifeMetal Fast 待命"; active = false
        statsLock.unlock()
    }

    func discardPreviousFrame() {
        processingLock.lock(); defer { processingLock.unlock() }
        session?.discardPreviousFrame()
        statsLock.lock(); active = false; statsLock.unlock()
    }

    /// First frame primes the cache and passes through. Subsequent pairs produce
    /// [midpoint, original], matching the existing low-latency presentation clock.
    func interpolate(_ frame: DecodedVideoFrame, sourceFPS: Double, targetFPS: Double,
                     maxInputHeight: Int) -> [DecodedVideoFrame]? {
        processingLock.lock(); defer { processingLock.unlock() }
        guard AppleLowLatencyInterpolator.supports(sourceFPS: sourceFPS, targetFPS: targetFPS),
              !frame.isHDR else {
            session?.discardPreviousFrame()
            setStatus("RifeMetal Fast 仅支持 SDR 2X，使用 Core ML RIFE 回退")
            return nil
        }
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        let key = "\(width)x\(height)|\(maxInputHeight)|\(CVPixelBufferGetPixelFormatType(frame.pixelBuffer))|\(frame.colorSpaceCode)|\(frame.isFullRange)"
        if let failure = failures[key] { setStatus(failure); return nil }
        do {
            if configurationKey != key {
                session = nil
                session = try RifeMetalFastSession(sourceWidth: width, sourceHeight: height,
                    maxInputHeight: maxInputHeight, colorSpaceCode: frame.colorSpaceCode)
                configurationKey = key
            }
            guard let session else { return nil }
            let start = CACurrentMediaTime()
            let frames = try session.interpolate(frame)
            let count = frames.filter(\.isInterpolated).count
            statsLock.lock()
            generated += count
            if count > 0 { elapsed += CACurrentMediaTime() - start }
            active = true
            status = "RifeMetal Fast · RIFE 4.25 FP16 · 输入 \(session.width)×\(session.height) · 光流 \(session.flowWidth)×\(session.flowHeight)"
            status += count > 0 ? String(format: " · 处理均耗 %.1f ms", elapsed * 1000 / Double(generated)) : " · 首帧缓存就绪"
            statsLock.unlock()
            return frames
        } catch {
            session = nil; configurationKey = ""
            let failure = "RifeMetal Fast 不可用，使用 Core ML RIFE 回退：\(error.localizedDescription)"
            failures[key] = failure
            setStatus(failure)
            NSLog("[RifeMetalFast] %@", error.localizedDescription)
            return nil
        }
    }

    private func setStatus(_ text: String) {
        statsLock.lock(); status = text; active = false; statsLock.unlock()
    }
}

private final class RifeMetalFastSession {
    let width: Int
    let height: Int
    // Upstream fast pads input to multiples of 256 before quarter-scale IFNet.
    var flowWidth: Int { ((width + 255) / 256 * 256) / 4 }
    var flowHeight: Int { ((height + 255) / 256 * 256) / 4 }
    private let stream: RifeStream
    private let inputPool: CVPixelBufferPool
    private let middlePool: CVPixelBufferPool
    private let outputPool: CVPixelBufferPool
    private let inputTransfer: VTPixelTransferSession
    private let outputTransfer: VTPixelTransferSession
    private var previousPTS: Double?

    init(sourceWidth: Int, sourceHeight: Int, maxInputHeight: Int, colorSpaceCode: Int32) throws {
        let size = InferenceGeometry.fit(sourceWidth: sourceWidth, sourceHeight: sourceHeight, maxHeight: maxInputHeight)
        width = size.width; height = size.height
        inputPool = try Self.pool(width: size.width, height: size.height, format: kCVPixelFormatType_32BGRA)
        middlePool = try Self.pool(width: size.width, height: size.height, format: kCVPixelFormatType_32BGRA)
        outputPool = try Self.pool(width: sourceWidth, height: sourceHeight,
                                  format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        // Resolve the embedded resources without the upstream bundled URL's
        // force unwrap, so a malformed app can use the normal RIFE fallback.
        guard let resources = Bundle.main.resourceURL,
              let weights = Bundle(url: resources.appendingPathComponent("RifeMetal_RifeMetal.bundle")),
              let modelURL = weights.url(forResource: "rife-v4.25", withExtension: "rmw"),
              let kernels = Bundle(url: resources.appendingPathComponent("RifeMetal_RifeMetalCore.bundle")),
              kernels.url(forResource: "default", withExtension: "metallib") != nil else {
            throw Failure.unavailable("缺少内置 RIFE 4.25 权重或 Metal 内核")
        }
        let configuration = RifeConfiguration(modelURL: modelURL, qualityTier: .fast)
        let interpolator = try RifeInterpolator(configuration: configuration)
        stream = try interpolator.makeStream(width: size.width, height: size.height)
        let input = try Self.transfer()
        do {
            let output = try Self.transfer()
            do {
                let matrix = colorSpaceCode == 0 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
                    : (colorSpaceCode == 2 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
                try Self.check(VTSessionSetProperty(output, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                                  value: matrix))
                outputTransfer = output
            } catch {
                VTPixelTransferSessionInvalidate(output)
                throw error
            }
        } catch {
            VTPixelTransferSessionInvalidate(input)
            throw error
        }
        inputTransfer = input
    }

    deinit {
        VTPixelTransferSessionInvalidate(inputTransfer)
        VTPixelTransferSessionInvalidate(outputTransfer)
    }

    func discardPreviousFrame() {
        previousPTS = nil
        stream.reset()
    }

    func interpolate(_ frame: DecodedVideoFrame) throws -> [DecodedVideoFrame] {
        guard frame.pts.isFinite else { throw Failure.unavailable("帧时间戳无效") }
        if let previousPTS, !(0.001..<0.15).contains(frame.pts - previousPTS) {
            discardPreviousFrame()
        }
        let input = try Self.buffer(inputPool)
        try Self.check(VTPixelTransferSessionTransferImage(inputTransfer, from: frame.pixelBuffer, to: input))
        let middle = try Self.buffer(middlePool)
        let produced = try stream.push(input, into: middle)
        CVBufferPropagateAttachments(input, middle)
        let priorPTS = previousPTS
        previousPTS = frame.pts
        guard produced, let priorPTS else { return [frame] }
        let output = try Self.buffer(outputPool)
        try Self.check(VTPixelTransferSessionTransferImage(outputTransfer, from: middle, to: output))
        let matrix = frame.colorSpaceCode == 0 ? kCVImageBufferYCbCrMatrix_ITU_R_601_4
            : (frame.colorSpaceCode == 2 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey] {
            if let value = CVBufferCopyAttachment(frame.pixelBuffer, key, nil) {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            }
        }
        let interpolated = DecodedVideoFrame(pixelBuffer: output, pts: (priorPTS + frame.pts) * 0.5,
            isBT709: frame.isBT709, colorSpaceCode: frame.colorSpaceCode, isFullRange: false,
            isInterpolated: true, transferFunction: frame.transferFunction, peakNits: frame.peakNits)
        return [interpolated, frame]
    }

    private static func transfer() throws -> VTPixelTransferSession {
        var value: VTPixelTransferSession?
        try check(VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &value))
        guard let value else { throw Failure.unavailable("像素转换会话创建失败") }
        do {
            try check(VTSessionSetProperty(value, key: kVTPixelTransferPropertyKey_RealTime, value: kCFBooleanTrue))
            try check(VTSessionSetProperty(value, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal))
        } catch {
            VTPixelTransferSessionInvalidate(value)
            throw error
        }
        return value
    }

    private static func pool(width: Int, height: Int, format: OSType) throws -> CVPixelBufferPool {
        var pool: CVPixelBufferPool?
        try check(CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true,
        ] as CFDictionary, &pool))
        guard let pool else { throw Failure.unavailable("像素缓冲池创建失败") }
        return pool
    }

    private static func buffer(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        try check(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &value))
        guard let value else { throw Failure.unavailable("像素缓冲创建失败") }
        return value
    }

    private static func check(_ result: OSStatus) throws {
        if result != noErr { throw Failure.unavailable("像素转换错误 \(result)") }
    }

    private enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self { case .unavailable(let reason): return reason }
        }
    }
}
