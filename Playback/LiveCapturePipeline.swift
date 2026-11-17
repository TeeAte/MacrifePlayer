import Foundation

enum PlaybackInputKind: String {
    case videoFile, captureCard
    var title: String { self == .videoFile ? "视频文件" : "采集卡" }
}

/// FPS and scheduling travel with a frame instead of being inferred from the
/// last capture session's global state.
enum FrameSourceContext {
    case videoFile(fps: Double)
    case captureCard(transportFPS: Double, contentFPS: Double)

    var inputKind: PlaybackInputKind {
        switch self { case .videoFile: return .videoFile; case .captureCard: return .captureCard }
    }
    var sourceFPS: Double {
        switch self { case .videoFile(let fps): return fps; case .captureCard(_, let fps): return fps }
    }
    var isLive: Bool { inputKind == .captureCard }
    func needsInterpolation(enabled: Bool, targetFPS: Double) -> Bool {
        enabled && targetFPS > sourceFPS + 0.5
    }
}

/// UVC startup can deliver a zero timestamp before switching to host uptime.
/// Keep that epoch change out of the playout clock and interpolation cadence.
struct CaptureTimestampMapper {
    private var offset: Double?
    private var lastPTS: Double = 0

    mutating func reset() { self = Self() }

    mutating func time(sourceTime: Double, fallbackTime: Double) -> Double? {
        guard sourceTime.isFinite, sourceTime > 0 else {
            guard offset != nil else { return nil }
            lastPTS = max(lastPTS, fallbackTime)
            return lastPTS
        }
        if offset == nil { offset = sourceTime }
        var pts = sourceTime - offset!
        if pts < lastPTS - 0.001 || abs(pts - fallbackTime) > 5 {
            offset = sourceTime - fallbackTime
            pts = fallbackTime
        }
        lastPTS = max(lastPTS, pts)
        return lastPTS
    }
}

/// Fit inference to the chosen 16:9 budget without upscaling source pixels.
/// Both dimensions stay even for NV12. This is independent of queue latency.
enum InferenceGeometry {
    static func fit(sourceWidth: Int, sourceHeight: Int, maxHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (2, 2) }
        let cap = Double(max(2, maxHeight))
        let scale = min(1, min(cap * 16 / 9 / Double(sourceWidth), cap / Double(sourceHeight)))
        return (max(2, Int(Double(sourceWidth) * scale) / 2 * 2),
                max(2, Int(Double(sourceHeight) * scale) / 2 * 2))
    }
}

/// Manual console-30 mode: keep the first capture tick, then every other
/// tick on the 60Hz PTS grid. No image sampling, detection window or lookahead.
/// Using PTS parity (rather than callback count) preserves phase across drops.
struct Console30FrameSelector {
    private var anchorPTS: Double?
    private var lastPTS: Double?
    private var lastTick = -1

    mutating func reset() { self = Self() }

    mutating func select(pts: Double, captureFPS: Double, enabled: Bool)
        -> (keep: Bool, contentFPS: Double) {
        guard enabled, (55...65).contains(captureFPS), pts.isFinite else {
            reset()
            return (true, captureFPS)
        }
        if anchorPTS == nil || (lastPTS.map { pts < $0 || pts - $0 > 0.5 } ?? false) {
            anchorPTS = pts
            lastTick = -1
        }
        lastPTS = pts
        let tick = Int(((pts - anchorPTS!) * captureFPS).rounded())
        guard tick > lastTick else { return (false, captureFPS / 2) }
        lastTick = tick
        return (tick % 2 == 0, captureFPS / 2)
    }
}

/// 用至少约一秒的计数差读 FPS，避免临时诊断刷新恰好落在两拍之间，
/// 将正常的 60fps 读成 40/70fps。时间由调用方提供，使用单调时钟。
struct FrameRateWindow {
    private var samples: [(time: Double, presented: Int, decoded: Int)] = []

