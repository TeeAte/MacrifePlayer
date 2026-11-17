// Run with Tests/run-capture-latency-tests.sh. No camera or model package required.
import Foundation

@main
enum CaptureLatencyTests {
    static func main() {
        testNewestFramesAndCapacityChanges()
        testBlockingProducerWakesOnPop()
        testCloseWakesConsumerAndReopenClearsFrames()
        testConcurrentOverloadStaysFresh()
        testPlayoutPreservesIntermediateFrames()
        testPlayoutRecoversAfterStalls()
        testBudgetsPreserveWholeInterpolationPairs()
        testFixedRateModesDoNotBecomeDoubleRate()
        testPreferenceValuesAreNotMediaFiles()
        testFirstAIFrameGetsItsOwnAnchor()
        testLiveTimingDoesNotRetainColdStartDelay()
        testFPSReadingsSurviveAnExtraRefresh()
        testConsole30StartsImmediately()
        testConsole30PreservesPhaseAcrossDrops()
        testConsole30PassesNativeCaptureAndRestarts()
        testConsole30RepeatsCannotReplaceQueuedOriginal()
        testCaptureTimestampEpochChanges()
        testFileAndCaptureFrameContexts()
        testProcessingCostRecoversAfterColdStart()
        print("PASS: 19 capture/context regression tests")
    }

    static func testProcessingCostRecoversAfterColdStart() {
        var window = InterpolationProcessingWindow()
        window.record(0.6); window.record(0.016); window.record(0.018)
        precondition(abs(window.estimate - 0.018) < 0.000001)
        for _ in 0..<7 { window.record(0.014) }
        window.record(0.2)
        precondition(abs(window.estimate - 0.014) < 0.000001)
        let due = CapturePlayoutClock.livePresentationTime(latestPTS: 10,receivedHostTime: 20,hostTime: 20,
            sourceFPS: 30,processingSeconds: window.estimate)
        precondition(10 - due < 0.032, "A past compile spike must not permanently delay live capture")
        window.reset(); window.record(.nan)
        precondition(window.estimate == 0)
    }

    static func testFileAndCaptureFrameContexts() {
        let capture = FrameSourceContext.captureCard(transportFPS: 60, contentFPS: 30)
        let file = FrameSourceContext.videoFile(fps: 24)
        precondition(capture.sourceFPS == 30 && capture.isLive)
        precondition(file.sourceFPS == 24 && !file.isLive)
        precondition(capture.needsInterpolation(enabled: true, targetFPS: 60))
        precondition(file.needsInterpolation(enabled: true, targetFPS: 48))
        precondition(!FrameSourceContext.videoFile(fps: 60).needsInterpolation(enabled: true, targetFPS: 60))
        precondition(!capture.needsInterpolation(enabled: false, targetFPS: 60))
    }

    static func testCaptureTimestampEpochChanges() {
        var mapper = CaptureTimestampMapper()
        assert(mapper.time(sourceTime: 0, fallbackTime: 0) == nil)
        assert(mapper.time(sourceTime: .nan, fallbackTime: 0.01) == nil)
        assert(mapper.time(sourceTime: 272_000, fallbackTime: 0.02) == 0)
        assert(abs(mapper.time(sourceTime: 272_000.02, fallbackTime: 0.02)! - 0.02) < 0.00001)
        assert(mapper.time(sourceTime: .nan, fallbackTime: 0.04) == 0.04)
        assert(mapper.time(sourceTime: 1, fallbackTime: 0.06) == 0.06)
        assert(abs(mapper.time(sourceTime: 1.02, fallbackTime: 0.08)! - 0.08) < 0.00001)
        assert(mapper.time(sourceTime: 500_000, fallbackTime: 0.1) == 0.1)
        mapper.reset()
        assert(mapper.time(sourceTime: 0, fallbackTime: 0) == nil)
        assert(mapper.time(sourceTime: 500_001, fallbackTime: 0) == 0)
    }

