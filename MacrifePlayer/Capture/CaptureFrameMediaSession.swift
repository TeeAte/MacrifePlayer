// CaptureFrameMediaSession.swift
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

final class CaptureFrameMediaSession {
        init(source: MediaSource) {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func sharedCaptureSession(`for`: CaptureDeviceSource) throws -> CaptureAVSession {
        fatalError("Not implemented")
    }
    func sharedScreenCaptureSession(`for`: ScreenCaptureSource) throws -> ScreenCaptureSession {
        fatalError("Not implemented")
    }
    func close() {
        // 无返回值
    }
}
