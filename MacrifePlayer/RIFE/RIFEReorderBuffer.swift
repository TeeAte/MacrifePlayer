// RIFEReorderBuffer.swift
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

final class RIFEReorderBuffer {
        init() {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func continuousMiddleReadyCountLocked(from: Int64, limit: Int) -> Int {
        return 0
    }
    func markMiddleFailed(_ x0: Int64) {
        // 无返回值
    }
    func setMiddle(_ x0: Int64, _ x1: TimedDisplayFrame) {
        // 无返回值
    }
    func stats() -> (submitted: Int64, done: Int64, failed: Int64, decodeFinished: Bool) {
        fatalError("Not implemented")
    }
    func updateDisplayPair(_ x0: Int64) {
        // 无返回值
    }
}