    static func testNewestFramesAndCapacityChanges() {
        let queue = BoundedQueue<Int>(capacity: 8)
        assert(queue.pushKeepingNewest([1, 2, 3], limit: 4) == 0)
        assert(queue.pushKeepingNewest([4, 5, 6], limit: 4) == 2)
        assert(queue.tryPop() == 3)
        assert(queue.pushKeepingNewest([7], limit: 1) == 3)
        assert(queue.tryPop() == 7)
        assert(queue.pushKeepingNewest([8, 9, 10, 11], limit: 2) == 2)
        assert(queue.tryPop() == 10 && queue.tryPop() == 11)
        queue.close()
        assert(queue.pushKeepingNewest([12], limit: 1) == 1 && queue.count == 0)
    }

    static func testBlockingProducerWakesOnPop() {
        let queue = BoundedQueue<Int>(capacity: 1)
        queue.push(1)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            assert(queue.push(2, timeout: 2))
            finished.signal()
        }
        started.wait()
        Thread.sleep(forTimeInterval: 0.02)
        assert(queue.tryPop() == 1)
        assert(finished.wait(timeout: .now() + 0.5) == .success)
        assert(queue.tryPop() == 2)
    }

    static func testCloseWakesConsumerAndReopenClearsFrames() {
        let queue = BoundedQueue<Int>(capacity: 2)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            assert(queue.pop() == nil)
            finished.signal()
        }
        queue.close()
        assert(finished.wait(timeout: .now() + 0.5) == .success)
        queue.reopen()
        queue.push(1)
        queue.close()
        queue.reopen()
        assert(queue.count == 0)
        queue.push(2)
        assert(queue.pop() == 2)
    }

    static func testConcurrentOverloadStaysFresh() {
        let queue = BoundedQueue<Int>(capacity: 8)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var previous = -1
            while let value = queue.pop() {
                assert(value > previous)
                previous = value
                Thread.sleep(forTimeInterval: 0.0001)
            }
            assert(previous == 9_999)
            done.signal()
        }
        for value in 0..<10_000 {
            queue.pushKeepingNewest([value], limit: 2)
            assert(queue.count <= 2)
        }
        queue.close()
        assert(done.wait(timeout: .now() + 2) == .success)
    }

    static func testPlayoutPreservesIntermediateFrames() {
        var clock = CapturePlayoutClock()
        let step = 1.0 / 60
        let first = clock.presentationTime(hostTime: 10, nextPTS: 1, newestPTS: 1 + step,
                                          frameInterval: step, sourceInterval: 1.0 / 30)
        assert(abs(first - 1) < 0.00001)
        let half = clock.presentationTime(hostTime: 10 + step / 2, nextPTS: 1 + step,
                                         newestPTS: 1 + step, frameInterval: step, sourceInterval: 1.0 / 30)
        assert(half < 1 + step) // The AI middle frame must wait for its own display tick.
        let next = clock.presentationTime(hostTime: 10 + step, nextPTS: 1 + step,
                                         newestPTS: 1 + step, frameInterval: step, sourceInterval: 1.0 / 30)
        assert(abs(next - (1 + step)) < 0.00001)
    }

    static func testPlayoutRecoversAfterStalls() {
        var clock = CapturePlayoutClock()
        _ = clock.presentationTime(hostTime: 10, nextPTS: 1, newestPTS: 1.0167,
                                   frameInterval: 1.0 / 60, sourceInterval: 1.0 / 30)
        let recovered = clock.presentationTime(hostTime: 11, nextPTS: 1.7, newestPTS: 1.8,
                                               frameInterval: 1.0 / 60, sourceInterval: 1.0 / 30)
        assert(abs(recovered - 1.8) < 0.00001) // Recover to the newest result, never the oldest backlog.
        let afterGap = clock.presentationTime(hostTime: 11.01, nextPTS: 3, newestPTS: 3.0167,
                                              frameInterval: 1.0 / 60, sourceInterval: 1.0 / 30)
        assert(abs(afterGap - 3) < 0.00001)
        clock.reset()
        assert(clock.presentationTime(hostTime: 20, nextPTS: 0, newestPTS: 0.0167,
                                      frameInterval: 1.0 / 60, sourceInterval: 1.0 / 30) == 0)
    }

    static func testBudgetsPreserveWholeInterpolationPairs() {
        let extreme = CaptureLatencyPolicy(isExtreme: true)
        let balanced = CaptureLatencyPolicy(isExtreme: false)
        assert(extreme.maxInflightPairs == 2 && balanced.maxInflightPairs == 3)
        assert(extreme.outputCapacity(sourceFPS: 30, targetFPS: 60) == 3)
        assert(extreme.outputCapacity(sourceFPS: 30, targetFPS: 120) >= 4)
        assert(balanced.outputCapacity(sourceFPS: 24, targetFPS: 120) >= 5)
        assert(extreme.outputCapacity(sourceFPS: 60, targetFPS: 60) < balanced.outputCapacity(sourceFPS: 60, targetFPS: 60))
    }

    static func testFixedRateModesDoNotBecomeDoubleRate() {
        for sourceFPS in [24.0, 30.0, 60.0, 120.0] {
            assert(RIFERateMode.fps60.needsTimelineResample(sourceFPS: sourceFPS))
            assert(RIFERateMode.fps120.needsTimelineResample(sourceFPS: sourceFPS))
            assert(RIFERateMode.customFps.needsTimelineResample(sourceFPS: sourceFPS))
            assert(!RIFERateMode.x2.needsTimelineResample(sourceFPS: sourceFPS))
        }
        assert(!CaptureLatencyPolicy.requiresInterpolation(sourceFPS: 60, targetFPS: 60))
        assert(!CaptureLatencyPolicy.requiresInterpolation(sourceFPS: 59.94, targetFPS: 60))
        assert(CaptureLatencyPolicy.requiresInterpolation(sourceFPS: 30, targetFPS: 60))
        assert(CaptureLatencyPolicy.requiresInterpolation(sourceFPS: 60, targetFPS: 120))
    }

    static func testPreferenceValuesAreNotMediaFiles() {
        let values = DevFlag.preferenceValueURLs(in: ["player", "--capture-go", "-macrife.rifeRateMode", "fps60",
                                                     "-macrife.rifeModel", "v426", "-macrife.rifeStaticFrameSkip", "NO", "/tmp/movie.mp4"])
        assert(values.contains(URL(fileURLWithPath: "fps60").standardizedFileURL))
        assert(values.contains(URL(fileURLWithPath: "v426").standardizedFileURL))
        assert(values.contains(URL(fileURLWithPath: "NO").standardizedFileURL))
        assert(!values.contains(URL(fileURLWithPath: "/tmp/movie.mp4")))
        assert(DevFlag.preferenceValueURLs(in: ["player", "--capture-go", "/tmp/movie.mp4"]).isEmpty)
    }

    static func testFirstAIFrameGetsItsOwnAnchor() {
        var clock = CapturePlayoutClock()
        let step = 1.0 / 60
        _ = clock.presentationTime(hostTime: 10, nextPTS: 0, newestPTS: 0,
                                   frameInterval: step, sourceInterval: 1.0 / 30)
        let firstAI = clock.presentationTime(hostTime: 10.04, nextPTS: step, newestPTS: 2 * step,
                                             frameInterval: step, sourceInterval: 1.0 / 30, isInterpolated: true)
        assert(abs(firstAI - step) < 0.00001, "Do not consume the real source frame instead of the first AI middle frame")
        let sourceDue = clock.presentationTime(hostTime: 10.04 + step, nextPTS: 2 * step, newestPTS: 2 * step,
                                               frameInterval: step, sourceInterval: 1.0 / 30)
        assert(abs(sourceDue - 2 * step) < 0.00001)
    }

    static func testLiveTimingDoesNotRetainColdStartDelay() {
        let due = CapturePlayoutClock.livePresentationTime(latestPTS: 10, receivedHostTime: 100,
                                                           hostTime: 100.008, sourceFPS: 30, processingSeconds: 0.008)
        assert(due > 9.98 && due < 10, "A warmed-up fast model must recover from the initial cold-start backlog")
        let next = CapturePlayoutClock.livePresentationTime(latestPTS: 10, receivedHostTime: 100,
                                                            hostTime: 100.008 + 1.0 / 60, sourceFPS: 30, processingSeconds: 0.008)
        assert(abs(next - due - 1.0 / 60) < 0.000001)
    }

    static func testFPSReadingsSurviveAnExtraRefresh() {
        var window = FrameRateWindow()
        _ = window.sample(time: 100, presented: 0, decoded: 0)
        _ = window.sample(time: 100.5, presented: 30, decoded: 15)
        _ = window.sample(time: 101, presented: 60, decoded: 30)
        let rates = window.sample(time: 101.06, presented: 64, decoded: 32)
        assert(rates.render > 59 && rates.render < 62, "A short extra refresh must not turn steady 60fps into 67fps")
        assert(rates.decode > 29 && rates.decode < 32)
        let resetRates = window.sample(time: 102, presented: 1, decoded: 1)
        assert(resetRates.render == 0 && resetRates.decode == 0)
        window.reset()
        assert(window.sample(time: 103, presented: 100, decoded: 50).render == 0)
    }

    static func testConsole30StartsImmediately() {
        var selector = Console30FrameSelector()
        for fps in [60.0, 59.94, 60.00024] {
            selector.reset()
            for tick in 0..<120 {
                let jitter = tick % 2 == 0 ? 0.0001 : -0.0001
                let result = selector.select(pts: 10 + Double(tick) / fps + jitter, captureFPS: fps, enabled: true)
                assert(result.keep == (tick % 2 == 0), "Keep the first tick immediately, without a detection window")
                assert(result.contentFPS == fps / 2)
            }
        }
    }

    static func testConsole30PreservesPhaseAcrossDrops() {
        var selector = Console30FrameSelector()
        for tick in [0, 1, 2, 4, 5, 6, 9, 10, 11, 12] {
            let result = selector.select(pts: Double(tick) / 60, captureFPS: 60, enabled: true)
            assert(result.keep == (tick % 2 == 0), "A missing callback must not reverse the selected 2:2 phase")
        }
        assert(!selector.select(pts: 12.0 / 60, captureFPS: 60, enabled: true).keep)
    }

    static func testConsole30PassesNativeCaptureAndRestarts() {
        var selector = Console30FrameSelector()
        for enabled in [false, true] {
            for fps in [24.0, 30, 120] {
                let result = selector.select(pts: 1, captureFPS: fps, enabled: enabled)
                assert(result.keep && result.contentFPS == fps)
            }
        }
        assert(selector.select(pts: 3, captureFPS: 60, enabled: true).keep)
        assert(!selector.select(pts: 3 + 1.0 / 60, captureFPS: 60, enabled: true).keep)
        assert(selector.select(pts: 0, captureFPS: 60, enabled: true).keep)
        assert(selector.select(pts: 5, captureFPS: 60, enabled: true).keep)
        assert(selector.select(pts: 5 + 1.0 / 60, captureFPS: 60, enabled: false).keep)
        assert(selector.select(pts: 5 + 2.0 / 60, captureFPS: 60, enabled: true).keep)
    }

    static func testConsole30RepeatsCannotReplaceQueuedOriginal() {
        var selector = Console30FrameSelector()
        let queue = BoundedQueue<Int>(capacity: 1)
        for tick in 0..<120 {
            if selector.select(pts: Double(tick) / 60, captureFPS: 60, enabled: true).keep {
                queue.pushKeepingNewest([tick], limit: 1)
            }
            // Model finishes after the repeated copy has arrived.
            if tick % 4 == 3 { assert(queue.tryPop() == tick - 1) }
        }
    }
}
