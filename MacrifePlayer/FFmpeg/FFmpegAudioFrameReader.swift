// FFmpegAudioFrameReader.swift
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

final class FFmpegAudioFrameReader {
    // MARK: - 方法
    func `open`() throws {
        // 无返回值
    }
    func readInto(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, maxFrames: Int) throws -> AudioReadResult? {
        return nil
    }
    func stats() -> FFAudioStats? {
        return nil
    }
}
