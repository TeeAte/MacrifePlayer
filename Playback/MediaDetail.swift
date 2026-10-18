//  MediaDetail.swift
//  MetalPlayer 重建工程 —— 「性能监看」面板的数据源（Phase 2 增补）
//
//  这个文件是 Tab 监看面板的上半部分：把 FFmpeg 里读到的**源视频详细参数**
//  装进一个纯值类型，UI 层只读它、不碰任何 FFmpeg 结构体。
//
//  为什么要是纯值类型（和 `TrackInfo` / `DecodedVideoFrame` 一个道理）：
//    `MediaFileSource` 有明确的线程约定 —— 只允许解封装线程碰（见它的文件头）。
//    如果面板直接去读 `AVCodecParameters`，就是在主线程越界摸别人的结构体。
//    所以开文件时**取一次快照**（`MediaFileSource.detail()`），之后 UI 只读快照。
//
//  这是 Phase 2 的**新增功能**，不是从二进制恢复的：
//  原版有没有这个面板无从得知（符号表给不出 UI 行为）。所以这里的字段名是
//  按 FFmpeg 的既有概念起的，不冒充「观测到的成员名」。

import Foundation

// MARK: - 视频流

struct VideoStreamDetail {
    var codec = "?"
    /// 形如 `High` / `Main`（`avcodec_profile_name`）。
    var profile = ""
    /// 形如 31 → 显示成 `L3.1`。
    var level: Int32 = 0
    var width = 0
    var height = 0
    var frameRate: Double = 0
    /// 形如 `yuv420p` / `nv12` / `yuv420p10le`。
    var pixelFormat = "?"
    var bitRate: Int64 = 0
    var colorPrimaries = ""
    var colorTransfer = ""
    var colorSpace = ""
    var colorRange = ""

    /// `High L3.1`，缺项就省掉。
    var profileLevelText: String {
        var parts: [String] = []
        if !profile.isEmpty { parts.append(profile) }
        if level > 0 { parts.append("L\(String(format: "%.1f", Double(level) / 10))") }
        return parts.joined(separator: " ")
    }

    /// `1280x720`。
    var resolutionText: String { "\(width)x\(height)" }
}

// MARK: - 音频流

struct AudioStreamDetail {
    var codec = "?"
    var profile = ""
    /// 形如 `fltp` / `s16p`（`av_get_sample_fmt_name`）。
    var sampleFormat = ""
    /// 形如 `stereo` / `5.1`（`av_channel_layout_describe`）。
    var channelLayout = ""
    var channels = 0
    var sampleRate = 0
    var bitRate: Int64 = 0
}

// MARK: - 容器

struct ContainerDetail {
    var fileName = ""
    var formatName = "?"
    /// 形如 `Matroska / WebM`。
    var formatLongName = ""
    var duration: Double = 0
    var bitRate: Int64 = 0
    var fileSize: Int64 = 0
    var streamCount = 0
    var videoCount = 0
    var audioCount = 0
    var subtitleCount = 0
}

// MARK: - 整个文件的参数快照

struct MediaDetail {
    var container = ContainerDetail()
    var video: VideoStreamDetail?
    var audio: AudioStreamDetail?

    var hasAny: Bool { video != nil || audio != nil || !container.fileName.isEmpty }

    /// 码率 → `4.2 Mb/s`。0 表示容器没给，返回空串（不显示假的 0）。
    static func bitRateText(_ value: Int64) -> String {
        guard value > 0 else { return "" }
        let kbps = Double(value) / 1000
        if kbps >= 1000 { return String(format: "%.2f Mb/s", kbps / 1000) }
        return String(format: "%.0f kb/s", kbps)
    }

    /// 字节 → `1.4 GB`。用系统格式化器，省得自己处理单位与本地化。
    static func fileSizeText(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return f.string(fromByteCount: bytes)
    }

    /// 帧率 → `23.976 fps`（整数帧率不显示小数，免得 `24.000 fps` 看起来奇怪）。
    static func frameRateText(_ fps: Double) -> String {
        guard fps > 0 else { return "? fps" }
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.001 { return String(format: "%.0f fps", rounded) }
        return String(format: "%.3f fps", fps)
    }
}
