import Foundation
import CoreVideo
import CoreGraphics
import CoreText
import QuartzCore
import Metal

@main
enum CaptureTextStabilityTests {
    static let width = 1920, height = 1080
    static let glyphs: [UInt8] = {
        var pixels = [UInt8](repeating: 0,count: width*height)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress,width: width,height: height,bitsPerComponent: 8,
                bytesPerRow: width,space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            let font = CTFontCreateWithName("PingFangSC-Regular" as CFString,24,nil)
            let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray: 1,alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "HUD 0123 静止文字",attributes: attributes))
            context.textPosition = CGPoint(x: 100,y: 100)
            CTLineDraw(line,context)
        }
        return pixels
    }()
    static var glyphBounds: CGRect {
        var x0=width,y0=height,x1=0,y1=0
        for y in 0..<height { for x in 0..<width where glyphs[y*width+x] > 0 {
            x0=min(x0,x);y0=min(y0,y);x1=max(x1,x);y1=max(y1,y)
        } }
        return CGRect(x: x0,y: y0,width: x1-x0+1,height: y1-y0+1)
    }
    static var regions: [CGRect] { [CGRect(x: glyphBounds.minX/Double(width),y: glyphBounds.minY/Double(height),
        width: (glyphBounds.width+18)/Double(width),height: glyphBounds.height/Double(height))] }

    static func make(index: Double, textShift: Int = 0, blurred: Bool = false, full: Bool = false, colored: Bool = false) -> CVPixelBuffer {
        var result: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,width,height,full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&result) == kCVReturnSuccess)
        let pb=result!;CVPixelBufferLockBaseAddress(pb,[])
        let bytes=CVPixelBufferGetBaseAddressOfPlane(pb,0)!.assumingMemoryBound(to:UInt8.self)
        let stride=CVPixelBufferGetBytesPerRowOfPlane(pb,0)
        for y in 0..<height { for x in 0..<width {
            var alpha=0.0
            if blurred {
                for yy in -1...1 { for xx in -1...1 {
                    let sx=x-textShift+xx,sy=y+yy
                    if sx>=0 && sx<width && sy>=0 && sy<height { alpha += Double(glyphs[sy*width+sx])/255/9 }
                } }
            } else if x-textShift>=0 && x-textShift<width { alpha=Double(glyphs[y*width+x-textShift])/255 }
            let start=800+Int(index*24)
            let base:Double = (450..<600).contains(y) && (start..<(start+160)).contains(x) ? 192:64
            var value=base+((colored ? 175:235)-base)*alpha
            if full { value=(value-16)*255/219 }
            bytes[y*stride+x]=UInt8(max(0,min(255,value.rounded())))
        } }
        memset(CVPixelBufferGetBaseAddressOfPlane(pb,1)!,128,CVPixelBufferGetBytesPerRowOfPlane(pb,1)*height/2)
        if colored {
            let uv=CVPixelBufferGetBaseAddressOfPlane(pb,1)!.assumingMemoryBound(to:UInt8.self)
            let stride=CVPixelBufferGetBytesPerRowOfPlane(pb,1)
            for y in 0..<(height/2) {for x in 0..<(width/2) {
                var alpha=0.0
                for dy in 0..<2 {for dx in 0..<2 {
                    let sx=x*2+dx-textShift,sy=y*2+dy
                    if sx>=0 && sx<width {alpha+=Double(glyphs[sy*width+sx])/255/4}
                }}
                if blurred { alpha *= 0.5 }
                var u=128-40*alpha,v=128+32*alpha
                if full {u=128+(u-128)*255/224;v=128+(v-128)*255/224}
                uv[y*stride+x*2]=UInt8(u.rounded());uv[y*stride+x*2+1]=UInt8(v.rounded())
            }}
        }
        CVPixelBufferUnlockBaseAddress(pb,[])
        return pb
    }
    static func luma(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        let base=CVPixelBufferGetBaseAddressOfPlane(pb,0)!.assumingMemoryBound(to:UInt8.self)
        let stride=CVPixelBufferGetBytesPerRowOfPlane(pb,0)
        return (0..<height).flatMap { Array(UnsafeBufferPointer(start:base+$0*stride,count:width)) }
    }
    static func packed(_ source: CVPixelBuffer) -> CVPixelBuffer {
        var output: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_422YpCbCr8_yuvs,
            [kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary,&output)==kCVReturnSuccess)
        let pb=output!;CVPixelBufferLockBaseAddress(source,.readOnly);CVPixelBufferLockBaseAddress(pb,[])
        let y=CVPixelBufferGetBaseAddressOfPlane(source,0)!.assumingMemoryBound(to:UInt8.self),ys=CVPixelBufferGetBytesPerRowOfPlane(source,0)
        let uv=CVPixelBufferGetBaseAddressOfPlane(source,1)!.assumingMemoryBound(to:UInt8.self),us=CVPixelBufferGetBytesPerRowOfPlane(source,1)
        let dst=CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to:UInt8.self),ds=CVPixelBufferGetBytesPerRow(pb)
        for row in 0..<height {for x in stride(from:0,to:width,by:2) {
            dst[row*ds+x*2]=y[row*ys+x];dst[row*ds+x*2+1]=uv[row/2*us+x]
            dst[row*ds+x*2+2]=y[row*ys+x+1];dst[row*ds+x*2+3]=uv[row/2*us+x+1]
        }}
        CVPixelBufferUnlockBaseAddress(source,.readOnly);CVPixelBufferUnlockBaseAddress(pb,[]);return pb
    }
    static func chroma(_ pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb,.readOnly);defer { CVPixelBufferUnlockBaseAddress(pb,.readOnly) }
        let base=CVPixelBufferGetBaseAddressOfPlane(pb,1)!.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRowOfPlane(pb,1)
        return (0..<(height/2)).flatMap {Array(UnsafeBufferPointer(start:base+$0*stride,count:width))}
    }
    static func chromaError(_ pixels:[UInt8],_ truth:[UInt8])->Double {
        var sum=0.0,count=0.0
        for y in 0..<(height/2){for x in 0..<(width/2) {
            let alpha=Int(glyphs[y*2*width+x*2])+Int(glyphs[y*2*width+x*2+1])+Int(glyphs[(y*2+1)*width+x*2])+Int(glyphs[(y*2+1)*width+x*2+1])
            if alpha>128 {for c in 0..<2 {let i=y*width+x*2+c;sum+=abs(Double(pixels[i])-Double(truth[i]));count+=1}}
        }}
        return sum/max(1,count)
    }
    static func error(_ pixels: [UInt8],_ truth: [UInt8]) -> Double {
        var sum=0.0,count=0.0
        for i in glyphs.indices where glyphs[i]>32 { sum+=abs(Double(pixels[i])-Double(truth[i]));count+=1 }
        return sum/max(1,count)
    }
    static func checkOutside(_ before: [UInt8],_ after: [UInt8]) {
        let b = CGRect(x: regions[0].minX*Double(width),y: regions[0].minY*Double(height),
            width: regions[0].width*Double(width),height: regions[0].height*Double(height)).insetBy(dx:-6,dy:-6)
        for y in 0..<height { for x in 0..<width where !b.contains(CGPoint(x:x,y:y)) {
            precondition(before[y*width+x]==after[y*width+x],"Pixels outside the text ROI must remain the real AI result")
        } }
    }
    static func main() throws {
        let truth=luma(make(index:0))
        for full in [false,true] {
            let a=DecodedVideoFrame(pixelBuffer:make(index:0,full:full),pts:0,isFullRange:full)
            let b=DecodedVideoFrame(pixelBuffer:make(index:1,full:full),pts:1.0/30,isFullRange:full)
            let output=DecodedVideoFrame(pixelBuffer:make(index:0.5,blurred:true),pts:1.0/60,isInterpolated:true)
            let before=luma(output.pixelBuffer)
            let stabilizer=CaptureTextStabilizer(fixedRegions:regions)
            _=stabilizer.apply(previous:a,current:b,outputs:[output],slot:0)
            let after=luma(output.pixelBuffer),old=error(before,truth),new=error(after,truth)
            print(String(format:"Static text %@: MAE %.3f → %.3f /255",full ? "full-range":"video-range",old,new))
            precondition(new < old*0.45,"Stationary glyph flicker must fall without replacing the surrounding AI motion")
            checkOutside(before,after)
            let shifted=DecodedVideoFrame(pixelBuffer:make(index:1,textShift:12,full:full),pts:1.0/30,isFullRange:full)
            let moving=DecodedVideoFrame(pixelBuffer:make(index:0.5,textShift:6,blurred:true),pts:1.0/60,isInterpolated:true)
            let movingBefore=luma(moving.pixelBuffer)
            _=stabilizer.apply(previous:a,current:shifted,outputs:[moving],slot:0)
            precondition(movingBefore == luma(moving.pixelBuffer),"Moving text must retain the generated midpoint")
        }
        for full in [false,true] {
            let a=DecodedVideoFrame(pixelBuffer:packed(make(index:0,full:full,colored:true)),pts:0,isFullRange:full)
            let b=DecodedVideoFrame(pixelBuffer:packed(make(index:1,full:full,colored:true)),pts:1.0/30,isFullRange:full)
            let middle=DecodedVideoFrame(pixelBuffer:make(index:0.5,blurred:true,colored:true),pts:1.0/60,isInterpolated:true)
            let reference=make(index:0,colored:true)
            let baseline=luma(middle.pixelBuffer),truth=luma(reference),beforeUV=chroma(middle.pixelBuffer),truthUV=chroma(reference)
            let stabilizer=CaptureTextStabilizer(fixedRegions:regions)
            _=stabilizer.apply(previous:a,current:b,outputs:[middle],slot:0)
            let fixed=luma(middle.pixelBuffer)
            print(String(format:"YUVS colored static text %@: %.3f → %.3f",full ? "full":"video",error(baseline,truth),error(fixed,truth)))
            precondition(error(fixed,truth)<error(baseline,truth)*0.5)
            let afterUV=chroma(middle.pixelBuffer)
            print(String(format:"Colored chroma: %.3f → %.3f",chromaError(beforeUV,truthUV),chromaError(afterUV,truthUV)))
            precondition(chromaError(afterUV,truthUV)<chromaError(beforeUV,truthUV)*0.5)
            checkOutside(baseline,fixed)
        }
        let detector=CaptureTextStabilizer()
        detector.observe(DecodedVideoFrame(pixelBuffer:make(index:0),pts:0))
        let deadline=CACurrentMediaTime()+5
        while detector.activeRegionCount==0 && CACurrentMediaTime()<deadline { Thread.sleep(forTimeInterval:0.01) }
        precondition(detector.activeRegionCount>0,"The actual asynchronous text detector must find the fixture text")
        print("Detected text regions:",detector.activeRegionCount)
        detector.reset();precondition(detector.activeRegionCount==0)

        let model=AppleLowLatencyInterpolator(),stabilizer=CaptureTextStabilizer(fixedRegions:regions)
        let first=DecodedVideoFrame(pixelBuffer:make(index:0),pts:0)
        let second=DecodedVideoFrame(pixelBuffer:make(index:1),pts:1.0/30)
        _=model.interpolate(first,sourceFPS:30,targetFPS:60,maxInferenceHeight:576)
        let generated=model.interpolate(second,sourceFPS:30,targetFPS:60,maxInferenceHeight:576)!
        let before=luma(generated[0].pixelBuffer)
        _=stabilizer.apply(previous:first,current:second,outputs:generated,slot:0)
        let after=luma(generated[0].pixelBuffer)
        print(String(format:"Actual Apple576 static text: MAE %.3f → %.3f /255",error(before,truth),error(after,truth)))
        precondition(error(after,truth)<error(before,truth)*0.6)
        checkOutside(before,after)
        var mass=0.0,weighted=0.0
        for x in 750..<1050 {let value=max(0,Double(after[500*width+x])-64);mass+=value;weighted+=value*Double(x)}
        let center=weighted/mass
        precondition(abs(center-891.5)<2,"Actual AI motion must still be halfway between source objects")
        precondition(generated.last!.pixelBuffer === second.pixelBuffer)
        let queue=MTLCreateSystemDefaultDevice()!.makeCommandQueue()!
        var gpu:[Double]=[],wall:[Double]=[]
        for i in 0..<40 {
            let command=queue.makeCommandBuffer()!,start=CACurrentMediaTime()
            let encoded=try stabilizer.encode(previous:first,current:second,output:generated[0].pixelBuffer,
                outputFullRange:false,command:command)
            precondition(encoded)
            command.commit();command.waitUntilCompleted();precondition(command.status == .completed)
            if i>4 {gpu.append((command.gpuEndTime-command.gpuStartTime)*1000);wall.append((CACurrentMediaTime()-start)*1000)}
        }
        print(String(format:"1080p glyph ROI GPU mean %.3fms, encode+wait p95 %.3fms",gpu.reduce(0,+)/Double(gpu.count),wall.sorted()[Int(Double(wall.count-1)*0.95)]))
        let metalFX=MetalFXCaptureInterpolator()
        for index in 0..<4 {
            let source=make(index:Double(index))
            guard let frames=metalFX.interpolate(DecodedVideoFrame(pixelBuffer:source,pts:Double(index)/30),
                sourceFPS:30,targetFPS:60,maxInferenceHeight:576,textStabilizer:stabilizer) else {
                fatalError(metalFX.snapshot.status)
            }
            precondition(frames.last!.pixelBuffer === source)
            if index>0 {
                precondition(frames[0].isInterpolated)
                precondition(error(luma(frames[0].pixelBuffer),truth)<1.0,"MetalFX must use the same capture text stability batch")
            }
        }
        precondition(metalFX.snapshot.frames==3)
        print("PASS: MetalFX capture text batch and original-frame identity")
        print("PASS: static glyphs, moving-text bypass, exact outside-ROI preservation, source identity and genuine midpoint motion")
    }
}
