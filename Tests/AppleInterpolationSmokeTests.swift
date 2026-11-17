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
                if index >= 5 {
                    var mass=0.0, weighted=0.0
                    for x in 400..<1250 {
                        let value=max(0.0,Double(bytes[400*stride+x])-64)
                        mass+=value;weighted+=value*Double(x)
                    }
                    let center=weighted/max(1,mass), expected=719.5+(Double(index)-0.5)*4
                    precondition(abs(center-expected)<1.5,"Middle-frame motion must differ from both original endpoints")
                }
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
        try testIndependentSessions()
        try testBufferedFileOutput()
    }

    private static func testBufferedFileOutput() throws {
        let file = AppleLowLatencyInterpolator()
        let a = makeConsoleBuffer(index: 0), b = makeConsoleBuffer(index: 1)
        precondition(file.interpolate(DecodedVideoFrame(pixelBuffer: a, pts: 0),
            sourceFPS: 24, targetFPS: 48, maxInferenceHeight: 720, restoreSourceSize: false)!.count == 1)
        let result = file.interpolate(DecodedVideoFrame(pixelBuffer: b, pts: 1.0/24),
            sourceFPS: 24, targetFPS: 48, maxInferenceHeight: 720, restoreSourceSize: false)!
        precondition(result.count == 2 && result[0].isInterpolated && result[1].pixelBuffer === b)
        precondition(CVPixelBufferGetWidth(result[0].pixelBuffer) == 1280 && CVPixelBufferGetHeight(result[0].pixelBuffer) == 720,
                     "Cache actual model pixels, then let the renderer scale once")
        precondition(abs(result[0].pts - 1.0/48) < 0.00001)
        file.reset()
        CVPixelBufferLockBaseAddress(result[0].pixelBuffer, .readOnly)
        let bytes = CVPixelBufferGetBaseAddressOfPlane(result[0].pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(result[0].pixelBuffer, 0)
        precondition(bytes[300 * stride + 500] > bytes[50 * stride + 50], "A queued generated frame must survive session reset")
        CVPixelBufferUnlockBaseAddress(result[0].pixelBuffer, .readOnly)
        print("PASS: buffered file native-size AI output, 4:2:0 lifetime, PTS and unchanged original frame")
    }

    private static func testIndependentSessions() throws {
        let file=AppleLowLatencyInterpolator(), capture=AppleLowLatencyInterpolator()
        let a=makeConsoleBuffer(index:0),b=makeConsoleBuffer(index:1),c=makeConsoleBuffer(index:2)
        precondition(file.interpolate(DecodedVideoFrame(pixelBuffer:a,pts:0),sourceFPS:24,targetFPS:48)!.count==1)
        precondition(capture.interpolate(DecodedVideoFrame(pixelBuffer:a,pts:100),sourceFPS:30,targetFPS:60)!.count==1)
        let fileFrames=file.interpolate(DecodedVideoFrame(pixelBuffer:b,pts:1.0/24),sourceFPS:24,targetFPS:48)!
        let captureFrames=capture.interpolate(DecodedVideoFrame(pixelBuffer:b,pts:100+1.0/30),sourceFPS:30,targetFPS:60)!
        precondition(abs(fileFrames[0].pts-1.0/48)<0.00001)
        precondition(abs(captureFrames[0].pts-(100+1.0/60))<0.00001)
        capture.reset()
        let next=file.interpolate(DecodedVideoFrame(pixelBuffer:c,pts:2.0/24),sourceFPS:24,targetFPS:48)!
        precondition(next.count==2 && file.snapshot.frames==2 && capture.snapshot.frames==0)
        print("PASS: independent file24→48 and capture30→60 model histories; closing capture preserves file interpolation")
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
