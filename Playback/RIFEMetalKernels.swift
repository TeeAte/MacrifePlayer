import Foundation

/// Shared with GPU regression tests. Quantize the same intermediates as the
/// former five-pass blend so fusion changes memory traffic, not model behavior.
enum RIFEMetalKernels {
    struct SourceBlendParams {
        var sourceWidth, sourceHeight, modelWidth, modelHeight: UInt32
    }

    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct RIFESourceBlendParams { uint sourceWidth, sourceHeight, modelWidth, modelHeight; };
    inline float rife_sample(const device half *p, uint channel, uint w, uint h, float x, float y) {
        x=clamp(x,0.0f,float(w-1)); y=clamp(y,0.0f,float(h-1));
        uint x0=uint(floor(x)), y0=uint(floor(y)), x1=min(x0+1,w-1), y1=min(y0+1,h-1);
        float dx=x-float(x0),dy=y-float(y0);uint base=channel*w*h;
        return mix(mix(float(p[base+y0*w+x0]),float(p[base+y0*w+x1]),dx),
                   mix(float(p[base+y1*w+x0]),float(p[base+y1*w+x1]),dx),dy);
    }
    kernel void rife_blend_source(const device half *a [[buffer(0)]], const device half *b [[buffer(1)]],
        const device half *flow [[buffer(2)]], const device half *mask [[buffer(3)]], device half *out [[buffer(4)]],
        constant RIFESourceBlendParams &p [[buffer(5)]], uint2 xy [[thread_position_in_grid]]) {
        if(xy.x>=p.sourceWidth || xy.y>=p.sourceHeight)return;
        float sx=float(p.sourceWidth)/float(p.modelWidth), sy=float(p.sourceHeight)/float(p.modelHeight);
        float x=(float(xy.x)+0.5f)*float(p.modelWidth)/float(p.sourceWidth)-0.5f;
        float y=(float(xy.y)+0.5f)*float(p.modelHeight)/float(p.sourceHeight)-0.5f;
        float4 f;
        for(uint c=0;c<4;++c)f[c]=float(half(rife_sample(flow,c,p.modelWidth,p.modelHeight,x,y)*((c&1)?sy:sx)));
        float m=float(half(rife_sample(mask,0,p.modelWidth,p.modelHeight,x,y)));
        float weight=1.0f/(1.0f+exp(-m));uint plane=p.sourceWidth*p.sourceHeight,idx=xy.y*p.sourceWidth+xy.x;
        for(uint c=0;c<3;++c) {
            float v0=float(half(rife_sample(a,c,p.sourceWidth,p.sourceHeight,float(xy.x)+f.x,float(xy.y)+f.y)));
            float v1=float(half(rife_sample(b,c,p.sourceWidth,p.sourceHeight,float(xy.x)+f.z,float(xy.y)+f.w)));
            out[c*plane+idx]=half(v0*weight+v1*(1.0f-weight));
        }
    }
    inline float2 rife_kr_kb(float matrix) {
        return matrix>1.5f ? float2(0.2627f,0.0593f) : (matrix>0.5f ? float2(0.2126f,0.0722f) : float2(0.299f,0.114f));
    }
    inline float3 rife_yuv_to_rgb(float y,float cb,float cr,bool full,float matrix) {
        float2 k=rife_kr_kb(matrix);float kg=1.0f-k.x-k.y;
        cb-=128.0f/255.0f;cr-=128.0f/255.0f;
        if(!full){y=(255.0f*y-16.0f)/219.0f;cb*=255.0f/224.0f;cr*=255.0f/224.0f;}
        float r=y+2.0f*(1.0f-k.x)*cr,b=y+2.0f*(1.0f-k.y)*cb;
        return clamp(float3(r,(y-k.x*r-k.y*b)/kg,b),0.0f,1.0f);
    }
    inline float3 rife_rgb_to_yuv(float3 rgb,bool full,float matrix) {
        float2 k=rife_kr_kb(matrix);float y=dot(rgb,float3(k.x,1.0f-k.x-k.y,k.y));
        float2 c=float2((rgb.b-y)/(2.0f*(1.0f-k.y)),(rgb.r-y)/(2.0f*(1.0f-k.x)));
        return full ? float3(y,c+128.0f/255.0f) : float3((16.0f+219.0f*y)/255.0f,(128.0f+224.0f*c)/255.0f);
    }
    """
}
