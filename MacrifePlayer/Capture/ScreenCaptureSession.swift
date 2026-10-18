// ScreenCaptureSession.swift
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

final class ScreenCaptureSession {
    // MARK: - 属性
    var decodePathTitle: String = ""
        init(source: ScreenCaptureSource) {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func acceptByPTS(_ x0: Double) -> Bool {
        return false
    }
    func pollSourceWindowFrameIfNeeded() {
        // 无返回值
    }
    func pushVideo(_ x0: RIFEVideoFrame) {
        // 无返回值
    }
    func requestConfigurationResize(width: Int, height: Int, reason: String) {
        // 无返回值
    }
    func nextVideoFrame(timeout: Double?) -> RIFEVideoFrame? {
        return nil
    }
    func start() throws {
        // 无返回值
    }
    func stop() {
        // 无返回值
    }
}
