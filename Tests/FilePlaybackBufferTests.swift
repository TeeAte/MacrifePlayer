import Foundation

@main
enum FilePlaybackBufferTests {
    static func main() {
        var state = FilePlaybackBufferState()
        precondition(state.update(available: 7, readyFrames: 8, drained: false, ranOut: false) == .wait)
        precondition(state.isBuffering)
        precondition(state.update(available: 8, readyFrames: 8, drained: false, ranOut: false) == .play)
        precondition(state.update(available: 0, readyFrames: 8, drained: false, ranOut: false) == .none,
                     "A not-yet-due frame interval is not an underrun")
        precondition(state.update(available: 0, readyFrames: 8, drained: false, ranOut: true) == .pause)
        precondition(state.isBuffering && state.rebufferCount == 1)
        precondition(state.update(available: 1, readyFrames: 8, drained: false, ranOut: false) == .wait,
                     "Do not repeatedly restart audio for every late AI pair")
        precondition(state.update(available: 8, readyFrames: 8, drained: false, ranOut: false) == .play)
        precondition(state.update(available: 0, readyFrames: 8, drained: true, ranOut: true) == .none)
        state = FilePlaybackBufferState()
        precondition(state.update(available: 3, readyFrames: 60, drained: true, ranOut: false) == .play,
                     "Short videos and tails must not wait for an unreachable buffer threshold")

        let fourK = FilePlaybackBufferPolicy(targetFPS: 48, seconds: 2, memoryMB: 1024,
                                            frameBytes: 4096 * 2304 * 2)
        precondition(fourK.capacity * fourK.frameBytes <= 1024 * 1_048_576)
        precondition(fourK.readyFrames < fourK.capacity)
        let hd = FilePlaybackBufferPolicy(targetFPS: 48, seconds: 2, memoryMB: 1024,
                                         frameBytes: 1920 * 1080 * 2)
        precondition(hd.readyFrames == 96 && hd.capacity > hd.readyFrames)
        let eightK = FilePlaybackBufferPolicy(targetFPS: 60, seconds: 2, memoryMB: 256,
                                             frameBytes: 7680 * 4320 * 3)
        precondition(eightK.capacity * eightK.frameBytes <= 256 * 1_048_576)
        precondition(eightK.readyFrames > 0 && eightK.readyFrames < eightK.capacity)
        precondition((0..<8).map { FilePlaybackBufferPolicy.workerIndex(sequence: $0, workers: 2) }
            == [0,0,0,0,1,1,1,1])

        let queue = BoundedQueue<Int>(capacity: 6)
        precondition(queue.push(1, limit: 2) && queue.push(2, limit: 2))
        precondition(!queue.push(3, timeout: 0.01, limit: 2), "File backpressure must retain old frames")
        precondition(queue.tryPop() == 1 && queue.push(3, limit: 2))
        precondition(queue.tryPop() == 2 && queue.tryPop() == 3)
        print("PASS: file startup/rebuffer/EOF gate, 4K memory budget, ordered cache-reusing workers and lossless queue backpressure")
    }
}
