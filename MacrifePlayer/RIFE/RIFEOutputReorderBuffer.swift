// RIFEOutputReorderBuffer.swift
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

final class RIFEOutputReorderBuffer {
        init() {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func readyCountLocked(from: Int64, limit: Int) -> Int {
        return 0
    }
    func markFailed(_ x0: Int64) {
        // 无返回值
    }
    func setFrame(_ x0: Int64, _ x1: TimedDisplayFrame) {
        // 无返回值
    }
    func snapshot(from: Int64, limit: Int) -> RIFEFrameBufferStats {
        fatalError("Not implemented")
    }
    func updateDisplayIndex(_ x0: Int64) {
        // 无返回值
    }
}
