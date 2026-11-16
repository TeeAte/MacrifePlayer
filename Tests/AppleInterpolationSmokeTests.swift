import Foundation
import CoreVideo
import QuartzCore

@main
enum AppleInterpolationSmokeTests {
    static func main() throws {
        guard #available(macOS 26.0, *) else { return }
        let engine = AppleLowLatencyInterpolator()
        var times: [Double] = []
        var lastPTS = -1.0
        for index in 0..<35 {
            var buffer: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
            precondition(CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                      attributes as CFDictionary, &buffer) == kCVReturnSuccess)
            let source = buffer!
            CVPixelBufferLockBaseAddress(source, [])
            for plane in 0..<2 {
                let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let height = CVPixelBufferGetHeightOfPlane(source, plane)
                let base = CVPixelBufferGetBaseAddressOfPlane(source, plane)!
                memset(base, plane == 0 ? 64 : 128, stride * height)
                if plane == 0 {
                    let bytes = base.assumingMemoryBound(to: UInt8.self)
                    for y in 270..<540 { for x in (480 + index * 4)..<(960 + index * 4) { bytes[y * stride + x] = 192 } }
                }
            }
            CVPixelBufferUnlockBaseAddress(source, [])
            CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            let frame = DecodedVideoFrame(pixelBuffer: source, pts: Double(index) / 30)
            let start = CACurrentMediaTime()
            guard let output = engine.interpolate(frame, sourceFPS: 30, targetFPS: 60) else {
                fatalError("Native interpolation failed: \(engine.snapshot.status)")
            }
            if index >= 5 { times.append((CACurrentMediaTime() - start) * 1000) }
            precondition(output.last!.pixelBuffer === source, "Source frame must retain original 1080p pixels")
            for item in output {
                precondition(item.pts > lastPTS)
                lastPTS = item.pts
                precondition(CVPixelBufferGetWidth(item.pixelBuffer) == 1920 && CVPixelBufferGetHeight(item.pixelBuffer) == 1080)
            }
            if index > 0 {
                precondition(output.count == 2 && output[0].isInterpolated && !output[1].isInterpolated)
                precondition(abs(output[0].pts - (Double(index) - 0.5) / 30) < 0.00001)
                let middle = output[0].pixelBuffer
                CVPixelBufferLockBaseAddress(middle, .readOnly)
                let bytes = CVPixelBufferGetBaseAddressOfPlane(middle, 0)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(middle, 0)
                precondition(bytes[400 * stride + 750] > bytes[100 * stride + 100] + 80, "Generated frame must contain the moving image")
                CVPixelBufferUnlockBaseAddress(middle, .readOnly)
            }
        }
        precondition(engine.snapshot.frames == 34)
        print(engine.snapshot.status)
        precondition(engine.interpolate(DecodedVideoFrame(pixelBuffer: makeTinyBuffer(), pts: 9), sourceFPS: 24, targetFPS: 60) == nil)
        let ordered = times.sorted()
        print(String(format: "PASS: Apple native 1080p source → 720p AI → 1080p output; mean %.2f ms, p95 %.2f ms (downscale + AI + upscale, 30 samples)", times.reduce(0, +) / Double(times.count), ordered[28]))
        engine.reset()
        precondition(engine.snapshot.frames == 0)
        try testConsole30Capture(engine)
        try testStaticHUD(engine)
        try testStaticHUD(engine, fullRange: true)
        try testHUDOverMovingBackground(engine)
    }

    private static func testStaticHUD(_ engine: AppleLowLatencyInterpolator, fullRange: Bool = false) throws {
        engine.reset()
        var worstMAE = 0.0
        var movingDifference = 0.0
        for index in 0..<8 {
            let source = makeConsoleBuffer(index: index * 10, fullRange: fullRange)
            CVPixelBufferLockBaseAddress(source, [])
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
            let bytes = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt8.self)
            // Small stationary text-like strokes, including one-pixel lines.
            for y in 80..<144 {
                for x in 101..<481 {
                    let gx = (x - 101) % 19, gy = (y - 80) % 21
                    bytes[y * stride + x] = (gx == 0 || (gx < 10 && [0, 10, 19].contains(gy))) ? 235 : 32
                }
            }
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
            let uv = CVPixelBufferGetBaseAddressOfPlane(source, 1)!.assumingMemoryBound(to: UInt8.self)
            for y in 40..<72 { for x in 50..<240 {
                uv[y * uvStride + x * 2] = x % 3 == 0 ? 64 : 192
                uv[y * uvStride + x * 2 + 1] = x % 5 == 0 ? 196 : 80
            } }
            CVPixelBufferUnlockBaseAddress(source, [])
            let output = engine.interpolate(DecodedVideoFrame(pixelBuffer: source, pts: Double(index) / 30,
                                                              isFullRange: fullRange), sourceFPS: 30, targetFPS: 60)!
            precondition(output.last!.pixelBuffer === source)
            if index == 0 { continue }
            let middle = output[0].pixelBuffer
            precondition(!output[0].isFullRange)
            CVPixelBufferLockBaseAddress(source, .readOnly)
            CVPixelBufferLockBaseAddress(middle, .readOnly)
            let a = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt8.self)
            let b = CVPixelBufferGetBaseAddressOfPlane(middle, 0)!.assumingMemoryBound(to: UInt8.self)
            let sa = CVPixelBufferGetBytesPerRowOfPlane(source, 0), sb = CVPixelBufferGetBytesPerRowOfPlane(middle, 0)
            var error = 0.0
            func limitedY(_ value: UInt8) -> Double { fullRange ? 16 + 219 * Double(value) / 255 : Double(value) }
            for y in 84..<140 { for x in 105..<477 { error += abs(limitedY(a[y * sa + x]) - Double(b[y * sb + x])) } }
            worstMAE = max(worstMAE, error / Double(56 * 372))
            let auv = CVPixelBufferGetBaseAddressOfPlane(source, 1)!.assumingMemoryBound(to: UInt8.self)
            let buv = CVPixelBufferGetBaseAddressOfPlane(middle, 1)!.assumingMemoryBound(to: UInt8.self)
            let sau = CVPixelBufferGetBytesPerRowOfPlane(source, 1), sbu = CVPixelBufferGetBytesPerRowOfPlane(middle, 1)
            for y in 44..<68 { for x in 108..<474 {
                let expected = fullRange ? 128 + (Double(auv[y * sau + x]) - 128) * 224 / 255 : Double(auv[y * sau + x])
                precondition(abs(expected - Double(buv[y * sbu + x])) <= 1, "Static colored HUD must retain chroma and correct range")
            } }
            if index > 3 {
                for y in 300..<500 { for x in 480..<1360 { movingDifference += abs(limitedY(a[y * sa + x]) - Double(b[y * sb + x])) } }
            }
            CVPixelBufferUnlockBaseAddress(middle, .readOnly)
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        print(String(format: "HUD (%@) static fine-stroke MAE %.3f / 255; moving ROI difference %.0f", fullRange ? "full-range" : "video-range", worstMAE, movingDifference))
        fflush(stdout)
        precondition(worstMAE <= 1, "Static HUD must not alternate between sharp source pixels and blurred AI pixels")
        precondition(movingDifference > 1000, "Moving region must retain genuine interpolation rather than copying the current source")
        engine.reset()
    }

    private static func testHUDOverMovingBackground(_ engine: AppleLowLatencyInterpolator) throws {
        engine.reset()
        var worstStrokeError = 0.0
        for index in 0..<10 {
            let source = makeConsoleBuffer(index: index * 10)
            CVPixelBufferLockBaseAddress(source, [])
            let bytes = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 0)
            for y in 340..<460 { for x in 1450..<1890 {
                // A HUD stays in place while the background and antialiasing
                // pixels change. Requiring a static 3×3 neighbourhood fails here.
                let background = 40 + ((x + index * 7) / 3 + y / 5) % 12 * 3
                let gx = (x - 1460) % 19, gy = (y - 355) % 23
                let inText = x >= 1460 && x < 1870 && y >= 355 && y < 440
                let stroke = inText && (gx == 0 || (gx < 10 && [0, 10, 20].contains(gy)))
                let antialias = inText && (gx == 1 || (gx < 11 && [1, 11, 21].contains(gy)))
                bytes[y * stride + x] = UInt8(stroke ? 220 : (antialias ? (background + 220) / 2 : background))
            } }
            CVPixelBufferUnlockBaseAddress(source, [])
            let output = engine.interpolate(DecodedVideoFrame(pixelBuffer: source, pts: Double(index) / 30), sourceFPS: 30, targetFPS: 60)!
            if index == 0 { continue }
            precondition(output[0].isInterpolated && output.last!.pixelBuffer === source)
            let middle = output[0].pixelBuffer
            CVPixelBufferLockBaseAddress(middle, .readOnly)
            let generated = CVPixelBufferGetBaseAddressOfPlane(middle, 0)!.assumingMemoryBound(to: UInt8.self)
            let middleStride = CVPixelBufferGetBytesPerRowOfPlane(middle, 0)
            var error = 0.0, count = 0.0
            for y in 357..<438 { for x in 1462..<1868 {
                let gx = (x - 1460) % 19, gy = (y - 355) % 23
                if gx == 0 || (gx < 10 && [0, 10, 20].contains(gy)) {
                    error += abs(Double(generated[y * middleStride + x]) - 220)
                    count += 1
                }
            } }
            CVPixelBufferUnlockBaseAddress(middle, .readOnly)
            worstStrokeError = max(worstStrokeError, error / count)
        }
        print(String(format: "HUD over moving background: stationary stroke error %.3f / 255", worstStrokeError))
        fflush(stdout)
        precondition(worstStrokeError <= 1, "HUD strokes must remain stationary over moving/transparent backgrounds")
        engine.discardPreviousFrame()
        let next = engine.interpolate(DecodedVideoFrame(pixelBuffer: makeConsoleBuffer(index: 1), pts: 1), sourceFPS: 30, targetFPS: 60)!
        precondition(next.count == 1, "Cadence changes must reset the HUD history and interpolation pair")
        engine.reset()
    }

    private static func testConsole30Capture(_ engine: AppleLowLatencyInterpolator) throws {
        var selector = Console30FrameSelector()
        var lastPTS = -1.0
        var delivered = 0
        // Real 1080p buffers arrive as A,A,B,B at 60Hz. Only even capture
        // timestamps reach the actual system AI, with no detection warmup.
        for tick in 0..<70 {
            let source = makeConsoleBuffer(index: tick / 2)
            let pts = Double(tick) / 60
            let selection = selector.select(pts: pts, captureFPS: 60, enabled: true)
            guard selection.keep else { continue }
            guard let output = engine.interpolate(DecodedVideoFrame(pixelBuffer: source, pts: pts),
                sourceFPS: selection.contentFPS, targetFPS: 60) else { fatalError(engine.snapshot.status) }
            precondition(output.last!.pixelBuffer === source)
            for frame in output {
                if lastPTS >= 0 { precondition(abs(frame.pts - lastPTS - 1.0 / 60) < 0.00001) }
                lastPTS = frame.pts
                delivered += 1
            }
        }
        precondition(delivered == 69 && engine.snapshot.frames == 34)
        engine.discardPreviousFrame()
        let source = makeConsoleBuffer(index: 36)
        let next = engine.interpolate(DecodedVideoFrame(pixelBuffer: source, pts: 2), sourceFPS: 30, targetFPS: 60)!
        precondition(next.count == 1 && !next[0].isInterpolated)
        precondition(engine.snapshot.frames == 34, "Reset pair history without reloading model or resetting counters")
        print("PASS: 1080p60 capture / console30 → actual AI60; 35 original + 34 AI frames, correct first-copy PTS and 60Hz spacing")
        engine.reset()
    }

    private static func makeConsoleBuffer(index: Int, fullRange: Bool = false) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        precondition(CVPixelBufferCreate(nil, 1920, 1080, fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                       attributes as CFDictionary, &buffer) == kCVReturnSuccess)
        let result = buffer!
        CVPixelBufferLockBaseAddress(result, [])
        for plane in 0..<2 {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(result, plane)
            let height = CVPixelBufferGetHeightOfPlane(result, plane)
            let base = CVPixelBufferGetBaseAddressOfPlane(result, plane)!
            memset(base, plane == 0 ? 64 : 128, stride * height)
            if plane == 0 {
                let bytes = base.assumingMemoryBound(to: UInt8.self)
                for y in 270..<540 { for x in (480 + index * 4)..<(960 + index * 4) { bytes[y * stride + x] = 192 } }
            }
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        return result
    }

    private static func makeTinyBuffer() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer)
        return buffer!
    }
}
