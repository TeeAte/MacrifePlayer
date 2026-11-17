import Foundation
import CoreVideo
import Metal
import Vision
import QuartzCore

/// Capture-only, stationary glyph support. Detection is asynchronous and never
/// blocks capture/model queues. A narrow band around stable strokes inside text
/// boxes can modify a generated frame; source frames are never written.
final class CaptureTextStabilizer {
    private let stateLock = NSLock()
    private let gpuLock = NSLock()
    private let detectionQueue = DispatchQueue(label: "macrife.capture.text-detection", qos: .utility)
    private let detectionConverter = Packed422GPUConverter()
    private let fixedRegions: [CGRect]?
    private var detectedRegions: [CGRect] = [] // normalized, top-left origin
    private var dimensions = CGSize.zero
    private var generation = 0
    private var detecting = false
    private var lastRequest = -Double.greatestFiniteMagnitude
    private var lastResult = -Double.greatestFiniteMagnitude
    private var gpu: GPU?
    private var postprocessWindow = InterpolationProcessingWindow()

    /// Fixed normalized regions also support deterministic offline diagnostics.
    init(fixedRegions: [CGRect]? = nil) { self.fixedRegions = fixedRegions }

    func reset() {
        stateLock.lock()
        generation &+= 1; detectedRegions = []; dimensions = .zero
        lastRequest = -Double.greatestFiniteMagnitude; lastResult = lastRequest
        postprocessWindow.reset()
        stateLock.unlock()
        gpuLock.lock()
        if let gpu { CVMetalTextureCacheFlush(gpu.cache,0) }
        gpuLock.unlock()
    }

