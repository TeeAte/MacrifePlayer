//  VideoRenderView.swift
//  Macrife Player —— Phase 5 画质渲染引擎 (Metal + MetalFX 空间超分辨率 + Anime4K 动漫画质增强)
//
//  MTKView 子类：
//    1. 从引擎拉「此刻该显示的帧」，利用 CVMetalTextureCache 零拷贝将 NV12 两个平面映射为 Metal 纹理。
//    2. 原生直通模式（增强全关）：零拷贝单 Pass 全屏四边形 YCbCr→RGB 直接上屏，功耗极低。
//    3. 画质增强模式（Phase 5 接入）：
//       - 离屏合成 intermediateRGBTexture（原清晰度 BGRA）。
//       - 串联 Anime4K 动漫线稿锐化与自适应双边降噪计算着色器。
//       - 串联 Apple 原生 MetalFX 空间超分辨率放大（支持 1080p -> 4K / 720p -> 1440p / 视网膜 Retina）。
//       - DisplayPipeline 配合 letterbox/pillarbox 四边形上屏。
//    4. 顶层无缝叠加 libass 预乘 alpha 字幕层。
//    5. 动态自适应刷新率（支持 120Hz ProMotion）。

import Foundation
import Metal
import MetalKit
import MetalFX
import CoreVideo
import CoreGraphics
import simd

/// 与 VideoShaders.metal 里的 VideoVertexIn 严格同布局（两个 float2，共 16 字节）。
struct VideoVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

final class VideoRenderView: MTKView, MTKViewDelegate {

    /// 向引擎取「此刻该显示的帧」。没有则返回 nil（继续显示上一帧）。
    var frameProvider: (() -> DecodedVideoFrame?)?
    /// 视频原始分辨率，用于等比缩放（letterbox / pillarbox）。
    var videoSizeProvider: (() -> CGSize)?

    /// 向引擎取「此刻该显示的字幕层」。nil = 沿用上一帧，不必重传纹理。
    var subtitleProvider: ((_ width: Int, _ height: Int) -> SubtitleBitmap?)?

    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var displayPipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?

    // MARK: - 画质增强 (Phase 5: MetalFX & Anime4K)

    private var intermediateRGBTexture: MTLTexture?
    private var upscaledTexture: MTLTexture?
    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerInputWidth = 0
    private var scalerInputHeight = 0
    private var scalerOutputWidth = 0
    private var scalerOutputHeight = 0

    private lazy var anime4kProcessor: Anime4KPostProcessor? = {
        guard let device else { return nil }
        return Anime4KPostProcessor(device: device)
    }()

    private static let fullQuadVertices: [VideoVertex] = [
        VideoVertex(position: [-1,  1], texCoord: [0, 0]),
        VideoVertex(position: [ 1,  1], texCoord: [1, 0]),
        VideoVertex(position: [-1, -1], texCoord: [0, 1]),
        VideoVertex(position: [ 1, -1], texCoord: [1, 1]),
    ]

    // MARK: - 字幕层（Phase 3）

    private var subtitlePipelineState: MTLRenderPipelineState?
    private var overlayTexture: MTLTexture?
    private var overlayWidth = 0
    private var overlayHeight = 0
    private var overlayNeedsDraw = false
    private var overlayHasContent = false

    private(set) var lastSubtitleStats = "（尚未绘制过字幕层）"

    // 显示中的帧引用持有
    private var lumaRef: CVMetalTexture?
    /// 上传计数（纹理缓存周期 flush 用）
    private var uploadCount = 0
    private var chromaRef: CVMetalTexture?
    private var heldPixelBuffer: CVPixelBuffer?
    private var lumaTexture: MTLTexture?
    private var chromaTexture: MTLTexture?

    // 打包 4:2:2（YUY2 / 'yuvs'）路径：整块缓冲映射成**一张** rg8Unorm 纹理，
    // 与双平面 NV12 的 luma/chroma 两张纹理互斥（见 upload）。
    private var packedRef: CVMetalTexture?
    private var packedTexture: MTLTexture?
    private var isPacked422 = false

