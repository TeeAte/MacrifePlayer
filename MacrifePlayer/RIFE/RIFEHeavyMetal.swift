// RIFEHeavyMetal.swift
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

final class RIFEHeavyMetal {
        init() throws {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func bufferFromMLArray(_ x0: MLMultiArray) throws -> MTLBuffer {
        fatalError("Not implemented")
    }
    func makeBGRATexture(from: CVBuffer) -> MTLTexture? {
        return nil
    }
    func addFlowInto(flow: RIFEHeavyTensor, fd: MLMultiArray, output: RIFEHeavyTensor) throws {
        // 无返回值
    }
    func bgraPixelBufferToNCHWInto(_ x0: CVBuffer, width: Int, height: Int, paddedHeight: Int, output: RIFEHeavyTensor) throws {
        // 无返回值
    }
    func bgraPixelBufferToNCHWResizedInto(_ x0: CVBuffer, outputWidth: Int, outputHeight: Int, paddedHeight: Int, output: RIFEHeavyTensor) throws {
        // 无返回值
    }
    func finalBlendWarpInto(img0: RIFEHeavyTensor, img1: RIFEHeavyTensor, flow: RIFEHeavyTensor, mask: MLMultiArray, output: RIFEHeavyTensor) throws {
        // 无返回值
    }
    func makeHalfTensor(shape: [Int]) throws -> RIFEHeavyHalfTensor {
        fatalError("Not implemented")
    }
    func makeTensor(shape: [Int]) throws -> RIFEHeavyTensor {
        fatalError("Not implemented")
    }
    func nv12PixelBufferToNCHWAutoInto(_ x0: CVBuffer, outputWidth: Int, outputHeight: Int, paddedHeight: Int, output: RIFEHeavyTensor) throws {
        // 无返回值
    }
    func packed422PixelBufferToNCHWAutoInto(_ x0: CVBuffer, outputWidth: Int, outputHeight: Int, paddedHeight: Int, output: RIFEHeavyTensor, pipeline: MTLComputePipelineState, label: String) throws {
        // 无返回值
    }
    func toFloatTensorInto(_ x0: MLMultiArray, output: RIFEHeavyTensor) throws {
        // 无返回值
    }
}
