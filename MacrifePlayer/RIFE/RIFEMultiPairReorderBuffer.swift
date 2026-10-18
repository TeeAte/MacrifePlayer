// RIFEMultiPairReorderBuffer.swift
// Macrife Player

import Foundation
import AppKit
import Metal
import MetalKit
import CoreMedia
import CoreVideo
import AVFoundation
import CoreML
import CoreImage
import QuartzCore

final class RIFEMultiPairReorderBuffer {
        init(multiplier: Int) {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func continuousReadyPairCountLocked(from: Int64, limit: Int) -> Int {
        return 0
    }
    func intermediateReady(pair: Int64, slot: Int) -> Bool {
        return false
    }
    func markIntermediateFailed(pair: Int64, slot: Int) {
        // 无返回值
    }
    func markPairSubmitted(_ x0: Int64) {
        // 无返回值
    }
    func setIntermediate(pair: Int64, slot: Int, _ x2: TimedDisplayFrame) {
        // 无返回值
    }
    func snapshot(from: Int64, limit: Int) -> RIFEFrameBufferStats {
        fatalError("Not implemented")
    }
    func stats() -> (submitted: Int64, done: Int64, failed: Int64, decodeFinished: Bool) {
        fatalError("Not implemented")
    }
    func updateDisplayPair(_ x0: Int64) {
        // 无返回值
    }
}
