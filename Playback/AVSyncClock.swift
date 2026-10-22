//  AVSyncClock.swift
//  MetalPlayer 重建工程 —— Phase 1 音视频同步时钟
//
//  同步策略：**音频为主时钟**。
//
//  理由：画面的「准时」由显示时刻决定，晚一帧只是抖动；
//  声音的「准时」由声卡决定，晚一点就是爆音或卡顿。所以业界标准做法是
//  让视频去追音频，而不是反过来。
//
//  时钟有三个来源，按优先级：
//    1. 音频时钟 —— AVAudioPlayerNode 已渲染采样数 / 采样率，加上锚点偏移。
//       唯一的硬件驱动时间，不随 CPU 调度漂移。
//    2. 墙钟回落 —— 容器里没有音轨时（纯视频 / 静音轨）用锚点 + 单调时间。
//    3. 冻结值    —— 暂停 / 音频尚未起来时返回最后已知时间，保证画面不跳。
//
//  underrun 保护：音频时钟可能跑到「已排队音频」之外（解码跟不上时，
//  AVAudioPlayerNode 会输出静音但 playerTime 照走）。这时把时钟夹在
//  scheduledAudioEnd 上，宁可画面等声音，也不要画面冲到没声音的位置。

import Foundation

final class AVSyncClock {

    /// 音频时钟提供者：返回「此刻正在听到的媒体时间」，不可用时返回 nil。
    var audioTimeProvider: (() -> Double?)?

    /// 是否真的存在音轨。没有音轨时直接走墙上时钟。
    var hasAudio = false

    /// 音频已经排队到的媒体时间上界。
    var scheduledAudioEnd: Double = 0

    private var running = false
    private var lastTime: Double = 0
    private var fallbackAnchorMedia: Double = 0
    private var fallbackAnchorHost: UInt64 = 0

    var isRunning: Bool { running }

    /// 未夹取的音频时钟（可能跑到 scheduledAudioEnd 之外 = 已经断供）。
    ///
    /// 单独暴露出来只为一件事：给音频限流器用。
    /// `currentTime()` 会把音频时钟**夹到** scheduledAudioEnd 上（underrun 时画面要等声音），
    /// 这就带来一个致命的副作用 —— 一旦音频钟越过排队上界，`currentTime() == scheduledAudioEnd`
    /// 恒成立，「超前量 = scheduledAudioEnd - currentTime()」就恒等于 0，限流器会误判
    /// 「完全没有超前」而无限解码。实测后果：音频包队列被灌到 600 满，解封装线程卡在
    /// 音频队列上再也读不出视频包 → 画面冻死、补帧看门狗连跳。
    func rawAudioTime() -> Double? {
        guard running, hasAudio, let provider = audioTimeProvider else { return nil }
        return provider()
    }

    /// 已排队音频比「正在听到的位置」超前多少秒（限流专用，不夹取）。
    func scheduledLead() -> Double {
        scheduledAudioEnd - (rawAudioTime() ?? lastTime)
    }

    /// 现在到了切换音轨、需要重排音频锚点的时机。
    func setScheduledEnd(_ t: Double) {
        scheduledAudioEnd = t
    }

    /// 当前媒体时间（秒）。
    func currentTime() -> Double {
        guard running else { return lastTime }

        if hasAudio {
            if let provider = audioTimeProvider, let audioTime = provider() {
                // 夹到「已排队上界」：声音断供时画面必须等
                let ceiling = max(scheduledAudioEnd, lastTime)
                let clamped = min(audioTime, ceiling)
                lastTime = clamped
                return clamped
            }
            // 音频存在但时钟暂不可用（刚 seek、刚 play、暂停中）：冻结。
            return lastTime
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now &- fallbackAnchorHost) / 1_000_000_000
        let t = fallbackAnchorMedia + elapsed
        lastTime = t
        return t
    }

    /// 把时钟重置到 `mediaTime`（seek / 打开新文件时调用）。
    func reset(to mediaTime: Double) {
        lastTime = mediaTime
        fallbackAnchorMedia = mediaTime
        fallbackAnchorHost = DispatchTime.now().uptimeNanoseconds
    }

    /// 开始走时（播放）。
    func start() {
        guard !running else { return }
        running = true
        fallbackAnchorMedia = lastTime
        fallbackAnchorHost = DispatchTime.now().uptimeNanoseconds
    }

    /// 停止走时（暂停）。先抓一次当前值，避免暂停瞬间画面跳一格。
    func pause() {
        guard running else { return }
        lastTime = currentTime()
        running = false
    }
}
