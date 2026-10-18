// AudioPlayback.swift
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

final class AudioPlayback {
    // MARK: - 方法
    func configureOutputFormatFromReader() {
        // 无返回值
    }
    func readLoop(generation: UInt64, displayStartSeconds: Double) {
        // 无返回值
    }
    func startEngineWithRecovery(context: String) -> Bool {
        return false
    }
    func startReader(generation: UInt64, displayStartSeconds: Double) {
        // 无返回值
    }
    func currentTimeSeconds() -> Double? {
        return nil
    }
    func pause() {
        // 无返回值
    }
    func play(from: Double, delay: Double) {
        // 无返回值
    }
    func prepareReader() {
        // 无返回值
    }
    func resume() {
        // 无返回值
    }
    func stopForSeek() {
        // 无返回值
    }
}