    private var colorParams = SIMD4<Float>(0, 0, 0, 0)
    private var hasFrame = false

    private static let logPrefix = "[VideoRenderView] "

    // MARK: - 初始化

    init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        self.device = self.device ?? MTLCreateSystemDefaultDevice()
        configure()
    }

    private func configure() {
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false // 支持 MetalFX 和后处理离屏读取
        isPaused = false
        enableSetNeedsDisplay = false
        preferredFramesPerSecond = 60
        autoResizeDrawable = true
        delegate = self
        layer?.isOpaque = true

        guard let device else {
            Self.log("没有可用的 Metal 设备，画面无法渲染")
            return
        }
        commandQueue = device.makeCommandQueue()

        var cache: CVMetalTextureCache?
        let rc = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        if rc == kCVReturnSuccess { textureCache = cache }
        else { Self.log("CVMetalTextureCache 创建失败: \(rc)") }

        buildPipeline(device: device)
    }

    /// 根据当前补帧档位与源帧率动态调整 MTKView 刷新率（支持 120Hz ProMotion）
    func updatePreferredFPS(for mode: RIFERateMode, sourceFPS: Double) {
        let target = StatsPanelView.targetFrameRate(source: sourceFPS, mode: mode)
        let fps = target > 0 ? Int(ceil(target)) : 60
        self.preferredFramesPerSecond = max(60, min(120, fps))
    }

    /// 打包 4:2:2 的片段着色器（YUY2）。缺失时打包帧会走不了，
    /// 所以单独记一个状态，方便日志里看出是「编译失败」还是「没这个格式」。
    private var packed422PipelineState: MTLRenderPipelineState?

    private func buildPipeline(device: MTLDevice) {
        let library: MTLLibrary
        do {
            library = try VideoShaderLibrary.make(device: device)
        } catch {
            Self.log("着色器编译失败: \(error)")
            return
        }

        guard let vertexFunction = library.makeFunction(name: VideoShaderLibrary.vertexFunctionName),
              let fragmentFunction = library.makeFunction(name: VideoShaderLibrary.fragmentFunctionName) else {
            Self.log("着色器里没有 \(VideoShaderLibrary.vertexFunctionName) / \(VideoShaderLibrary.fragmentFunctionName)")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "VideoPipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Self.log("渲染管线创建失败: \(error)")
        }

        // Display 管线（呈现处理后的通用 RGB 纹理）
        if let dispFunc = library.makeFunction(name: VideoShaderLibrary.displayFragmentFunctionName) {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "DisplayPipeline"
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = dispFunc
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            displayPipelineState = try? device.makeRenderPipelineState(descriptor: desc)
        }

        // 打包 4:2:2（YUY2）管线。与上面的 video 管线同顶点、同 params 布局，
        // 只换成「读一张 rg8 打包纹理」的片段函数 —— 色彩数学两者共用同一段 MSL。
        if let packedFunc = library.makeFunction(name: VideoShaderLibrary.packed422FragmentFunctionName) {
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "Packed422Pipeline"
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = packedFunc
            desc.colorAttachments[0].pixelFormat = colorPixelFormat
            do {
                packed422PipelineState = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                Self.log("打包 4:2:2 管线创建失败: \(error)")
            }
        } else {
            Self.log("着色器里没有 \(VideoShaderLibrary.packed422FragmentFunctionName)，YUY2 采集将无法上屏")
        }

        // 字幕层管线
        buildSubtitlePipeline(library: library, device: device)
    }

    private func buildSubtitlePipeline(library: MTLLibrary, device: MTLDevice) {
        guard let vertexFunction = library.makeFunction(name: VideoShaderLibrary.vertexFunctionName),
              let fragmentFunction = library.makeFunction(name: VideoShaderLibrary.subtitleFragmentFunctionName) else {
            Self.log("着色器里没有 \(VideoShaderLibrary.subtitleFragmentFunctionName)")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "SubtitlePipeline"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction

        if let ca = descriptor.colorAttachments[0] {
            ca.pixelFormat = colorPixelFormat
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.sourceAlphaBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        do {
            subtitlePipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Self.log("字幕渲染管线创建失败: \(error)")
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((logPrefix + message + "\n").utf8))
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // 尺寸变动时按需在 draw 中重新分配 Scaler
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let queue = commandQueue else { return }

        // 先看有没有新帧要上屏（引擎负责按音视频时钟决定「该不该显示」）
        // 注意：不使用 pointer !== heldPixelBuffer 校验，因为 CVPixelBufferPool 会在同一内存地址快速复用指针，
        // 校验指针会导致回收复用的新帧被误判为旧帧而丢弃，产生高频跳帧与周期性卡顿。
        if let frame = frameProvider?() {
            upload(frame)
        }

        guard let commandBuffer = queue.makeCommandBuffer() else { return }

        var vertices = makeVertices()

        let settings = PlaybackSettings.shared
        let isEnhanceActive = (settings.metalFX != .off || settings.anime4k != .off)

        // 打包 4:2:2 与双平面 NV12 走**同一套**绘制结构，只换「源纹理与片段函数」：
        //   双平面 = luma 纹理 + chroma 纹理  → video_fragment
        //   打包   = 单张 rg8 纹理            → video_fragment_yuy2
        // 后面凡是需要「把源帧转成 RGB」的地方，都用这两个变量选路。
        let sourcePipeline = isPacked422 ? packed422PipelineState : pipelineState
        let sourceLuma = isPacked422 ? packedTexture : lumaTexture
        let sourceChroma = chromaTexture
        let hasSource = isPacked422 ? (packedTexture != nil) : (lumaTexture != nil && chromaTexture != nil)

        if hasFrame, let pipeline = sourcePipeline, let luma = sourceLuma, hasSource {

            if isEnhanceActive, let device = self.device, let displayPipeline = displayPipelineState {
                // ── 走 Phase 5 画质增强管线 (Anime4K / MetalFX) ──
                let inW = luma.width
                let inH = luma.height
                let intermediateTex = getOrCreateIntermediateRGBTexture(device: device, width: inW, height: inH)

                // 1. 将 NV12 YCbCr 转换并写入中间全分辨率 RGB 纹理
                let interPass = MTLRenderPassDescriptor()
                interPass.colorAttachments[0].texture = intermediateTex
                interPass.colorAttachments[0].loadAction = .clear
                interPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                interPass.colorAttachments[0].storeAction = .store

                if let interEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: interPass) {
                    interEncoder.label = "NV12_to_RGB"
                    interEncoder.setRenderPipelineState(pipeline)
                    var fullQuad = Self.fullQuadVertices
                    interEncoder.setVertexBytes(&fullQuad, length: MemoryLayout<VideoVertex>.stride * fullQuad.count, index: 0)
                    interEncoder.setFragmentTexture(luma, index: 0)
                    // 打包 4:2:2 没有第二张纹理；留空即零，Metal 允许未使用槽位为 nil
                    interEncoder.setFragmentTexture(sourceChroma, index: 1)
                    interEncoder.setFragmentBytes(&colorParams, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                    interEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    interEncoder.endEncoding()
                }

                // 2. Anime4K 动漫线稿锐化与双边降噪 (若开启)
                var currentTexture = intermediateTex
                if settings.anime4k == .on, let processor = anime4kProcessor {
                    processor.setPreset(Anime4KPreset(
                        id: settings.anime4kPresetID,
                        lineSharpness: settings.anime4kSharpness,
                        denoiseStrength: settings.anime4kDenoise,
                        isEnabled: true
                    ))
                    currentTexture = processor.process(commandBuffer: commandBuffer, inputTexture: currentTexture)
                }

                // 3. Apple MetalFX 空间超分辨率放大 (若开启)
                if settings.metalFX == .spatial {
                    let outW = inW * 2
                    let outH = inH * 2
                    if let scaler = getOrCreateSpatialScaler(device: device, inW: inW, inH: inH, outW: outW, outH: outH) {
                        let upscaled = getOrCreateUpscaledTexture(device: device, width: outW, height: outH)
                        scaler.colorTexture = currentTexture
                        scaler.outputTexture = upscaled
                        scaler.encode(commandBuffer: commandBuffer)
                        currentTexture = upscaled
                    }
                }

                // 4. 将最终处理后的 RGB 纹理上屏渲染 (带 letterbox)
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                descriptor.colorAttachments[0].storeAction = .store

                if let screenEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                    screenEncoder.label = "Final_Display"
                    screenEncoder.setRenderPipelineState(displayPipeline)
                    screenEncoder.setVertexBytes(&vertices, length: MemoryLayout<VideoVertex>.stride * vertices.count, index: 0)
                    screenEncoder.setFragmentTexture(currentTexture, index: 0)
                    screenEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

                    drawSubtitle(encoder: screenEncoder, vertices: &vertices)
                    screenEncoder.endEncoding()
                }
            } else {
                // ── 原生直通管线 (全关时极致低开销) ──
                descriptor.colorAttachments[0].loadAction = .clear
                descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                descriptor.colorAttachments[0].storeAction = .store

                if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setVertexBytes(&vertices, length: MemoryLayout<VideoVertex>.stride * vertices.count, index: 0)
                    encoder.setFragmentTexture(luma, index: 0)
                    encoder.setFragmentTexture(sourceChroma, index: 1)
                    encoder.setFragmentBytes(&colorParams, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

                    drawSubtitle(encoder: encoder, vertices: &vertices)
                    encoder.endEncoding()
                }
            }
        } else {
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            descriptor.colorAttachments[0].storeAction = .store
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) {
                drawSubtitle(encoder: encoder, vertices: &vertices)
                encoder.endEncoding()
            }
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - MetalFX & Intermediate Textures 缓存管理

    private func getOrCreateIntermediateRGBTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        if let tex = intermediateRGBTexture, tex.width == width, tex.height == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)!
        intermediateRGBTexture = tex
        return tex
    }

    private func getOrCreateUpscaledTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        if let tex = upscaledTexture, tex.width == width, tex.height == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .private
        let tex = device.makeTexture(descriptor: desc)!
        upscaledTexture = tex
        return tex
    }

    private func getOrCreateSpatialScaler(device: MTLDevice, inW: Int, inH: Int, outW: Int, outH: Int) -> MTLFXSpatialScaler? {
        if let s = spatialScaler, scalerInputWidth == inW, scalerInputHeight == inH, scalerOutputWidth == outW, scalerOutputHeight == outH {
            return s
        }

        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else { return nil }

        let desc = MTLFXSpatialScalerDescriptor()
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.inputWidth = inW
        desc.inputHeight = inH
        desc.outputWidth = outW
        desc.outputHeight = outH
        desc.colorProcessingMode = .perceptual

        guard let scaler = desc.makeSpatialScaler(device: device) else { return nil }
        spatialScaler = scaler
        scalerInputWidth = inW
        scalerInputHeight = inH
        scalerOutputWidth = outW
        scalerOutputHeight = outH
        return scaler
    }

    // MARK: - 字幕层

    private func drawSubtitle(encoder: MTLRenderCommandEncoder,
                              vertices: inout [VideoVertex]) {
        let videoSize = videoSizeProvider?() ?? .zero
        let width = Int(videoSize.width.rounded())
        let height = Int(videoSize.height.rounded())
        guard width > 0, height > 0 else { return }

        if let bitmap = subtitleProvider?(width, height) {
            uploadSubtitle(bitmap)
            overlayHasContent = bitmap.imageCount > 0
            overlayNeedsDraw = true
        }

        guard overlayNeedsDraw,
              let overlay = overlayTexture,
              let pipeline = subtitlePipelineState else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices,
                               length: MemoryLayout<VideoVertex>.stride * vertices.count,
                               index: 0)
        encoder.setFragmentTexture(overlay, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        overlayNeedsDraw = overlayHasContent
    }

    private func uploadSubtitle(_ bitmap: SubtitleBitmap) {
        guard let device else { return }

        if overlayTexture == nil
            || overlayWidth != bitmap.width || overlayHeight != bitmap.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: bitmap.width, height: bitmap.height,
                mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .managed
            overlayTexture = device.makeTexture(descriptor: descriptor)
            overlayWidth = bitmap.width
            overlayHeight = bitmap.height
        }

        guard let texture = overlayTexture, !bitmap.pixels.isEmpty else { return }

        // ┌ 只上传**脏区**，不再整幅 replace
        // │
        // │ 整幅上传的代价：4K 3584×2160×4 = 29.5MB/次，`.managed` 存储还要
        // │ 在 commit 时整块搬进显存。而字幕实际只动画面底部那几行 ——
        // │ 按脏区传，绝大多数情况下是几十 KB 量级。
        // │
        // │ 行的起点用 `bitmap.width * 4` 做步长：脏区是整幅缓冲里的一块子矩形，
        // │ 行与行之间仍然隔着整幅的宽度，所以不能按脏区宽度算 bytesPerRow。
        // └
        let dirty = bitmap.dirty.clamped(width: bitmap.width, height: bitmap.height)
        if !dirty.isEmpty {
            let region = MTLRegionMake2D(dirty.x, dirty.y, dirty.width, dirty.height)
            let offset = (dirty.y * bitmap.width + dirty.x) * 4
            bitmap.pixels.withUnsafeBytes { ptr in
                guard let base = ptr.baseAddress else { return }
                texture.replace(region: region,
                                mipmapLevel: 0,
                                withBytes: base.advanced(by: offset),
                                bytesPerRow: bitmap.width * 4)
            }
        }
        lastSubtitleStats = String(format: "%dx%d · 叠图 %d 张 · 脏区 %@",
                                   bitmap.width, bitmap.height, bitmap.imageCount,
                                   dirty.debugText)
    }

    // MARK: - 视频上传

    private func upload(_ frame: DecodedVideoFrame) {
        let pixelBuffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0,
              let cache = textureCache else { return }

        // CVMetalTextureCache 会保留已创建的纹理条目（纹理→IOSurface→像素缓冲）。
        // RIFE 补帧后上屏帧率 48-120fps，且插帧来自自建缓冲池 —— 缓存若长期
        // 不 flush，会扣住池缓冲不放 → 池误判「全部在用」→ 每帧新建缓冲 →
        // 新缓冲又成为新缓存条目，正反馈泄漏 ~26MB/帧（实测 20 分钟 25GB）。
        // 每 24 次上传（≈0.5s@48fps）强制回收一次无引用条目 —— 间隔太长时，
        // 缓存扣住的纹理会连带钉住像素缓冲，池回收随之失效（池创建数会持续涨）。
        uploadCount += 1
        if uploadCount % 24 == 0 { CVMetalTextureCacheFlush(cache, 0) }

        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is10Bit = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        // ── 打包 4:2:2（YUY2 / 'yuvs'）──
        //
        // 采集卡原生 4:2:2 的色度**不横向减半**，比 420v（4:2:0）多一倍彩色细节。
        // 整块缓冲按 rg8Unorm 映射：每纹素 2 字节，纹素 i = (Y_i, U) 或 (Y_i, V)。
        // 实测：CVMetalTextureCache 对该格式建 rg8Unorm 纹理 rc=0 成功。
        //
        // 只认 'yuvs'（YUY2）。UYVY（'2vuy'）字节序相反，解包下标不同，
        // 需要另一套映射 —— 没有实测样本，不放进来（见 isRenderablePixelFormat 的注释）。
        if fmt == kCVPixelFormatType_422YpCbCr8_yuvs {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let texW = bytesPerRow / 2
            guard texW > 0, let cache = textureCache else { return }
            var packedRefOut: CVMetalTexture?
            let rc = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, cache, pixelBuffer, nil,
                .rg8Unorm, texW, height, 0, &packedRefOut)
            guard rc == kCVReturnSuccess, let ref = packedRefOut,
                  let tex = CVMetalTextureGetTexture(ref) else {
                Self.log("打包 4:2:2 纹理创建失败: rc=\(rc)")
                return
            }
            lumaRef = nil; chromaRef = nil
            lumaTexture = nil; chromaTexture = nil
            packedRef = ref
            packedTexture = tex
            isPacked422 = true
            heldPixelBuffer = pixelBuffer
            // params.z = 源像素宽度（行有对齐填充时 ≠ 纹理宽度，着色器靠它算 x）
            colorParams = SIMD4<Float>(Float(frame.colorSpaceCode),
                                       frame.isFullRange ? 1.0 : 0.0,
                                       Float(width), 0)
            hasFrame = true
            return
        }

        let lumaFormat: MTLPixelFormat = is10Bit ? .r16Unorm : .r8Unorm
        let chromaFormat: MTLPixelFormat = is10Bit ? .rg16Unorm : .rg8Unorm

        var luma: CVMetalTexture?
        var chroma: CVMetalTexture?
        let lumaRC = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            lumaFormat, width, height, 0, &luma)
        let chromaRC = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            chromaFormat, width / 2, height / 2, 1, &chroma)

        guard lumaRC == kCVReturnSuccess, chromaRC == kCVReturnSuccess,
              let lumaRefOut = luma, let chromaRefOut = chroma,
              let lumaTextureOut = CVMetalTextureGetTexture(lumaRefOut),
              let chromaTextureOut = CVMetalTextureGetTexture(chromaRefOut) else {
            return
        }

        lumaRef = lumaRefOut
        chromaRef = chromaRefOut
        lumaTexture = lumaTextureOut
        chromaTexture = chromaTextureOut
        // 双平面路径：把打包 4:2:2 的状态清掉，避免上一帧的标记漏到这一帧
        packedRef = nil
        packedTexture = nil
        isPacked422 = false
        heldPixelBuffer = pixelBuffer
        colorParams = SIMD4<Float>(Float(frame.colorSpaceCode), frame.isFullRange ? 1.0 : 0.0, 0, Float(frame.transferFunction.rawValue))
        hasFrame = true
    }

    /// 清掉当前画面（停止播放 / 换文件时用）。
    func clearFrame() {
        lumaRef = nil
        chromaRef = nil
        lumaTexture = nil
        chromaTexture = nil
        packedRef = nil
        packedTexture = nil
        isPacked422 = false
        heldPixelBuffer = nil
        hasFrame = false
        overlayNeedsDraw = false
        overlayHasContent = false
        intermediateRGBTexture = nil
        upscaledTexture = nil
        spatialScaler = nil
        scalerInputWidth = 0
        scalerInputHeight = 0
        scalerOutputWidth = 0
        scalerOutputHeight = 0
        if let cache = textureCache { CVMetalTextureCacheFlush(cache, 0) }
    }

    // MARK: - 几何

    private func makeVertices() -> [VideoVertex] {
        let viewSize = drawableSize
        let videoSize = videoSizeProvider?() ?? .zero

        var scaleX: Float = 1
        var scaleY: Float = 1
        if videoSize.width > 0, videoSize.height > 0,
           viewSize.width > 0, viewSize.height > 0 {
            let videoAspect = Float(videoSize.width / videoSize.height)
            let viewAspect = Float(viewSize.width / viewSize.height)
            if viewAspect > videoAspect {
                scaleX = videoAspect / viewAspect
            } else {
                scaleY = viewAspect / videoAspect
            }
        }

        return [
            VideoVertex(position: [-scaleX,  scaleY], texCoord: [0, 0]),
            VideoVertex(position: [ scaleX,  scaleY], texCoord: [1, 0]),
            VideoVertex(position: [-scaleX, -scaleY], texCoord: [0, 1]),
            VideoVertex(position: [ scaleX, -scaleY], texCoord: [1, 1]),
        ]
    }
}
