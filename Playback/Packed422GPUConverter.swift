import Foundation
import CoreVideo
import Metal

/// Capture YUVS/YUY2 -> NV12 on Metal, independently of AI model loading.
/// Pixel values retain their range; only chroma is vertically subsampled.
final class Packed422GPUConverter {
    private let lock = NSLock()
    private var context: Context?

    func reset() {
        lock.lock(); defer { lock.unlock() }
        context = nil
    }

    func convert(_ source: CVPixelBuffer, fullRange: Bool) throws -> CVPixelBuffer {
        lock.lock(); defer { lock.unlock() }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_422YpCbCr8_yuvs,
              width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw Failure.invalidInput
        }
        if context == nil { context = try Context() }
        guard let context else { throw Failure.unavailable }
        return try context.convert(source, fullRange: fullRange)
    }

    private final class Context {
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState
        let cache: CVMetalTextureCache
        private var pool: CVPixelBufferPool?
        private var poolKey = ""
        private var conversions = 0

        init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
                throw Failure.unavailable
            }
            self.queue = queue
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
                  let cache else { throw Failure.unavailable }
            self.cache = cache
            let library = try device.makeLibrary(source: Packed422GPUConverter.shader, options: nil)
            guard let function = library.makeFunction(name: "capture_yuvs_to_nv12") else { throw Failure.unavailable }
            pipeline = try device.makeComputePipelineState(function: function)
        }

        func convert(_ source: CVPixelBuffer, fullRange: Bool) throws -> CVPixelBuffer {
            let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
            let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                   : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let key = "\(width)x\(height)|\(format)"
            if poolKey != key {
                pool = nil
                CVMetalTextureCacheFlush(cache, 0)
                var newPool: CVPixelBufferPool?
                guard CVPixelBufferPoolCreate(nil, nil, [
                    kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                    kCVPixelBufferPixelFormatTypeKey: format,
                    kCVPixelBufferIOSurfacePropertiesKey: [:],
                    kCVPixelBufferMetalCompatibilityKey: true,
                ] as CFDictionary, &newPool) == kCVReturnSuccess, let newPool else {
                    throw Failure.unavailable
                }
                pool = newPool; poolKey = key
            }
            guard let pool else { throw Failure.unavailable }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let output = buffer else { throw Failure.unavailable }
            var references: [CVMetalTexture] = []
            func texture(_ buffer: CVPixelBuffer, format: MTLPixelFormat, width: Int, height: Int, plane: Int) throws -> MTLTexture {
                var reference: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format,
                    width, height, plane, &reference) == kCVReturnSuccess,
                      let reference, let texture = CVMetalTextureGetTexture(reference) else {
                    throw Failure.unavailable
                }
                references.append(reference)
                return texture
            }
            // CoreVideo supplies row stride. Texture dimensions are image pixels,
            // never bytesPerRow/2 (which would include alignment padding).
            let packed = try texture(source, format: .rg8Unorm, width: width, height: height, plane: 0)
            let y = try texture(output, format: .r8Unorm, width: width, height: height, plane: 0)
            let uv = try texture(output, format: .rg8Unorm, width: width / 2, height: height / 2, plane: 1)
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                throw Failure.unavailable
            }
            command.label = "Capture YUVS -> NV12 (Metal)"
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(packed, index: 0); encoder.setTexture(y, index: 1); encoder.setTexture(uv, index: 2)
            encoder.dispatchThreads(MTLSize(width: width / 2, height: height / 2, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            encoder.endEncoding()
            // Source and texture wrappers must stay alive until the capture
            // conversion finishes. The destination may then enter another queue.
            try withExtendedLifetime((source, output, references)) {
                command.commit()
                command.waitUntilCompleted()
                guard command.status == .completed else {
                    throw command.error ?? Failure.unavailable
                }
            }
            CVBufferPropagateAttachments(source, output)
            conversions += 1
            if conversions % 24 == 0 { CVMetalTextureCacheFlush(cache, 0) }
            return output
        }
    }

    private enum Failure: LocalizedError {
        case invalidInput, unavailable
        var errorDescription: String? {
            switch self {
            case .invalidInput: return "需要偶数宽高的 YUVS/YUY2 采集帧"
            case .unavailable: return "YUVS Metal 像素转换不可用"
            }
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void capture_yuvs_to_nv12(texture2d<float, access::read> source [[texture(0)]],
        texture2d<float, access::write> y [[texture(1)]],
        texture2d<float, access::write> uv [[texture(2)]], uint2 p [[thread_position_in_grid]]) {
        if (p.x >= uv.get_width() || p.y >= uv.get_height()) return;
        uint2 q = p * 2;
        float2 a = source.read(q).rg;
        float2 b = source.read(q + uint2(1,0)).rg;
        float2 c = source.read(q + uint2(0,1)).rg;
        float2 d = source.read(q + uint2(1,1)).rg;
        y.write(float4(a.x), q); y.write(float4(b.x), q + uint2(1,0));
        y.write(float4(c.x), q + uint2(0,1)); y.write(float4(d.x), q + uint2(1,1));
        // YUY2 = Y0 U Y1 V; average only vertically, rounding to a byte.
        float2 chroma = floor((float2(a.y,b.y) + float2(c.y,d.y)) * 127.5 + 0.5) / 255.0;
        uv.write(float4(chroma,0,1), p);
    }
    """
}
