//  AudioOutput.swift
//  MetalPlayer 重建工程 —— Phase 1 音频输出
//
//  用 AVAudioEngine + AVAudioPlayerNode 播 PCM。
//  这一层**不依赖 FFmpeg**（只吃平面 Float32 的 PCMChunk），
//  所以它同时是「音频时钟」的来源：playerTime(forNodeTime:) 给出的采样计数
//  是整条链路里唯一由硬件驱动的、不会随 CPU 调度漂移的时间基准。
//
//  为什么不用 AudioQueue：
//    AVAudioPlayerNode 的 playerTime 直接给出「已渲染采样数 / 采样率」，
//    换算成媒体时间只要在一个锚点上加一下，比 AudioQueue 的 time stamp 回调好对齐。

import Foundation
import AVFoundation

final class AudioOutput {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    /// 播放格式：平面 Float32（= AVAudioFormat 的 standardFormat）。
    let format: AVAudioFormat

    private var engineRunning = false
    private var configObserver: NSObjectProtocol?

    /// 输出音量（0…1）。
    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    var isPlaying: Bool { player.isPlaying }

    init(sampleRate: Double = 48_000, channels: AVAudioChannelCount = 2) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
            ?? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        engine.attach(player)
        // 接 mainMixer：设备采样率与 48k 不一致时由它重采样，播放侧不必关心硬件。
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        teardown()
    }

    // MARK: - 引擎生命周期

    func start() throws {
        guard !engineRunning else { return }
        engine.prepare()
        try engine.start()
        engineRunning = true

        // 输出设备切换／采样率变化时 AVAudioEngine 会自己停掉，需要重建连接。
        if configObserver == nil {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                self?.handleConfigurationChange()
            }
        }
    }

    /// 尝试把引擎拉起来。已经活着就直接成功。
    ///
    /// 为什么单独抽出来：`handleConfigurationChange` 里 `engine.start()` 失败会把
    /// `engineRunning` 置 false，而 `play()` 原来只有一句 `guard engineRunning`——
    /// 于是一次失败（休眠唤醒时设备还没就绪就是这样）就让**本次会话永久静音**，
    /// 且 `renderedSeconds()` 永远返回 nil，音频主时钟随之冻结，画面跟着冻死。
    /// 起播是用户显式意图，这里必须允许重试。
    @discardableResult
    func startEngineIfNeeded() -> Bool {
        if engineRunning { return true }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        // dev-only：MP_FORCE_AUDIO_FAIL=1 模拟「唤醒后设备不可用」——engine.start() 抛错。
        if ProcessInfo.processInfo.environment["MP_FORCE_AUDIO_FAIL"] != nil {
            engineRunning = false
            return false
        }
        do {
            try engine.start()
            engineRunning = true
            return true
        } catch {
            engineRunning = false
            return false
        }
    }

    /// 音频硬件配置变更回调（设备重连、休眠唤醒等）
    var onConfigurationChange: (() -> Void)?

    func handleConfigurationChange() {
        guard engineRunning else { return }
        // 重新连一次，然后重启引擎；已排队的 buffer 会丢，播放器会自然重新缓冲。
        engineRunning = false           // 让 startEngineIfNeeded 走完整的重建路径
        let ok = startEngineIfNeeded()
        if !ok { Self.logLine("音频引擎重建失败，等下次起播时重试") }
        onConfigurationChange?()
    }

    /// 恢复播放时的兜底：引擎「假活」或节点被系统打断后，`play()` 是空操作。
    ///
    /// 判据来自播放器侧：已经进入播放态、`wantPlaying` 为真，但音频时钟连续若干秒
    /// 一动不动。这时唯一还可能出问题的就是音频栈本身，所以整条重建：
    /// 停引擎 → 重新连接 → 启动 → play，最后通知上层重算锚点
    ///（buffer 已丢，锚点不重算会把时钟带到错误的位置）。
    func restartForResume() {
        if engineRunning {
            if player.isPlaying { player.stop() }
            engine.stop()
            engineRunning = false
        }
        guard startEngineIfNeeded() else {
            Self.logLine("恢复失败：引擎仍无法启动")
            return
        }
        // 这里**不**调 player.play()：重启后队列里一个 buffer 都没有，
        // 空 buffer 起播会让 playerTime 空转、把音频时钟带飞（见 applySeek 的注释）。
        // 交给音频线程排入第一块后由 scheduleAudio 唤醒。
        Self.logLine("已强制重建音频栈，等待音频线程重新排入 buffer")
        onConfigurationChange?()
    }

    private static func logLine(_ message: String) {
        FileHandle.standardError.write(Data("[AudioOutput] \(message)\n".utf8))
    }

    func teardown() {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
        if player.isPlaying { player.stop() }
        if engineRunning {
            engine.stop()
            engineRunning = false
        }
    }

    // MARK: - 播放控制

    /// 开始播放。因为 AVAudioPlayerNode 在没有已排队 buffer 时不会推进 playerTime，
    /// 所以这里只负责「开始渲染」，什么时候有声音由 schedule 决定。
    ///
    /// 注意 `startEngineIfNeeded()`：引擎可能因为一次休眠唤醒/设备切换失败而停在
    /// engineRunning == false，此时直接 return 会让本次会话再也出不了声，
    /// 而音频是主时钟 —— 不出声就等于把画面一起冻住。
    func play() {
        guard startEngineIfNeeded() else { return }
        if !player.isPlaying { player.play() }
    }

    /// 在停下来之前先把增益线性拉到 0。
    ///
    /// 为什么需要它：直接 `stop()` / `pause()` 会在波形的**任意相位**上把输出
    /// 切断，从满幅直接跳到 0 是一次阶跃 —— 耳朵听到的就是「啪」一声爆音。
    /// 用户实测拖进度条时音响会爆音，根因就在这里。
    ///
    /// 分档降到 0 而不是一步到位：单次 12.5% 的跳变能量只有满幅的 1/64，
    /// 听不出来；总时长 24ms（8 档 × 3ms）足够盖住任意相位（48kHz 下
    /// 半个周期才 0.01ms），又短到不影响 seek 响应。
    private func fadeOutBeforeStop() {
        let saved = player.volume
        var level: Float = 0.875
        while level > 0.001 {
            player.volume = level
            Thread.sleep(forTimeInterval: 0.003)
            level -= 0.125
        }
        player.volume = 0
        Thread.sleep(forTimeInterval: 0.003)
        // 先还原再停：stop() 之后的增益留到下次 play 时才生效，
        // 这里补回来免得下次出声时音量被压着。
        player.volume = saved
    }

    func pause() {
        guard player.isPlaying else { return }
        fadeOutBeforeStop()
        player.pause()
    }

    /// 丢弃所有已排队 buffer 并把时间轴归零。用于 seek / 打开新文件。
    /// 调用后必须重新 schedule 才会出声。
    func flush() {
        // 爆音在主路径上：seek 必经这里（见 fadeOutBeforeStop 的注释）。
        // 没在播就不必淡出 —— 此时输出本来就是静音，白睡 24ms 没意义。
        if player.isPlaying { fadeOutBeforeStop() }
        player.stop()
    }

    // MARK: - 送数据

    /// 把一个 PCM 块排进播放队列。
    func schedule(_ chunk: PCMChunk) -> Bool {
        guard engineRunning, chunk.frameCount > 0 else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(chunk.frameCount))
        else { return false }
        buffer.frameLength = AVAudioFrameCount(chunk.frameCount)

        guard let dst = buffer.floatChannelData else { return false }
        let outChannels = Int(format.channelCount)
        let bytes = chunk.frameCount * MemoryLayout<Float>.size
        for ch in 0..<min(chunk.channels, outChannels) {
            chunk.planes[ch].withUnsafeBufferPointer { src in
                guard let base = src.baseAddress else { return }
                memcpy(dst[ch], base, bytes)
            }
        }
        // 输入是单声道而输出是立体声时，复制一份到右声道，避免只响左边。
        if chunk.channels == 1, outChannels >= 2 {
            for ch in 1..<outChannels {
                chunk.planes[0].withUnsafeBufferPointer { src in
                    guard let base = src.baseAddress else { return }
                    memcpy(dst[ch], base, bytes)
                }
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        return true
    }

    // MARK: - 时钟

    /// dev-only 诊断：把「player 到底有没有在真渲染」这件事一次说清。
    ///
    /// 暂停→恢复卡死的根因只可能落在这三个值里：引擎是否还活着（engineRunning）、
    /// 节点是否真的在跑（player.isPlaying）、硬件时钟是否可读（renderedSeconds）。
    /// 排查时缺任何一个都只能靠猜，所以给暂停自检留一个聚合成一行的读数。
    var debugStateText: String {
        let rendered = renderedSeconds().map { String(format: "%.3f", $0) } ?? "nil"
        return "engine=\(engineRunning ? "run" : "STOP") "
             + "player=\(player.isPlaying ? "play" : "PAUSE") rendered=\(rendered)"
    }

    /// 自本节点最近一次 play() 起已经渲染的秒数。
    /// 节点没有在播放时返回 nil —— 调用方据此判断「音频时钟当前不可用」。
    func renderedSeconds() -> Double? {
        guard player.isPlaying,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }
}
