import Foundation
import Metal
import QuartzCore

@main
enum RIFEMetalKernelTests {
    static let reference = """
    struct P {uint sw,sh,mw,mh;};
    kernel void ref_up(const device half *f [[buffer(0)]],const device half *m [[buffer(1)]],device half *ff [[buffer(2)]],device half *mm [[buffer(3)]],constant P &p [[buffer(4)]],uint2 q [[thread_position_in_grid]]) {
        if(q.x>=p.sw||q.y>=p.sh)return;float x=(float(q.x)+0.5f)*float(p.mw)/float(p.sw)-0.5f,y=(float(q.y)+0.5f)*float(p.mh)/float(p.sh)-0.5f;
        for(uint c=0;c<4;++c)ff[c*p.sw*p.sh+q.y*p.sw+q.x]=half(rife_sample(f,c,p.mw,p.mh,x,y)*((c&1)?float(p.sh)/p.mh:float(p.sw)/p.mw));
        mm[q.y*p.sw+q.x]=half(rife_sample(m,0,p.mw,p.mh,x,y));
    }
    kernel void ref_warp(const device half *src [[buffer(0)]],const device half *flow [[buffer(1)]],device half *out [[buffer(2)]],constant P &p [[buffer(3)]],uint2 q [[thread_position_in_grid]]) {
        if(q.x>=p.sw||q.y>=p.sh)return;uint i=q.y*p.sw+q.x,n=p.sw*p.sh;
        for(uint c=0;c<3;++c)out[c*n+i]=half(rife_sample(src,c,p.sw,p.sh,float(q.x)+float(flow[i]),float(q.y)+float(flow[n+i])));
    }
    kernel void ref_blend(const device half *a [[buffer(0)]],const device half *b [[buffer(1)]],const device half *m [[buffer(2)]],device half *out [[buffer(3)]],constant P &p [[buffer(4)]],uint2 q [[thread_position_in_grid]]) {
        if(q.x>=p.sw||q.y>=p.sh)return;uint i=q.y*p.sw+q.x,n=p.sw*p.sh;float w=1.0f/(1.0f+exp(-float(m[i])));
        for(uint c=0;c<3;++c)out[c*n+i]=half(float(a[c*n+i])*w+float(b[c*n+i])*(1-w));
    }
    kernel void color_test(const device float4 *rgb [[buffer(0)]],device float4 *yuv [[buffer(1)]],device float4 *decoded [[buffer(2)]],constant float2 &p [[buffer(3)]],uint x [[thread_position_in_grid]]) {
        float3 v=rife_rgb_to_yuv(rgb[x].rgb,p.y>0.5f,p.x);yuv[x]=float4(v,1);
        float3 quant=round(v*255.0f)/255.0f;decoded[x]=float4(rife_yuv_to_rgb(quant.x,quant.y,quant.z,p.y>0.5f,p.x),1);
    }
    """
    static func main() throws {
        let device=MTLCreateSystemDefaultDevice()!,queue=device.makeCommandQueue()!
        let library=try device.makeLibrary(source:RIFEMetalKernels.source+reference,options:nil)
        func pipeline(_ name:String) throws -> MTLComputePipelineState {
            try device.makeComputePipelineState(function:library.makeFunction(name:name)!)
        }
        let fused=try pipeline("rife_blend_source"),up=try pipeline("ref_up"),warp=try pipeline("ref_warp"),blend=try pipeline("ref_blend")
        func halfBuffer(_ values:[Float16]) -> MTLBuffer {
            values.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
        }
        func empty(_ count:Int) -> MTLBuffer { device.makeBuffer(length:count*2,options:.storageModeShared)! }
        for (sw,sh,mw,mh) in [(191,107,64,32),(1920,1080,1024,576)] {
            let n=sw*sh,mn=mw*mh
            let a=halfBuffer((0..<(n*3)).map {Float16(Float(($0*17)%251)/250)})
            let b=halfBuffer((0..<(n*3)).map {Float16(Float(($0*13+29)%251)/250)})
            let f=halfBuffer((0..<(mn*4)).map {Float16(Float(($0*7)%31-15)/7)})
            let m=halfBuffer((0..<mn).map {Float16(Float(($0*19)%41-20)/3)})
            let ff=empty(n*4),mm=empty(n),wa=empty(n*3),wb=empty(n*3),old=empty(n*3),new=empty(n*3)
            var p=RIFEMetalKernels.SourceBlendParams(sourceWidth:UInt32(sw),sourceHeight:UInt32(sh),modelWidth:UInt32(mw),modelHeight:UInt32(mh))
            func run(_ legacy:Bool) -> Double {
                let command=queue.makeCommandBuffer()!
                func encode(_ state:MTLComputePipelineState,_ buffers:[(MTLBuffer,Int)]) {
                    let encoder=command.makeComputeCommandEncoder()!;encoder.setComputePipelineState(state)
                    for (i,item) in buffers.enumerated(){encoder.setBuffer(item.0,offset:item.1,index:i)}
                    encoder.setBytes(&p,length:16,index:buffers.count)
                    encoder.dispatchThreads(MTLSize(width:sw,height:sh,depth:1),threadsPerThreadgroup:MTLSize(width:16,height:8,depth:1));encoder.endEncoding()
                }
                if legacy {
                    encode(up,[(f,0),(m,0),(ff,0),(mm,0)])
                    encode(warp,[(a,0),(ff,0),(wa,0)])
                    encode(warp,[(b,0),(ff,n*4),(wb,0)])
                    encode(blend,[(wa,0),(wb,0),(mm,0),(old,0)])
                }else{encode(fused,[(a,0),(b,0),(f,0),(m,0),(new,0)])}
                command.commit();command.waitUntilCompleted();precondition(command.status == .completed)
                return (command.gpuEndTime-command.gpuStartTime)*1000
            }
            _=run(true);_=run(false)
            let x=old.contents().assumingMemoryBound(to:Float16.self),y=new.contents().assumingMemoryBound(to:Float16.self)
            var maxError:Float=0,mae:Double=0
            for i in 0..<(n*3) { let error=abs(Float(x[i])-Float(y[i]));maxError=max(maxError,error);mae+=Double(error) }
            print("Fused source",sw,sh,"max",maxError,"MAE",mae/Double(n*3))
            precondition(maxError<0.004 && mae/Double(n*3)<0.00015)
            if sw==1920 {
                var oldTimes:[Double]=[],newTimes:[Double]=[]
                for _ in 0..<16 {oldTimes.append(run(true));newTimes.append(run(false))}
                print(String(format:"1080p GPU synthesis: reference %.3fms, fused %.3fms; %.1fMB scratch removed per engine",oldTimes.reduce(0,+)/16,newTimes.reduce(0,+)/16,Double(n*11*2)/1048576))
            }
        }
        let color=try pipeline("color_test")
        let colors:[SIMD4<Float>]=[SIMD4(0,0,0,1),SIMD4(1,1,1,1),SIMD4(1,0,0,1),SIMD4(0,1,0,1),SIMD4(0,0,1,1),SIMD4(0.3,0.5,0.7,1)]
        let rgb=colors.withUnsafeBytes{device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)!}
        let out=device.makeBuffer(length:colors.count*16,options:.storageModeShared)!,decoded=device.makeBuffer(length:colors.count*16,options:.storageModeShared)!
        for matrix in 0...2 {for full in 0...1 {
            var params=SIMD2<Float>(Float(matrix),Float(full));let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
            encoder.setComputePipelineState(color);encoder.setBuffer(rgb,offset:0,index:0);encoder.setBuffer(out,offset:0,index:1);encoder.setBuffer(decoded,offset:0,index:2);encoder.setBytes(&params,length:8,index:3)
            encoder.dispatchThreads(MTLSize(width:colors.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:1,height:1,depth:1));encoder.endEncoding();command.commit();command.waitUntilCompleted()
            precondition(command.status == .completed)
            let kr:Float=matrix==0 ? 0.299:(matrix==1 ? 0.2126:0.2627),kb:Float=matrix==0 ? 0.114:(matrix==1 ? 0.0722:0.0593)
            let yuv=out.contents().assumingMemoryBound(to:SIMD4<Float>.self),back=decoded.contents().assumingMemoryBound(to:SIMD4<Float>.self)
            for i in colors.indices {
                let expected=colors[i].x*kr+colors[i].y*(1-kr-kb)+colors[i].z*kb
                precondition(abs(yuv[i].x-(full==1 ? expected:(16+219*expected)/255))<0.00001)
                for c in 0..<3 {precondition(abs(back[i][c]-colors[i][c])<0.009,"Static color must survive YUV roundtrip")}
            }
        }}
        print("PASS: fused warp/blend equivalence, clamped borders, 601/709/2020 full/video-range color roundtrips")
    }
}
