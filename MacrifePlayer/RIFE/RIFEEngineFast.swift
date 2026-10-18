// RIFEEngineFast.swift
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

final class RIFEEngineFast {
        init(modelDir: String) throws {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func modelContentHeight(inputWidth: Int, inputHeight: Int) -> Int {
        return 0
    }
    func upscaleMiddleTensorToOriginalFrame(_ x0: FastTensor, frame0: CVBuffer) throws -> DisplayFrame {
        fatalError("Not implemented")
    }
    func interpolateFramePooled(frame0: CVBuffer, frame1: CVBuffer, timestep: Float) throws -> DisplayFrame {
        fatalError("Not implemented")
    }
}
