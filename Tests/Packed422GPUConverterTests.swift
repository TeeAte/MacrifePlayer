import Foundation
import CoreVideo

@main
enum Packed422GPUConverterTests {
    static func main() throws {
        let converter = Packed422GPUConverter()
        // Changing size/range exercises pool reconfiguration while previous
        // outputs remain alive. Small width explicitly requires padded rows.
        var retained: [CVPixelBuffer] = []
        for (width, height, fullRange) in [(18, 6, false), (18, 6, true),
                                          (1920, 1080, false), (2560, 1440, false),
                                          (3840, 2160, false), (18, 6, false)] {
            let input = try source(width: width, height: height)
            if width == 18 { precondition(CVPixelBufferGetBytesPerRow(input) > width * 2) }
            CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let output = try converter.convert(input, fullRange: fullRange)
            precondition(CVPixelBufferGetWidth(output) == width && CVPixelBufferGetHeight(output) == height)
            let format = fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                   : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            precondition(CVPixelBufferGetPixelFormatType(output) == format)
            let matrix = CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil)
            precondition(matrix as? String == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
            try validate(output, width: width, height: height)
            retained.append(output)
            print("PASS: YUVS -> NV12 \(width)×\(height), \(fullRange ? "full" : "video") range; every Y/UV byte verified")
        }
        do {
            _ = try converter.convert(retained[0], fullRange: false)
            fatalError("NV12 must not be interpreted as packed YUVS")
        } catch { print("PASS: wrong source format rejected") }
        converter.reset()
        let fresh = try converter.convert(source(width: 18, height: 6), fullRange: false)
        try validate(fresh, width: 18, height: 6)
        print("PASS: reset/recreate; no capture device or AI model used")
    }

    private static func luma(_ x: Int, _ y: Int) -> UInt8 { UInt8((x * 7 + y * 13) & 255) }
    private static func u(_ pair: Int, _ y: Int) -> Int { (pair * 3 + y * 7) & 255 }
    private static func v(_ pair: Int, _ y: Int) -> Int { (19 + pair * 5 + y * 11) & 255 }

    private static func source(width: Int, height: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_422YpCbCr8_yuvs, [
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
        ] as CFDictionary, &value) == kCVReturnSuccess, let value else { throw Failure.buffer }
        guard CVPixelBufferLockBaseAddress(value, []) == kCVReturnSuccess else { throw Failure.buffer }
        defer { CVPixelBufferUnlockBaseAddress(value, []) }
        let stride = CVPixelBufferGetBytesPerRow(value)
        let bytes = CVPixelBufferGetBaseAddress(value)!.assumingMemoryBound(to: UInt8.self)
        memset(bytes, 0xee, stride * height)
        for y in 0..<height { for x in Swift.stride(from: 0, to: width, by: 2) {
            let index = y * stride + x * 2
            bytes[index] = luma(x,y); bytes[index + 1] = UInt8(u(x / 2,y))
            bytes[index + 2] = luma(x + 1,y); bytes[index + 3] = UInt8(v(x / 2,y))
        } }
        return value
    }

    private static func validate(_ buffer: CVPixelBuffer, width: Int, height: Int) throws {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw Failure.buffer }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let yBytes = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            precondition(yBytes[y * yStride + x] == luma(x,y), "Luma mismatch \(x),\(y)")
        } }
        for y in 0..<(height / 2) { for x in 0..<(width / 2) {
            let expectedU = UInt8((u(x,y * 2) + u(x,y * 2 + 1) + 1) / 2)
            let expectedV = UInt8((v(x,y * 2) + v(x,y * 2 + 1) + 1) / 2)
            precondition(uv[y * uvStride + x * 2] == expectedU, "U mismatch \(x),\(y)")
            precondition(uv[y * uvStride + x * 2 + 1] == expectedV, "V mismatch \(x),\(y)")
        } }
    }

    private enum Failure: Error { case buffer }
}