    mutating func sample(time: Double, presented: Int, decoded: Int) -> (render: Double, decode: Double) {
        if let last = samples.last, time < last.time || presented < last.presented || decoded < last.decoded {
            samples.removeAll(keepingCapacity: true)
        }
        samples.append((time, presented, decoded))
        while samples.count > 2, samples[1].time <= time - 1 { samples.removeFirst() }
        guard let first = samples.first, time - first.time > 0.05 else { return (0, 0) }
        return (Double(presented - first.presented) / (time - first.time),
                Double(decoded - first.decoded) / (time - first.time))
    }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }
}

/// 直播不能像文件一样对上游施加长时间背压；预算只覆盖少量正在处理的帧对。
struct CaptureLatencyPolicy {
    let isExtreme: Bool

    static func requiresInterpolation(sourceFPS: Double, targetFPS: Double) -> Bool {
        targetFPS > sourceFPS + 0.5
    }

    var inputCapacity: Int { isExtreme ? 1 : 2 }
    var maxInflightPairs: Int { isExtreme ? 2 : 3 }
    var passthroughCapacity: Int { isExtreme ? 1 : 2 }

    func outputCapacity(sourceFPS: Double, targetFPS: Double) -> Int {
        let framesPerPair = max(1, Int(ceil(max(1, targetFPS) / max(1, sourceFPS))))
        // 保留整对输出，让中间插帧有机会按节奏上屏；不用「只取最新」吞掉补帧。
        return min(24, framesPerPair * (isExtreme ? 1 : 2) + 1)
    }
}

/// 采集补帧专用播放锚点。推理的必要耗时由首批结果确定，迟到恢复时只对齐
/// 最新就绪结果，不让文件回放的 150–600ms 容差和反复回拨时钟积累直播延迟。
struct CapturePlayoutClock {
    private var anchorPTS: Double?
    private var anchorHostTime: Double = 0
    private var hasInterpolatedAnchor = false

    /// 原生低延迟模型能报告实际处理耗时；以输入时轴决定播放点，避免把启动时
    /// 一次性的预热耗时永久留在播放锚点里。半个源周期是中间帧所需的前视。
    static func livePresentationTime(latestPTS: Double, receivedHostTime: Double, hostTime: Double,
                                     sourceFPS: Double, processingSeconds: Double) -> Double {
        latestPTS + max(0, hostTime - receivedHostTime)
            - 0.5 / max(1, sourceFPS) - max(0, processingSeconds)
    }

    mutating func reset() {
        anchorPTS = nil
        anchorHostTime = 0
        hasInterpolatedAnchor = false
    }

    mutating func presentationTime(hostTime: Double, nextPTS: Double, newestPTS: Double,
                                   frameInterval: Double, sourceInterval: Double,
                                   isInterpolated: Bool = false) -> Double {
        // 第一张原帧可以立即显示，但第一张 AI 中间帧要重新建立播放锚点。
        // 否则原帧的零等待时钟会把后来才生成的中间帧全部当成过期帧吞掉。
        if isInterpolated && !hasInterpolatedAnchor {
            hasInterpolatedAnchor = true
            reanchor(pts: nextPTS, hostTime: hostTime)
            return nextPTS
        }
        guard let anchorPTS else {
            reanchor(pts: nextPTS, hostTime: hostTime)
            return nextPTS
        }
        let due = anchorPTS + max(0, hostTime - anchorHostTime)
        let recoveryWindow = max(sourceInterval, 2 * frameInterval)
        if due > newestPTS + recoveryWindow {
            reanchor(pts: newestPTS, hostTime: hostTime)
            return newestPTS
        }
        if nextPTS > due + recoveryWindow {
            reanchor(pts: nextPTS, hostTime: hostTime)
            return nextPTS
        }
        return due
    }

    private mutating func reanchor(pts: Double, hostTime: Double) {
        anchorPTS = pts
        anchorHostTime = hostTime
    }
}
