//  VideoDecoder.swift
//  MetalPlayer 重建工程 —— Phase 1 视频解码
//
//  链路：AVPacket → avcodec → AVFrame → swscale → NV12 CVPixelBuffer → Metal 纹理
//
//  为什么落到 NV12 而不是 BGRA：
//    NV12 每像素 1.5 字节，BGRA 是 4 字节。1080p 一帧差 5.7 MB 的上传量。
//    色度→RGB 的矩阵放在片元着色器里做（BT.709 / BT.601 可切），
//    这样 swscale 只做「像素格式 + 缩放」，不做色彩空间转换，CPU 开销最小。
//
//  注意：本文件只被视频解码线程调用，内部无锁。

import Foundation
import CoreVideo

/// 视频色彩传输特性 (Transfer Function)
enum VideoTransferFunction: Int32 {
    case sdr = 0     // BT.709 / sRGB / gamma
    case pq = 1      // SMPTE ST 2084 (HDR10)
    case hlg = 2     // ARIB STD-B67 (HLG)
}

/// 一张可以直接上屏的画面。
///
/// 刻意放在 `#if USE_FFMPEG` **之外**：渲染层与 UI 只吃这个值类型，
/// 关掉开关时它们仍然能独立编译。
struct DecodedVideoFrame {
    /// NV12 / P010 像素缓冲，带 IOSurface，可直接建 Metal 纹理。
    let pixelBuffer: CVPixelBuffer
    /// 显示时间（秒）。
    let pts: Double
    /// 色度矩阵：true = BT.709，false = BT.601。
    /// 由解码器给出的色彩空间元数据决定，缺失时按分辨率猜（≥720p 判 709）。
    let isBT709: Bool
    /// 色彩空间代号：0 = BT.601, 1 = BT.709, 2 = BT.2020
    var colorSpaceCode: Int32 = 1
    /// 是否为全范围（Full Range 0-255）
    var isFullRange: Bool = false
    /// 是否为 RIFE 补帧生成的插值帧
    var isInterpolated: Bool = false
    /// 传输特性：0 = SDR, 1 = SMPTE ST 2084 (PQ), 2 = ARIB STD-B67 (HLG)
    var transferFunction: VideoTransferFunction = .sdr
    /// 目标最大亮度 (nits)，默认 1000.0 (HDR10 标准基准)
    var peakNits: Float = 1000.0

    /// 是否为 10-bit 像素格式 (P010)
    var is10Bit: Bool {
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        return fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
               fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    }

    /// 是否为 HDR 视频帧（PQ 或 HLG，或 10-bit BT.2020）
    var isHDR: Bool {
        return transferFunction == .pq || transferFunction == .hlg || (colorSpaceCode == 2 && is10Bit)
    }

    init(pixelBuffer: CVPixelBuffer,
         pts: Double,
         isBT709: Bool = true,
         colorSpaceCode: Int32 = 1,
         isFullRange: Bool = false,
         isInterpolated: Bool = false,
         transferFunction: VideoTransferFunction = .sdr,
         peakNits: Float = 1000.0) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
        self.isBT709 = isBT709
        self.colorSpaceCode = colorSpaceCode
        self.isFullRange = isFullRange
        self.isInterpolated = isInterpolated
        self.transferFunction = transferFunction
        self.peakNits = peakNits
    }
}

#if USE_FFMPEG

import CFFmpeg

final class VideoDecoder {

    let width: Int
    let height: Int
    let timeBase: AVRational
    /// 编码层的帧率（用于估算「落后多少帧」）。
    let frameRate: Double

    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var scratch: UnsafeMutablePointer<AVPacket>?
    private var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?

    // swscale（不透明指针，Swift 只能拿 OpaquePointer）
    private var sws: OpaquePointer?
    private var swsSourceFormat: AVPixelFormat = AV_PIX_FMT_NONE
    private var swsSourceSize: (Int, Int) = (0, 0)

