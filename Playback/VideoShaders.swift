//  VideoShaders.swift
//  MetalPlayer 重建工程 —— Phase 1 画面渲染着色器（MSL 源码 + 运行时编译）
//
//  输入是解码器产出的 NV12（两个平面：Y / CbCr），输出 BGRA。
//  色度上采样与 YCbCr→RGB 都在 GPU 里做，CPU 侧只负责把帧交给 Metal。
//
//  ────────────────────────────────────────────────────────────────
//  为什么是「运行时编译」而不是 .metal 文件参与构建：
//
//  本机（Xcode 26 系，macOS 27 SDK）没有安装 Metal 工具链，
//  把 VideoShaders.metal 放进 Sources 阶段会直接失败：
//
//      error: cannot execute tool 'metal' due to missing Metal Toolchain;
//      use: xcodebuild -downloadComponent MetalToolchain
//
//  而实测 MTLCreateSystemDefaultDevice().makeLibrary(source:) **是可用的**
//  （系统自带运行时 Metal 编译器，不依赖那个可下载组件），
//  所以这里把 MSL 源码内联成 Swift 字符串，运行时编译一次、进程内复用。
//
//  两个附带好处：
//    · 着色器源码与渲染代码在同一个文件里，改一处不会漏改另一处；
//    · 不依赖 build 环境是否装了 Metal 工具链，换台机器也能跑。
//
//  代价：启动时多几十毫秒编译。已实测可接受。
//  若以后装上了工具链（xcodebuild -downloadComponent MetalToolchain），
//  把下面 videoShaderSource 落成 .metal 文件即可切回构建期编译 ——
//  两种方式产出的函数名完全一致（video_vertex / video_fragment）。
//  ────────────────────────────────────────────────────────────────
//
//  关于「视频范围」而不是「全范围」：
//    解码出来的是 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange，
//    Y ∈ [16,235]、CbCr ∈ [16,240]。必须先用 (255/219) / (255/224) 展开，
//    否则画面会发灰、对比度偏低 —— 这是自己写 YUV 着色器最常踩的坑。
//
//  关于 BT.709 / BT.601：
//    高清（≥720p）与绝大多数现代片源是 BT.709；DVD / 标清是 BT.601。
//    用错了就是偏色，肤色尤其明显。用哪个由解码器给出的色彩空间元数据决定
//    （见 VideoDecoder.resolveBT709），通过 params.x 传进来。

import Foundation
import Metal

enum VideoShaderLibrary {

    static let vertexFunctionName = "video_vertex"
    static let fragmentFunctionName = "video_fragment"
    static let subtitleFragmentFunctionName = "subtitle_fragment"
    static let displayFragmentFunctionName = "display_fragment"
    /// 打包 4:2:2（YUY2 / yuvs）专用片段着色器。
    static let packed422FragmentFunctionName = "video_fragment_yuy2"

    /// Metal Shading Language 源码。
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VideoVertexIn {
        float2 position;
        float2 texCoord;
    };

    struct VideoVertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VideoVertexOut video_vertex(uint vertexID [[vertex_id]],
                                       const device VideoVertexIn *vertices [[buffer(0)]])
    {
        VideoVertexOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.texCoord = vertices[vertexID].texCoord;
        return out;
    }

    // YCbCr → RGB。两个片段着色器共用这一处，保证「双平面 NV12」与
    // 「打包 4:2:2」两条路径的色彩处理逐字一致 —— 复制两份迟早会漂移。
    static inline float3 ycbcr_to_rgb(float y, float cb, float cr, constant float4 &params)
    {
        bool isFullRange = (params.y > 0.5);
        if (isFullRange) {
            cb = cb - 0.5;
            cr = cr - 0.5;
        } else {
            // 视频范围 -> 全范围
            y  = max(y - 16.0 / 255.0, 0.0) * (255.0 / 219.0);
            cb = (cb - 128.0 / 255.0) * (255.0 / 224.0);
            cr = (cr - 128.0 / 255.0) * (255.0 / 224.0);
        }

        float3 rgb;
        if (params.x > 1.5) {
            // BT.2020 (HDR)
            rgb.r = y + 1.4746 * cr;
            rgb.g = y - 0.16455 * cb - 0.5714 * cr;
            rgb.b = y + 1.8814 * cb;
        } else if (params.x > 0.5) {
            // BT.709
            rgb.r = y + 1.5748 * cr;
            rgb.g = y - 0.1873 * cb - 0.4681 * cr;
            rgb.b = y + 1.8556 * cb;
        } else {
            // BT.601
            rgb.r = y + 1.4020 * cr;
            rgb.g = y - 0.3441 * cb - 0.7141 * cr;
            rgb.b = y + 1.7720 * cb;
        }
        return saturate(rgb);
    }

