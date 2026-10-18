// RIFEFastMetal.swift
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

final class RIFEFastMetal {
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
    func addFlowInto(flow: FastTensor, fd: MLMultiArray, output: FastTensor) throws {
        // 无返回值
    }
    func bgraPixelBufferToNCHWInto(_ x0: CVBuffer, width: Int, height: Int, paddedHeight: Int, output: FastTensor) throws {
        // 无返回值
    }
    func bgraPixelBufferToNCHWResizedInto(_ x0: CVBuffer, outputWidth: Int, outputHeight: Int, paddedHeight: Int, output: FastTensor) throws {
        // 无返回值
    }
    func buildBlock123WarpConcatHalfInto(img0: FastTensor, img1: FastTensor, f0: MLMultiArray, f1: MLMultiArray, flow: FastTensor, mask: MLMultiArray, feat: MLMultiArray, timestep: Float, output: FastHalfTensor) throws {
        // 无返回值
    }
    func buildBlock123WarpConcatInto(img0: FastTensor, img1: FastTensor, f0: MLMultiArray, f1: MLMultiArray, flow: FastTensor, mask: MLMultiArray, feat: MLMultiArray, timestep: Float, output: FastTensor) throws {
        // 无返回值
    }
    func finalBlendWarpInto(img0: FastTensor, img1: FastTensor, flow: FastTensor, mask: MLMultiArray, output: FastTensor) throws {
        // 无返回值
    }
    func makeHalfTensor(shape: [Int]) throws -> FastHalfTensor {
        fatalError("Not implemented")
    }
    func makeTensor(shape: [Int]) throws -> FastTensor {
        fatalError("Not implemented")
    }
    func nv12PixelBufferToNCHWAutoInto(_ x0: CVBuffer, outputWidth: Int, outputHeight: Int, paddedHeight: Int, output: FastTensor) throws {
        // 无返回值
    }
    func packed422PixelBufferToNCHWAutoInto(_ x0: CVBuffer, outputWidth: Int, outputHeight: Int, paddedHeight: Int, output: FastTensor, pipeline: MTLComputePipelineState, label: String) throws {
        // 无返回值
    }
    func toFloatTensorInto(_ x0: MLMultiArray, output: FastTensor) throws {
        // 无返回值
    }
}
