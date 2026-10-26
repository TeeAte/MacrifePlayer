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

    /// 音频硬件配置变更回调（设备重连、休眠唤醒等）
    var onConfigurationChange: (() -> Void)?

    func handleConfigurationChange() {
        guard engineRunning else { return }
        // 重新连一次，然后重启引擎；已排队的 buffer 会丢，播放器会自然重新缓冲。
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do { try engine.start() } catch {
            engineRunning = false
        }
        onConfigurationChange?()
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
    func play() {
        guard engineRunning else { return }
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
