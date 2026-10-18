//  TimeFormat.swift
//  MetalPlayer 重建工程 —— 时间显示格式
//
//  为什么单独一个文件、而不是复用 `FFmpegSupport.timeLabel`：
//  那个函数在 `#if USE_FFMPEG` 里（因为整个 FFmpegSupport 都要 C 模块）。
//  而 UI 层要能在**关掉 USE_FFMPEG 的构建**里独立编译 —— 那是 Phase 1 验收的一条硬要求。
//  所以时间格式化在 UI 侧另有一份，不依赖 FFmpeg。

import Foundation

enum TimeFormat {

    /// `mm:ss`，超过一小时给 `h:mm:ss`。
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    /// 控制条上用的「当前 / 总长」。
    static func progress(current: Double, duration: Double) -> String {
        guard duration > 0 else { return "--:-- / --:--" }
        return "\(clock(current)) / \(clock(duration))"
    }
}
