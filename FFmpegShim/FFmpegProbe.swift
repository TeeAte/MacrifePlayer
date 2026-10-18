//  FFmpegProbe.swift
//  MetalPlayer 重建工程 —— FFmpeg 接入层
//
//  这一层是 Swift 与 FFmpeg C 接口之间的唯一通道。
//
//  为什么放在 FFmpegShim/ 而不是 MetalPlayer/：
//  MetalPlayer/ 由 _reverse/generate.py 重新生成，手写代码会被覆盖；
//  FFmpegShim/ 由 _reverse/make_ffmpeg_shim.py 维护（本文件是模板，
//  从 _reverse/ffmpeg_shim/ 拷入），不参与源码重建。
//
//  Phase 0 验收：能在 app 内 `avformat_open_input` 打开 MKV 并读出流信息。

import Foundation

#if USE_FFMPEG
import CFFmpeg
#endif

/// FFmpeg 接入自检 / 探针。
public enum FFmpegProbe {

    /// 是否编译期启用了 FFmpeg（对应 SWIFT_ACTIVE_COMPILATION_CONDITIONS=USE_FFMPEG）。
    public static var isEnabled: Bool {
        #if USE_FFMPEG
        return true
        #else
        return false
        #endif
    }

    /// FFmpeg 运行时版本，例如 "7.1.1"。
    public static var version: String {
        #if USE_FFMPEG
        guard let p = av_version_info() else { return "unknown" }
        return String(cString: p)
        #else
        return "未启用"
        #endif
    }

    /// 库版本三元组，用于核对头文件与 dylib 是否 ABI 对齐。
    public static var libraryVersions: String {
        #if USE_FFMPEG
        let c = avcodec_version(), f = avformat_version(), u = avutil_version()
        return "avcodec \(triple(c)) / avformat \(triple(f)) / avutil \(triple(u))"
        #else
        return "未启用"
        #endif
    }

    /// 已注册的解封装器 / 解码器数量 —— 用来确认注册表完整（不是空壳）。
    public static var codecInventory: String {
        #if USE_FFMPEG
        var dCount = 0
        var it: UnsafeMutableRawPointer?
        while av_demuxer_iterate(&it) != nil { dCount += 1 }
        var cCount = 0
        var ci: UnsafeMutableRawPointer?
        while av_codec_iterate(&ci) != nil { cCount += 1 }
        return "\(dCount) 个解封装器 / \(cCount) 个编解码器"
        #else
        return "未启用"
        #endif
    }

    /// 打开媒体文件并返回流信息摘要。失败时返回原因文本，不抛异常。
    public static func describe(path: String) -> String {
        #if USE_FFMPEG
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        let rc = path.withCString { avformat_open_input(&fmt, $0, nil, nil) }
        guard rc >= 0, let ctx = fmt else {
            return "avformat_open_input 失败: \(errorText(rc))"
        }
        defer {
            var p: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&p)
        }

        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            return "avformat_find_stream_info 失败"
        }

        let fmtName = ctx.pointee.iformat.flatMap { String(cString: $0.pointee.name) } ?? "?"
        let secs = Double(ctx.pointee.duration) / Double(AV_TIME_BASE)

        var lines = [
            "封装格式: \(fmtName)",
            String(format: "时长: %.3f s", secs),
            "流数量: \(ctx.pointee.nb_streams)",
        ]

        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let st = ctx.pointee.streams[i] else { continue }
            guard let par = st.pointee.codecpar else { continue }
            let kind = av_get_media_type_string(par.pointee.codec_type)
                .flatMap { String(cString: $0) } ?? "?"
            let codec = avcodec_get_name(par.pointee.codec_id)
                .flatMap { String(cString: $0) } ?? "?"
            switch par.pointee.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                let fps = av_q2d(st.pointee.avg_frame_rate)
                lines.append(String(format: "  [%d] %@ %@ %dx%d @%.3f fps",
                                    i, kind, codec,
                                    par.pointee.width, par.pointee.height, fps))
            case AVMEDIA_TYPE_AUDIO:
                lines.append(String(format: "  [%d] %@ %@ %d Hz, %d ch",
                                    i, kind, codec,
                                    par.pointee.sample_rate, par.pointee.ch_layout.nb_channels))
            default:
                lines.append("  [\(i)] \(kind) \(codec)")
            }
        }
        return lines.joined(separator: "\n")
        #else
        return "FFmpeg 未启用"
        #endif
    }

    #if USE_FFMPEG
    /// FFmpeg 的 AV_VERSION_MAJOR/MINOR/MICRO 是函数式宏，Swift 无法导入
    /// （`#define AV_VERSION_MAJOR(a) ((a) >> 16)`），这里按同一定义用位运算重写。
    private static func triple(_ v: UInt32) -> String {
        "\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    /// 把 av_strerror 的错误码翻成人话。
    private static func errorText(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buf, buf.count)
        return String(cString: buf)
    }
    #endif
}
