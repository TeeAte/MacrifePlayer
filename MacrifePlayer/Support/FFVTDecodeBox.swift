// FFVTDecodeBox.swift
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

final class FFVTDecodeBox {
    // MARK: - 方法
    func pop(timeout: Double, minBuffered: Int) -> FFVTDecodedFrame? {
        return nil
    }
    func push(_ x0: CVBuffer, pts: CMTime) {
        // 无返回值
    }
    func shouldLogCallbackError() -> Bool {
        return false
    }
}
