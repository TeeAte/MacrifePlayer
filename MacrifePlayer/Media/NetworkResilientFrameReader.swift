// NetworkResilientFrameReader.swift
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

final class NetworkResilientFrameReader {
    // MARK: - 方法
    func reconnectAfterReadEnded() -> Bool {
        return false
    }
    func nextFrame() -> RIFEVideoFrame? {
        return nil
    }
}