    var activeRegionCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return fixedRegions?.count ?? (CACurrentMediaTime() - lastResult < 3 ? detectedRegions.count : 0)
    }

    var postprocessSeconds: Double {
        stateLock.lock(); defer { stateLock.unlock() }
        return postprocessWindow.estimate
    }

    func observe(_ frame: DecodedVideoFrame) {
        guard fixedRegions == nil else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let now = CACurrentMediaTime()
        stateLock.lock()
        if dimensions != size { generation &+= 1; dimensions = size; detectedRegions = []; lastRequest = -1e9 }
        guard !detecting, now - lastRequest >= 1 else { stateLock.unlock(); return }
        detecting = true; lastRequest = now; let token = generation
        stateLock.unlock()
        detectionQueue.async { [weak self] in
            guard let self else { return }
            let boxes: [CGRect] = autoreleasepool {
                do {
                    let input: CVPixelBuffer
                    if CVPixelBufferGetPixelFormatType(frame.pixelBuffer) == kCVPixelFormatType_422YpCbCr8_yuvs {
                        input = try self.detectionConverter.convert(frame.pixelBuffer, fullRange: frame.isFullRange)
                    } else { input = frame.pixelBuffer }
                    // Geometric text detection, without an OCR recognition/language model.
                    let request = VNDetectTextRectanglesRequest()
                    request.reportCharacterBoxes = false
                    try VNImageRequestHandler(cvPixelBuffer: input).perform([request])
                    return (request.results ?? []).compactMap { observation in
                        let b = observation.boundingBox
                        guard b.width > 0.004, b.height > 0.005, b.height < 0.18,
                              b.width * b.height < 0.12 else { return nil }
                        return CGRect(x: b.minX, y: 1-b.maxY, width: b.width, height: b.height)
                    }
                } catch { return [] }
            }
            self.stateLock.lock()
            if token == self.generation { self.detectedRegions = boxes; self.lastResult = CACurrentMediaTime() }
            self.detecting = false
            self.stateLock.unlock()
        }
    }

    private func regions(width: Int, height: Int) -> [CGRect] {
        stateLock.lock()
        let normalized = fixedRegions ?? ((dimensions == CGSize(width: width, height: height)
            && CACurrentMediaTime() - lastResult < 3) ? detectedRegions : [])
        stateLock.unlock()
        let bounds = CGRect(x: 0,y: 0,width: width,height: height)
        var merged: [CGRect] = []
        for box in normalized.prefix(64) {
            var rect = CGRect(x: box.minX * Double(width),y: box.minY * Double(height),
                width: box.width * Double(width),height: box.height * Double(height)).insetBy(dx: -4,dy: -4).integral.intersection(bounds)
            guard !rect.isEmpty else { continue }
            let x = floor(rect.minX / 2) * 2,y = floor(rect.minY / 2) * 2
            rect = CGRect(x: x,y: y,width: ceil(rect.maxX / 2)*2-x,height: ceil(rect.maxY / 2)*2-y).intersection(bounds)
            // An overlapping ROI must not blend the same pixel twice.
            var index = 0
            while index < merged.count {
                if rect.intersects(merged[index]) { rect = rect.union(merged.remove(at: index)); index = 0 }
                else { index += 1 }
            }
            merged.append(rect)
        }
        return merged
    }

    @discardableResult
    func encode(previous: DecodedVideoFrame, current: DecodedVideoFrame, output: CVPixelBuffer,
                outputFullRange: Bool, command: MTLCommandBuffer, slot: Int = 0) throws -> Bool {
        let w = CVPixelBufferGetWidth(output), h = CVPixelBufferGetHeight(output)
        let supported = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_422YpCbCr8_yuvs]
        guard output !== previous.pixelBuffer, output !== current.pixelBuffer,
              supported.contains(CVPixelBufferGetPixelFormatType(previous.pixelBuffer)),
              supported.contains(CVPixelBufferGetPixelFormatType(current.pixelBuffer)),
              w == CVPixelBufferGetWidth(previous.pixelBuffer), h == CVPixelBufferGetHeight(previous.pixelBuffer),
              w == CVPixelBufferGetWidth(current.pixelBuffer), h == CVPixelBufferGetHeight(current.pixelBuffer),
              [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
                .contains(CVPixelBufferGetPixelFormatType(output)) else { return false }
        let boxes = regions(width: w,height: h)
        guard !boxes.isEmpty else { return false }
        gpuLock.lock(); defer { gpuLock.unlock() }
        if gpu == nil { gpu = try GPU(device: command.device) }
        guard let gpu else { return false }
        try gpu.encode(previous: previous,current: current,output: output,outputFullRange: outputFullRange,
                       boxes: boxes,command: command,slot: slot)
        return true
    }

    /// CoreML/RifeMetal already return completed GPU results. Their workers use
    /// separate scratch slots; native Apple/MetalFX encode into their existing batch.
    func apply(previous: DecodedVideoFrame, current: DecodedVideoFrame,
               outputs: [DecodedVideoFrame], slot: Int) -> [DecodedVideoFrame] {
        guard outputs.contains(where: \.isInterpolated), activeRegionCount > 0 else { return outputs }
        let start = CACurrentMediaTime()
        do {
            let queue: MTLCommandQueue? = try {
                gpuLock.lock(); defer { gpuLock.unlock() }
                if gpu == nil, let device = MTLCreateSystemDefaultDevice() { gpu = try GPU(device: device) }
                return gpu?.queue
            }()
            guard let command = queue?.makeCommandBuffer() else { return outputs }
            var encoded = false
            for frame in outputs where frame.isInterpolated {
                encoded = try encode(previous: previous,current: current,output: frame.pixelBuffer,
                    outputFullRange: frame.isFullRange,command: command,slot: slot) || encoded
            }
            if encoded {
                command.commit(); command.waitUntilCompleted()
                stateLock.lock(); postprocessWindow.record(CACurrentMediaTime()-start); stateLock.unlock()
            }
        } catch { /* Preserve the actual generated frames on unsupported formats. */ }
        return outputs
    }

    private final class GPU {
        let queue: MTLCommandQueue
        let maskPipeline, blendPipeline: MTLComputePipelineState
        let cache: CVMetalTextureCache
        let device: MTLDevice
        var scratch: [Int: MTLTexture] = [:]
        var counts: [Int: MTLBuffer] = [:]
        var operations = 0
        init(device: MTLDevice) throws {
            self.device = device
            guard let queue = device.makeCommandQueue() else { throw Failure.unavailable }
            self.queue = queue
            let library = try device.makeLibrary(source: CaptureTextStabilizer.shader,options: nil)
            maskPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "capture_text_mask")!)
            blendPipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "capture_text_blend")!)
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(nil,nil,device,nil,&cache) == kCVReturnSuccess,let cache else { throw Failure.unavailable }
            self.cache = cache
        }
        struct Params {
            var x,y,width,height: Int32
            var sourceWidth,sourceHeight,previousPacked,currentPacked: UInt32
            var previousFull,currentFull,outputFull,padding: UInt32
        }
        func encode(previous: DecodedVideoFrame,current: DecodedVideoFrame,output: CVPixelBuffer,outputFullRange: Bool,
                    boxes: [CGRect],command: MTLCommandBuffer,slot: Int) throws {
            var refs: [CVMetalTexture] = []
            func texture(_ pb: CVPixelBuffer,_ plane: Int,_ format: MTLPixelFormat) throws -> MTLTexture {
                let packed = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_422YpCbCr8_yuvs
                let w = packed ? CVPixelBufferGetWidth(pb) : CVPixelBufferGetWidthOfPlane(pb,plane)
                let h = packed ? CVPixelBufferGetHeight(pb) : CVPixelBufferGetHeightOfPlane(pb,plane)
                var ref: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(nil,cache,pb,nil,format,w,h,plane,&ref) == kCVReturnSuccess,
                      let ref,let texture = CVMetalTextureGetTexture(ref) else { throw Failure.unavailable }
                refs.append(ref); return texture
            }
            func source(_ pb: CVPixelBuffer) throws -> (MTLTexture,MTLTexture,Bool) {
                let packed = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_422YpCbCr8_yuvs
                let y = try texture(pb,0,packed ? .rg8Unorm : .r8Unorm)
                return (y,packed ? y : try texture(pb,1,.rg8Unorm),packed)
            }
            let a = try source(previous.pixelBuffer),b = try source(current.pixelBuffer)
            let outY = try texture(output,0,.r8Unorm),outUV = try texture(output,1,.rg8Unorm)
            let mw = Int(boxes.map(\.width).max()!) + 6,mh = Int(boxes.map(\.height).max()!) + 6
            if scratch[slot] == nil || scratch[slot]!.width < mw || scratch[slot]!.height < mh {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,width: mw,height: mh,mipmapped: false)
                descriptor.usage = [.shaderRead,.shaderWrite]
                guard let mask = device.makeTexture(descriptor: descriptor) else { throw Failure.unavailable }
                scratch[slot] = mask
            }
            let mask = scratch[slot]!
            if counts[slot] == nil { counts[slot] = device.makeBuffer(length: 8,options: .storageModeShared) }
            guard let counters = counts[slot] else { throw Failure.unavailable }
            for box in boxes {
                guard let clear = command.makeBlitCommandEncoder() else { throw Failure.unavailable }
                clear.fill(buffer: counters,range: 0..<8,value: 0); clear.endEncoding()
                var p = Params(x: Int32(box.minX),y: Int32(box.minY),width: Int32(box.width),height: Int32(box.height),
                    sourceWidth: UInt32(outY.width),sourceHeight: UInt32(outY.height),previousPacked: a.2 ? 1:0,currentPacked: b.2 ? 1:0,
                    previousFull: previous.isFullRange ? 1:0,currentFull: current.isFullRange ? 1:0,outputFull: outputFullRange ? 1:0,padding: 0)
                for (pipeline,width,height) in [(maskPipeline,Int(box.width)+6,Int(box.height)+6),
                                                (blendPipeline,Int(box.width),Int(box.height))] {
                    guard let encoder = command.makeComputeCommandEncoder() else { throw Failure.unavailable }
                    encoder.setComputePipelineState(pipeline)
                    for (index,t) in [a.0,a.1,b.0,b.1,mask,outY,outUV].enumerated() { encoder.setTexture(t,index: index) }
                    encoder.setBytes(&p,length: MemoryLayout<Params>.size,index: 0)
                    encoder.setBuffer(counters,offset: 0,index: 1)
                    encoder.dispatchThreads(MTLSize(width: width,height: height,depth: 1),threadsPerThreadgroup: MTLSize(width: 16,height: 8,depth: 1))
                    encoder.endEncoding()
                }
            }
            let retainedRefs = refs
            command.addCompletedHandler { _ in withExtendedLifetime((previous,current,output,retainedRefs,mask)) {} }
            operations += 1
            if operations % 24 == 0 { CVMetalTextureCacheFlush(cache,0) }
        }
    }
    private enum Failure: Error { case unavailable }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct P { int x,y,width,height;uint sw,sh,packedA,packedB,fullA,fullB,fullOut,padding; };
    float yl(texture2d<float,access::read> t,int2 p,uint full) {
        p=clamp(p,int2(0),int2(t.get_width()-1,t.get_height()-1));float y=t.read(uint2(p)).r;
        return full ? (16.0f+219.0f*y)/255.0f : y;
    }
    float2 uvl(texture2d<float,access::read> y,texture2d<float,access::read> uv,int2 p,uint packed,uint full) {
        p=clamp(p,int2(0),int2(y.get_width()-1,y.get_height()-1));float2 c;
        if(packed){uint x=uint(p.x/2)*2,y0=uint(p.y/2)*2,y1=min(y0+1,y.get_height()-1);
            c=(float2(y.read(uint2(x,y0)).g,y.read(uint2(x+1,y0)).g)+float2(y.read(uint2(x,y1)).g,y.read(uint2(x+1,y1)).g))*0.5f;
        }else c=uv.read(uint2(p)/2).rg;
        return full ? (c-128.0f/255.0f)*(224.0f/255.0f)+128.0f/255.0f : c;
    }
    kernel void capture_text_mask(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::read> auv [[texture(1)]],
        texture2d<float,access::read> b [[texture(2)]],texture2d<float,access::read> buv [[texture(3)]],
        texture2d<float,access::write> mask [[texture(4)]],constant P &p [[buffer(0)]],device atomic_uint *counts [[buffer(1)]],
        uint2 g [[thread_position_in_grid]],ushort lane [[thread_index_in_simdgroup]]) {
        if(g.x>=uint(p.width+6)||g.y>=uint(p.height+6))return;
        int2 q=int2(p.x,p.y)+int2(g)-3;float ca=yl(a,q,p.fullA),cb=yl(b,q,p.fullB),weight=0;
        float pattern=0;
        for(int yy=-1;yy<=1;++yy)for(int xx=-1;xx<=1;++xx)
            pattern=max(pattern,abs((yl(a,q+int2(xx,yy),p.fullA)-ca)-(yl(b,q+int2(xx,yy),p.fullB)-cb)));
        float candidate=0,matched=0;
        const int2 dirs[4]={int2(1,0),int2(0,1),int2(1,1),int2(1,-1)};
        for(int d=0;d<4;++d)for(int r=2;r<=4;r+=2) {
                int2 v=dirs[d]*r;
                float2 va=float2(yl(a,q-v,p.fullA),yl(a,q+v,p.fullA));
                float2 vb=float2(yl(b,q-v,p.fullB),yl(b,q+v,p.fullB));
                float ra=max(min(ca-va.x,ca-va.y),min(va.x-ca,va.y-ca));
                float rb=max(min(cb-vb.x,cb-vb.y),min(vb.x-cb,vb.y-cb));
                candidate=max(candidate,max(ra,rb));
                if(min(ra,rb)>0.07f && abs(ra-rb)<0.065f)matched=1;
        }
        if(abs(ca-cb)<0.03f && pattern<0.065f && all(abs(uvl(a,auv,q,p.packedA,p.fullA)-uvl(b,buv,q,p.packedB,p.fullB))<0.025f))weight=matched;
        uint localTotal=0,localStable=0;
        if(g.x>=3 && g.y>=3 && g.x<uint(p.width+3) && g.y<uint(p.height+3)) {
            // Strong glyph strokes should dominate weak moving background texture.
            uint score=uint(clamp(pow(max(0.0f,candidate-0.05f)*2.0f,2.0f)*255.0f,1.0f,255.0f));
            if(candidate>0.07f)localTotal=score;
            if(weight>0)localStable=score;
        }
        // Reduce per SIMD group instead of contending on one atomic per pixel.
        uint total=simd_sum(localTotal),stable=simd_sum(localStable);
        if(lane==0){if(total>0)atomic_fetch_add_explicit(counts,total,memory_order_relaxed);
            if(stable>0)atomic_fetch_add_explicit(counts+1,stable,memory_order_relaxed);}
        mask.write(float4(weight),g);
    }
    float matte(texture2d<float,access::read> mask,int2 g,float a,float b) {
        float m=0;
        for(int y=-3;y<=3;++y)for(int x=-3;x<=3;++x)
            m=max(m,mask.read(uint2(g+int2(x,y)+3)).r*(1.0f-smoothstep(1.4f,3.4f,length(float2(x,y)))));
        return m*(1.0f-smoothstep(0.018f,0.065f,abs(a-b)));
    }
    kernel void capture_text_blend(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::read> auv [[texture(1)]],
        texture2d<float,access::read> b [[texture(2)]],texture2d<float,access::read> buv [[texture(3)]],
        texture2d<float,access::read> mask [[texture(4)]],texture2d<float,access::read_write> yout [[texture(5)]],
        texture2d<float,access::read_write> uvout [[texture(6)]],constant P &p [[buffer(0)]],device atomic_uint *counts [[buffer(1)]],uint2 g [[thread_position_in_grid]]) {
        if(g.x>=uint(p.width)||g.y>=uint(p.height))return;
        uint total=atomic_load_explicit(counts,memory_order_relaxed),stable=atomic_load_explicit(counts+1,memory_order_relaxed);
        if(total==0 || float(stable)<0.6f*float(total))return;
        int2 q=int2(p.x,p.y)+int2(g);float ya=yl(a,q,p.fullA),yb=yl(b,q,p.fullB),m=matte(mask,int2(g),ya,yb);
        float original=(ya+yb)*0.5f;if(p.fullOut)original=(255.0f*original-16.0f)/219.0f;
        if(m>0)yout.write(float4(mix(yout.read(uint2(q)).r,original,m)),uint2(q));
        if((q.x&1)==0&&(q.y&1)==0) {
            float cm=0;
            for(int yy=0;yy<2;++yy)for(int xx=0;xx<2;++xx){int2 d=int2(xx,yy);
                // The mask has a 3px halo; clamp only the ROI-relative sample coordinate.
                int2 mg=clamp(int2(g)+d,int2(0),int2(p.width-1,p.height-1));
                cm+=matte(mask,mg,yl(a,q+d,p.fullA),yl(b,q+d,p.fullB));}
            cm*=0.25f;float2 c=(uvl(a,auv,q,p.packedA,p.fullA)+uvl(b,buv,q,p.packedB,p.fullB))*0.5f;
            if(p.fullOut)c=(c-128.0f/255.0f)*(255.0f/224.0f)+128.0f/255.0f;
            if(cm>0)uvout.write(float4(mix(uvout.read(uint2(q)/2).rg,c,cm),0,1),uint2(q)/2);
        }
    }
    """
}
