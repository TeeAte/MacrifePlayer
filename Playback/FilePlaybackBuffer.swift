import Foundation

/// File playback trades startup time for a bounded reservoir of completed frames.
/// Capture never uses this policy or its audio/clock gate.
struct FilePlaybackBufferPolicy {
    let targetFPS: Double
    let seconds: Double
    let memoryMB: Int
    let frameBytes: Int

    var capacity: Int {
        let memoryFrames = max(2, memoryMB * 1_048_576 / max(1, frameBytes))
        return min(240, memoryFrames, max(12, Int(ceil(max(1, targetFPS) * (seconds + 0.5)))))
    }
    var readyFrames: Int { max(1, min(capacity - 2, max(4, Int(ceil(max(1, targetFPS) * seconds))))) }

    /// Consecutive jobs on each CoreML engine reuse the previous frame's
    /// conversion/features. Round-robin pairs lose that cache on every job.
    static func workerIndex(sequence: Int, workers: Int) -> Int {
        (sequence / 4) % max(1, workers)
    }
}

struct FilePlaybackBufferState {
    enum Transition { case wait, play, pause, none }
    private(set) var isBuffering = true
    private(set) var rebufferCount = 0

    mutating func update(available: Int, readyFrames: Int, drained: Bool,
                         ranOut: Bool) -> Transition {
        if isBuffering {
            if available >= readyFrames || (drained && available > 0) {
                isBuffering = false
                return .play
            }
            return .wait
        }
        if ranOut && !drained {
            isBuffering = true
            rebufferCount += 1
            return .pause
        }
        return .none
    }
}
