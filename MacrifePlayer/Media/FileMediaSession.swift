// FileMediaSession.swift
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

final class FileMediaSession {
        init(url: URL) {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func makeAudioPlayback(trackIndex: Int?, startSeconds: Double) -> AudioPlayback {
        fatalError("Not implemented")
    }
    func makeVideoReader(startSeconds: Double) throws -> RIFEFrameReader {
        fatalError("Not implemented")
    }

    // MARK: - 嵌套类型 sharedPipeline（fileprivate）
        struct sharedPipeline {
        // 占位类型
    }
}
