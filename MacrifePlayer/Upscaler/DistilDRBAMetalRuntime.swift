// DistilDRBAMetalRuntime.swift
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

final class DistilDRBAMetalRuntime {
        init(models: DistilDRBACoreMLModels) throws {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func add(_ x0: MLMultiArray, _ x1: MLMultiArray, workspaceKey: String) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func buffer(`for`: MLMultiArray) throws -> MTLBuffer {
        fatalError("Not implemented")
    }
    func contiguousIfNeeded(_ x0: MLMultiArray, label: String, workspaceKey: String) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func dumpDiagnosticTriplet(centerPixelBuffer: CVBuffer, generatedTexture: MTLTexture, nextPixelBuffer: CVBuffer, sequence: Int64, timestep: Float) throws -> URL {
        fatalError("Not implemented")
    }
    func finalBlendTexture(img0: MLMultiArray, img1: MLMultiArray, flow: MLMultiArray, mask: MLMultiArray, canvasWidth: Int, canvasHeight: Int, outputWidth: Int, outputHeight: Int) throws -> MTLTexture {
        fatalError("Not implemented")
    }
    func floatBuffer(`for`: MLMultiArray) throws -> MTLBuffer {
        fatalError("Not implemented")
    }
    func makeBGRAImageTensor(pixelBuffer: CVBuffer, canvasWidth: Int, canvasHeight: Int, contentHeight: Int, workspaceKey: String) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeBGRATexture(pixelBuffer: CVBuffer) -> MTLTexture? {
        return nil
    }
    func makeImageTensor(pixelBuffer: CVBuffer, canvasWidth: Int, canvasHeight: Int, contentHeight: Int, workspaceKey: String) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeNV12ImageTensor(pixelBuffer: CVBuffer, canvasWidth: Int, canvasHeight: Int, contentHeight: Int, workspaceKey: String) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeNV12Textures(pixelBuffer: CVBuffer, is10Bit: Bool) -> (MTLTexture, MTLTexture)? {
        return nil
    }
    func maybeDumpDiagnosticTriplet(generatedTexture: MTLTexture, centerPixelBuffer: CVBuffer, nextPixelBuffer: CVBuffer, timestep: Float) {
        // 无返回值
    }
    func resize(_ x0: MLMultiArray, channels: Int, width: Int, height: Int, valueScale: Float, workspaceKey: String) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func run(_ x0: MTLComputePipelineState, grid: MTLSize, group: MTLSize, encode: (MTLComputeCommandEncoder) throws -> ()) throws {
        // 无返回值
    }
    func runHead(image: MLMultiArray, workspaceKey: String) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func interpolate(request: TripletFrameInterpolationRequest) throws -> DisplayFrame {
        fatalError("Not implemented")
    }

    // MARK: - 嵌套类型 ReferenceCapture（fileprivate）
        final class ReferenceCapture {
                init(descriptor: FrameInterpolationModelDescriptor, timestep: Float) throws {
            // TODO: Not implemented
        }
        // MARK: - 方法
        func dump(_ x0: MLMultiArray, name: String) throws {
        // 无返回值
        }
        func finish(extra: [String : Any]) throws {
        // 无返回值
        }
    }

    // MARK: - 嵌套类型 TensorStorage（fileprivate）
        final class TensorStorage {
                init(device: MTLDevice, shape: [Int], dataType: MLMultiArrayDataType) throws {
            // TODO: Not implemented
        }
    }

    // MARK: - 嵌套类型 TensorWorkspace（fileprivate）
        final class TensorWorkspace {
        // MARK: - 方法
        func buffer(`for`: MLMultiArray) -> MTLBuffer? {
        return nil
        }
        func tensor(key: String, shape: [Int], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        fatalError("Not implemented")
        }
    }
}
