// NetworkResilientAudioFrameReader.swift
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

final class NetworkResilientAudioFrameReader {
    // MARK: - 方法
    func openReplacement(resetAttempts: Bool) throws {
        // 无返回值
    }
    func reconnectAfterReadEnded() -> Bool {
        return false
    }
    func close() {
        // 无返回值
    }
    func readInto(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, maxFrames: Int) throws -> AudioReadResult? {
        return nil
    }
    func requestCancel() {
        // 无返回值
    }
    func stats() -> FFAudioStats? {
        return nil
    }
}
