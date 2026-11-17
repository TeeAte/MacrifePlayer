import Foundation
import CoreVideo
import QuartzCore

@main
enum RifeMetalSourceDetailTests {
    static func makeSource() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,1920,1080,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&buffer)==kCVReturnSuccess)
        let b=buffer!;CVPixelBufferLockBaseAddress(b,[])
        let p=CVPixelBufferGetBaseAddressOfPlane(b,0)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRowOfPlane(b,0)
        for y in 0..<1080 { for x in 0..<1920 { p[y*stride+x]=UInt8(90+((x/3+y/3)%2)*80+x/120) } }
        memset(CVPixelBufferGetBaseAddressOfPlane(b,1)!,128,CVPixelBufferGetBytesPerRowOfPlane(b,1)*540)
        CVPixelBufferUnlockBaseAddress(b,[]);return b
    }
    static func pixels(_ b: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(b,.readOnly);defer { CVPixelBufferUnlockBaseAddress(b,.readOnly) }
        let p=CVPixelBufferGetBaseAddressOfPlane(b,0)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRowOfPlane(b,0)
        return (0..<1080).flatMap { Array(UnsafeBufferPointer(start:p+$0*stride,count:1920)) }
    }
    static func main() throws {
        let engine=RifeMetalFastInterpolator()
        for index in 0..<4 {
            let source=makeSource()
            let frame=DecodedVideoFrame(pixelBuffer:source,pts:Double(index)/60)
            let start=CACurrentMediaTime()
            guard let output=engine.interpolate(frame,sourceFPS:60,targetFPS:120,maxInputHeight:576) else {
                fatalError(engine.snapshot.status)
            }
            precondition(output.last!.pixelBuffer===source)
            guard index>0 else { continue }
            precondition(output.count==2 && output[0].isInterpolated)
            let truth=pixels(source)
            let generated=pixels(output[0].pixelBuffer)
            var error=0.0
            for y in 350..<730 { for x in 650..<1270 { let i=y*1920+x; error+=abs(Double(truth[i])-Double(generated[i])) } }
            let mae=error/(380*620)
            print(String(format:"RifeMetal 576 budget / 1080p source: static fine-detail MAE %.3f, pair %.2fms",mae,(CACurrentMediaTime()-start)*1000))
            fflush(stdout)
            precondition(mae<16,"Original-resolution warp must retain source texture instead of returning a low-resolution enlargement")
        }
        precondition(engine.snapshot.frames==3)
        precondition(engine.snapshot.status.contains("原尺寸合成 1920×1080"))
        precondition(engine.snapshot.status.contains("光流 256×192"))
        print(engine.snapshot.status)
        print("PASS: RifeMetal 576 inference budget, full-resolution warp/cropped output, static detail, original identity and actual generated frames")
    }
}