    fragment float4 video_fragment(VideoVertexOut in [[stage_in]],
                                   texture2d<float> lumaTexture [[texture(0)]],
                                   texture2d<float> chromaTexture [[texture(1)]],
                                   constant float4 &params [[buffer(0)]])
    {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

        float y = lumaTexture.sample(textureSampler, in.texCoord).r;
        // NV12 的交错平面是 Cb 在前、Cr 在后 -> .r = Cb，.g = Cr
        float2 cbcr = chromaTexture.sample(textureSampler, in.texCoord).rg;

        return float4(ycbcr_to_rgb(y, cbcr.x, cbcr.y, params), 1.0);
    }

    // ── 打包 4:2:2（YUY2 / 'yuvs'）──────────────────────────────────────
    //
    // 为什么单独一条路径：采集卡的 4:2:2 输出色度**不横向减半**，
    // 而 420v（NV12）是 4:2:0，色度横竖都减半。同一路 HDMI 信号下，
    // 4:2:2 的彩色细节（游戏 HUD、红色小字、细线）明显更实 ——
    // OBS 直接吃原生格式，我们不该平白做一次 4:2:2 → 4:2:0 的降采样。
    //
    // 内存布局：每 4 字节 = [Y0][U][Y1][V]，即两个像素共享一组 U/V。
    // 按 rg8Unorm 覆盖后每个纹素占 2 字节：
    //     纹素下标 i 为偶数 -> (Y_i, U)     i 为奇数 -> (Y_i, V)
    // 于是 Y 就在纹素 xi 的 .r；U 在纹素 2k 的 .g，V 在纹素 2k+1 的 .g（k = xi/2）。
    //
    // params.z = 源像素宽度（行可能有对齐填充，不能直接用纹理宽度代替）。
    fragment float4 video_fragment_yuy2(VideoVertexOut in [[stage_in]],
                                        texture2d<float> packedTexture [[texture(0)]],
                                        constant float4 &params [[buffer(0)]])
    {
        // 逐像素取值，不做线性插值：Y 与 U/V 分别落在不同纹素上，
        // 线性插值会把相邻像素的色度混进来（边缘出现彩色镶边）。
        constexpr sampler pointSampler(address::clamp_to_edge, filter::nearest);

        float texW = float(packedTexture.get_width());
        float srcW = max(params.z, 1.0);
        float x  = clamp(in.texCoord.x * srcW, 0.0, srcW - 1.0);
        float xi = floor(x);
        float k  = floor(xi * 0.5);

        float row = in.texCoord.y;
        float y  = packedTexture.sample(pointSampler, float2((xi + 0.5) / texW, row)).r;
        float cb = packedTexture.sample(pointSampler, float2((k * 2.0 + 0.5) / texW, row)).g;
        float cr = packedTexture.sample(pointSampler, float2((k * 2.0 + 1.5) / texW, row)).g;

        return float4(ycbcr_to_rgb(y, cb, cr, params), 1.0);
    }

    // 通用 RGB 纹理展示片段着色器（用于 MetalFX / Anime4K 处理后的画面呈现）
    fragment float4 display_fragment(VideoVertexOut in [[stage_in]],
                                     texture2d<float> colorTexture [[texture(0)]])
    {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
        return colorTexture.sample(textureSampler, in.texCoord);
    }

    // 字幕层。纹理是 CPU 侧（libass 位图合成）产出的 **预乘 alpha** BGRA8，
    // 所以这里原样返回即可 —— 叠加方式交给固定的混合式
    //（sourceRGB = .one / destinationRGB = .oneMinusSourceAlpha）。
    //
    // 用与视频**完全相同**的顶点：字幕纹理的尺寸就是视频原始尺寸，
    // 于是 letterbox 的缩放与位移对两层完全一致 —— 字幕天然贴着画面，
    // 不需要为它单独算一套坐标（也就没有「字幕和画面错位」这类 bug 的容身之处）。
    fragment float4 subtitle_fragment(VideoVertexOut in [[stage_in]],
                                      texture2d<float> overlayTexture [[texture(0)]])
    {
        constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);
        return overlayTexture.sample(textureSampler, in.texCoord);
    }
    """

    /// 编译着色器。优先用构建期产物 default.metallib（若将来装回工具链），
    /// 没有再退回运行时编译。
    static func make(device: MTLDevice) throws -> MTLLibrary {
        if let library = device.makeDefaultLibrary(),
           library.makeFunction(name: vertexFunctionName) != nil {
            return library
        }
        return try device.makeLibrary(source: source, options: nil)
    }
}