    var codecName: String = "?"
    private(set) var isHardwareAccelerated: Bool = false
    private var hasObservedDecodedFrame: Bool = false

    let isMTSOrInterlacedHint: Bool
    private var didLogDeinterlace: Bool = false

    /// VideoToolbox 硬解像素格式协商回调
    private static let vtGetFormat: @convention(c) (UnsafeMutablePointer<AVCodecContext>?, UnsafePointer<AVPixelFormat>?) -> AVPixelFormat = { _, pixFmts in
        guard let pixFmts = pixFmts else { return AV_PIX_FMT_NONE }
        var p = pixFmts
        while p.pointee != AV_PIX_FMT_NONE {
            if p.pointee == AV_PIX_FMT_VIDEOTOOLBOX {
                return AV_PIX_FMT_VIDEOTOOLBOX
            }
            p = p.advanced(by: 1)
        }
        return pixFmts.pointee
    }

    init(parameters: UnsafeMutablePointer<AVCodecParameters>,
         timeBase: AVRational,
         useHardware: Bool = true,
         frameRate: Double = 25,
         isMTSOrInterlacedHint: Bool = false) throws {
        FFmpegSupport.ensureReady()
        self.timeBase = timeBase
        self.width = Int(parameters.pointee.width)
        self.height = Int(parameters.pointee.height)
        self.frameRate = (frameRate > 0.1 && frameRate < 1000) ? frameRate : 25
        self.isMTSOrInterlacedHint = isMTSOrInterlacedHint

        guard let decoder = avcodec_find_decoder(parameters.pointee.codec_id) else {
            throw FFmpegFailure(stage: "avcodec_find_decoder", code: -1)
        }
        codecName = FFmpegSupport.codecName(parameters.pointee.codec_id)

        guard let ctx = avcodec_alloc_context3(decoder) else {
            throw FFmpegFailure(stage: "avcodec_alloc_context3", code: -1)
        }
        codecCtx = ctx

        try FFmpegSupport.check(avcodec_parameters_to_context(ctx, parameters),
                                "avcodec_parameters_to_context")

        // thread_count = 0 → 让 FFmpeg 自己按 CPU 核数决定帧级并行。
        ctx.pointee.thread_count = 0
        ctx.pointee.pkt_timebase = timeBase

        // 对老的 MTS 隔行扫描 (1080 50i/60i)，若硬解可能导致 MBAFF 无法反交错或花屏，默认在隔行流中采用极速软解
        let requestHW = useHardware && !isMTSOrInterlacedHint

        // 若请求硬解，尝试建立 VideoToolbox 硬件上下文
        if requestHW {
            var hwRef: UnsafeMutablePointer<AVBufferRef>?
            let rc = av_hwdevice_ctx_create(&hwRef, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
            if rc >= 0, let hw = hwRef {
                hwDeviceCtx = hw
                ctx.pointee.hw_device_ctx = av_buffer_ref(hw)
                ctx.pointee.get_format = Self.vtGetFormat
                isHardwareAccelerated = true
            }
        }

        let openRC = avcodec_open2(ctx, decoder, nil)
        if openRC < 0 && isHardwareAccelerated {
            // 硬解初始化失败时，无缝回退到软解
            isHardwareAccelerated = false
            if hwDeviceCtx != nil { av_buffer_unref(&hwDeviceCtx) }
            if ctx.pointee.hw_device_ctx != nil { av_buffer_unref(&ctx.pointee.hw_device_ctx) }
            ctx.pointee.get_format = nil
            try FFmpegSupport.check(avcodec_open2(ctx, decoder, nil), "avcodec_open2(fallback to software)")
        } else {
            try FFmpegSupport.check(openRC, "avcodec_open2")
        }

        frame = av_frame_alloc()
        scratch = av_packet_alloc()
        guard frame != nil, scratch != nil else {
            throw FFmpegFailure(stage: "av_frame_alloc/av_packet_alloc", code: -1)
        }
    }

    deinit {
        if sws != nil { sws_freeContext(sws) }
        sws = nil
        if frame != nil { av_frame_free(&frame) }
        if scratch != nil { av_packet_free(&scratch) }
        if hwDeviceCtx != nil { av_buffer_unref(&hwDeviceCtx) }
        if codecCtx != nil { avcodec_free_context(&codecCtx) }
    }

    /// seek 之后调用：清掉解码器内部缓存的 GOP / 参考帧。
    func reset() {
        guard let ctx = codecCtx else { return }
        avcodec_flush_buffers(ctx)
    }

    // MARK: - 解码

    /// 送一个包进去，取回本次能产出的所有帧。
    /// - Parameter packet: 来自 MediaFileSource 的包；传 nil 表示流结束（冲刷）。
    func decode(packet: UnsafeMutablePointer<AVPacket>?) throws -> [DecodedVideoFrame] {
        guard let ctx = codecCtx, let fr = frame, let sc = scratch else { return [] }

        if let p = packet, p != sc {
            av_packet_unref(sc)
            let rc = av_packet_ref(sc, p)
            if rc < 0 { return [] }
        } else {
            av_packet_unref(sc)   // 传 nil 时给一个空的包 → 冲刷
        }

        let sendRC = avcodec_send_packet(ctx, sc)
        av_packet_unref(sc)
        if sendRC < 0 { return [] }   // EAGAIN / 坏包：跳过

        var out: [DecodedVideoFrame] = []
        let deintMode = PlaybackSettings.shared.deinterlaceMode

        while true {
            let rc = avcodec_receive_frame(ctx, fr)
            if rc < 0 { break }
            if !hasObservedDecodedFrame {
                hasObservedDecodedFrame = true
                let src = AVPixelFormat(rawValue: fr.pointee.format)
                isHardwareAccelerated = (src == AV_PIX_FMT_VIDEOTOOLBOX)
            }
            if let pb = convert(fr) {
                let pts = FFmpegSupport.seconds(fr.pointee.pts == Int64.min ? 0 : fr.pointee.pts,
                                               timeBase)
                let (csCode, is709) = Self.resolveColorSpace(fr)
                let fullRange = Self.resolveFullRange(fr, pixelBuffer: pb)
                let transferFunc = Self.resolveTransferFunction(fr, pixelBuffer: pb)
                let peakNits = Self.resolvePeakNits(fr)

                // 检测是否为隔行扫描视频帧 (1080 50i / 60i)
                let frInterlaced = (fr.pointee.flags & (1 << 3) != 0) || (fr.pointee.interlaced_frame != 0)
                let isTopFieldFirst = (fr.pointee.flags & (1 << 4) != 0) || (fr.pointee.top_field_first != 0)

                let shouldDeinterlace: Bool
                switch deintMode {
                case .off:
                    shouldDeinterlace = false
                case .on:
                    shouldDeinterlace = true
                case .auto:
                    // 智能判断：若标志位命中，或 MTS/M2TS 容器提示且帧率为典型的 25/29.97 附近
                    shouldDeinterlace = frInterlaced || isMTSOrInterlacedHint
                }

                if shouldDeinterlace, let (f0, f1) = FieldDeinterlacer.deinterlace2X(source: pb, isTopFieldFirst: isTopFieldFirst) {
                    if !didLogDeinterlace {
                        didLogDeinterlace = true
                        FileHandle.standardError.write(Data("[VideoDecoder] 隔行反交错已激活：双场自适应 2X 拆帧 1080 50i/60i (TFF: \(isTopFieldFirst)) -> 50/60 FPS 逐行输出\n".utf8))
                    }
                    // 双场倍帧输出：计算半帧时间步长 (60i -> 59.94/60.0 FPS; 50i -> 50.0 FPS)
                    let delta = (frameRate > 1.0) ? (0.5 / frameRate) : 0.016683
                    out.append(DecodedVideoFrame(pixelBuffer: f0,
                                                 pts: pts,
                                                 isBT709: is709,
                                                 colorSpaceCode: csCode,
                                                 isFullRange: fullRange,
                                                 transferFunction: transferFunc,
                                                 peakNits: peakNits))
                    out.append(DecodedVideoFrame(pixelBuffer: f1,
                                                 pts: pts + delta,
                                                 isBT709: is709,
                                                 colorSpaceCode: csCode,
                                                 isFullRange: fullRange,
                                                 transferFunction: transferFunc,
                                                 peakNits: peakNits))
                } else {
                    out.append(DecodedVideoFrame(pixelBuffer: pb,
                                                 pts: pts,
                                                 isBT709: is709,
                                                 colorSpaceCode: csCode,
                                                 isFullRange: fullRange,
                                                 transferFunction: transferFunc,
                                                 peakNits: peakNits))
                }
            }
            av_frame_unref(fr)
        }
        return out
    }

    /// 选色彩空间：0 = BT.601, 1 = BT.709, 2 = BT.2020
    private static func resolveColorSpace(_ fr: UnsafeMutablePointer<AVFrame>) -> (code: Int32, is709: Bool) {
        switch fr.pointee.colorspace.rawValue {
        case 9, 10:  return (2, true)  // BT.2020 NCL / CL
        case 1:      return (1, true)  // BT.709
        case 5, 6:   return (0, false) // BT.470BG / SMPTE170M (601)
        default:
            let is709 = fr.pointee.height >= 720
            return (is709 ? 1 : 0, is709)
        }
    }

    /// 解析传输特性：0 = SDR, 1 = SMPTE ST 2084 (PQ), 2 = ARIB STD-B67 (HLG)
    private static func resolveTransferFunction(_ fr: UnsafeMutablePointer<AVFrame>, pixelBuffer: CVPixelBuffer?) -> VideoTransferFunction {
        let trc = fr.pointee.color_trc.rawValue
        if trc == 16 /* AVCOL_TRC_SMPTE2084 */ {
            return .pq
        }
        if trc == 18 /* AVCOL_TRC_ARIB_STD_B67 */ {
            return .hlg
        }
        if let pb = pixelBuffer {
            if let unmanaged = CVBufferGetAttachment(pb, kCVImageBufferTransferFunctionKey, nil) {
                let trcObj = unmanaged.takeUnretainedValue()
                if CFGetTypeID(trcObj) == CFStringGetTypeID() {
                    let str = trcObj as! CFString
                    if CFStringCompare(str, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, []) == .compareEqualTo {
                        return .pq
                    }
                    if CFStringCompare(str, kCVImageBufferTransferFunction_ITU_R_2100_HLG, []) == .compareEqualTo {
                        return .hlg
                    }
                }
            }
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            let is10Bit = (fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                           fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
            let cs = fr.pointee.colorspace.rawValue
            if is10Bit && (cs == 9 || cs == 10) {
                return .pq
            }
        }
        return .sdr
    }

    /// 解析片源最高亮度元数据 (MaxCLL / Mastering Display Peak Luminance)
    private static func resolvePeakNits(_ fr: UnsafeMutablePointer<AVFrame>) -> Float {
        if let sideData = av_frame_get_side_data(fr, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
           let ptr = sideData.pointee.data {
            let cll = ptr.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { $0.pointee }
            if cll.MaxCLL > 0 {
                return Float(cll.MaxCLL)
            }
        }
        if let sideData = av_frame_get_side_data(fr, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
           let ptr = sideData.pointee.data {
            let mdm = ptr.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { $0.pointee }
            if mdm.has_luminance != 0 {
                let maxLum = Double(mdm.max_luminance.num) / max(Double(mdm.max_luminance.den), 1.0)
                if maxLum > 0 {
                    return Float(maxLum)
                }
            }
        }
        return 1000.0
    }

    /// 判断是否全范围（0-255）
    private static func resolveFullRange(_ fr: UnsafeMutablePointer<AVFrame>, pixelBuffer: CVPixelBuffer?) -> Bool {
        if fr.pointee.color_range.rawValue == 2 /* AVCOL_RANGE_JPEG */ {
            return true
        }
        if let pb = pixelBuffer {
            let fmt = CVPixelBufferGetPixelFormatType(pb)
            if fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
               fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange {
                return true
            }
        }
        return false
    }

    // MARK: - AVFrame → NV12 CVPixelBuffer

    private func convert(_ fr: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let w = Int(fr.pointee.width), h = Int(fr.pointee.height)
        guard w > 0, h > 0 else { return nil }

        let src = AVPixelFormat(rawValue: fr.pointee.format)

        // VideoToolbox 硬解直出 CVPixelBuffer（位于 data.3，零拷贝直通 Metal）
        if src == AV_PIX_FMT_VIDEOTOOLBOX {
            if let ptr = fr.pointee.data.3 {
                return Unmanaged<CVPixelBuffer>.fromOpaque(ptr).takeUnretainedValue()
            }
            return nil
        }

        guard let pb = makePixelBuffer(width: w, height: h) else { return nil }

        if src == AV_PIX_FMT_NV12 {
            // 已经是目标格式，直接按行拷（注意源/目的 stride 可能不同）
            guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let srcY = fr.pointee.data.0
            let srcUV = fr.pointee.data.1
            let srcYS = Int(fr.pointee.linesize.0)
            let srcUVS = Int(fr.pointee.linesize.1)
            if let dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
               let dstUV = CVPixelBufferGetBaseAddressOfPlane(pb, 1),
               let sy = srcY, let suv = srcUV {
                let dstYS = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let dstUVS = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
                for row in 0..<h {
                    memcpy(dstY.advanced(by: row * dstYS), sy.advanced(by: row * srcYS), w)
                }
                for row in 0..<(h / 2) {
                    memcpy(dstUV.advanced(by: row * dstUVS), suv.advanced(by: row * srcUVS), w)
                }
            }
            return pb
        }

        // 其它格式（yuv420p / yuv422p / yuv444p / 10bit …）走 swscale
        guard ensureSws(src: src, width: w, height: h) else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let d = fr.pointee.data
        let ls = fr.pointee.linesize
        // AVFrame.data / linesize 是 8 元素定长元组，swscale 只用到前 4 个平面
        var srcData: [UnsafePointer<UInt8>?] = [d.0, d.1, d.2, d.3].map {
            $0.map { UnsafePointer($0) }
        }
        var srcStride: [Int32] = [ls.0, ls.1, ls.2, ls.3]

        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil,
        ]
        var dstStride: [Int32] = [
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1)),
            0, 0,
        ]
        guard dstData[0] != nil, dstData[1] != nil else { return nil }

        _ = sws_scale(sws, &srcData, &srcStride, 0, Int32(h), &dstData, &dstStride)
        return pb
    }

    private func ensureSws(src: AVPixelFormat, width w: Int, height h: Int) -> Bool {
        if sws != nil, swsSourceFormat == src, swsSourceSize == (w, h) { return true }
        if sws != nil { sws_freeContext(sws); sws = nil }

        // SWS_BILINEAR：这里不做缩放（w/h 不变），只需一个好的色彩/格式转换。
        // SWS_ACCURATE_RND 保证 10bit → 8bit 的舍入一致，避免抖动。
        sws = sws_getContext(Int32(w), Int32(h), src,
                             Int32(w), Int32(h), AV_PIX_FMT_NV12,
                             SWS_BILINEAR | SWS_ACCURATE_RND,
                             nil, nil, nil)
        guard sws != nil else { return false }
        swsSourceFormat = src
        swsSourceSize = (w, h)
        return true
    }

    private func makePixelBuffer(width w: Int, height h: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferBytesPerRowAlignmentKey: 64,
        ]
        var pb: CVPixelBuffer?
        let rc = CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                     kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                     attrs as CFDictionary, &pb)
        guard rc == kCVReturnSuccess else { return nil }
        return pb
    }
}

#endif
