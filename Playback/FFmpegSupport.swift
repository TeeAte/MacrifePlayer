//  FFmpegSupport.swift
//  MetalPlayer 重建工程 —— Phase 1「真实播放（文件）」
//
//  这一层是 Playback/ 目录下所有手写代码共用的 FFmpeg 小工具：错误码翻译、
//  时间基换算、日志级别压制、可用性开关。
//
//  与 FFmpegShim/ 的分工：
//    FFmpegShim/          —— C 接口的暴露层（modulemap + 汇总头 + 探针），模板在 _reverse/ffmpeg_shim/
//    MetalPlayerRecon/Playback/ —— 播放引擎本体（本目录），手写，不参与标识符重建
//
//  Playback/ 不会被 _reverse/generate.py 覆盖：generate.py 只清理 MetalPlayer/ 子树。
//  工程收集由 _reverse/make_project.py 的 EXTRA_SRC_DIRS 负责。

import Foundation
import CoreMedia

#if USE_FFMPEG
import CFFmpeg
#endif

/// 播放引擎可用性开关。
///
/// 对应 `SWIFT_ACTIVE_COMPILATION_CONDITIONS = USE_FFMPEG`（见 `_reverse/make_project.py`）。
/// 关掉时 `PlaybackRootView` 会退化为「FFmpeg 未启用」占位视图，
/// 整个工程不产生任何 FFmpeg 链接依赖 —— 保证开关失败时不至于连编译都过不去。
enum PlaybackAvailability {
    static var isAvailable: Bool {
        #if USE_FFMPEG
        return true
        #else
        return false
        #endif
    }
}

#if USE_FFMPEG

/// FFmpeg 错误包装：带上出错阶段和可读的错误码解释。
struct FFmpegFailure: LocalizedError {
    let stage: String
    let code: Int32
    var errorDescription: String? {
        "\(stage) 失败: \(FFmpegSupport.errorText(code)) (\(code))"
    }
}

enum FFmpegSupport {

    /// 一次性初始化：把 FFmpeg 的日志级别压到 ERROR。
    /// 默认级别会往 stderr 刷一大堆解码器噪声，而本工程自己会打印关键信息。
    private static let bootstrap: Void = {
        av_log_set_level(AV_LOG_ERROR)
    }()

    static func ensureReady() { _ = bootstrap }

    /// av_strerror 的错误码解释。
    static func errorText(_ code: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buf, buf.count)
        return String(cString: buf)
    }

    /// 时间戳 → 秒（按给定时间基）。
    static func seconds(_ ts: Int64, _ tb: AVRational) -> Double {
        guard tb.den != 0, ts != Int64.min else { return 0 }
        return Double(ts) * Double(tb.num) / Double(tb.den)
    }

    /// 秒 → 时间戳（按给定时间基），用于 seek。
    static func timestamp(seconds: Double, tb: AVRational) -> Int64 {
        guard tb.num != 0 else { return 0 }
        let v = seconds * Double(tb.den) / Double(tb.num)
        if !v.isFinite { return 0 }
        return Int64(v.rounded())
    }

    static func mediaTypeName(_ t: AVMediaType) -> String {
        av_get_media_type_string(t).flatMap { String(cString: $0) } ?? "?"
    }

    /// 负返回码即失败，`stage` 用来指明是哪一步挂的。
    static func check(_ code: Int32, _ stage: String) throws {
        if code < 0 { throw FFmpegFailure(stage: stage, code: code) }
    }

    static func codecName(_ id: AVCodecID) -> String {
        avcodec_get_name(id).flatMap { String(cString: $0) } ?? "?"
    }

    /// 把秒格式化成 mm:ss（超过一小时给 h:mm:ss），给 UI 用。
    static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }
}

#endif
