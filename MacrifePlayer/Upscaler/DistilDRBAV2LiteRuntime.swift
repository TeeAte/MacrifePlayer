// DistilDRBAV2LiteRuntime.swift
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

final class DistilDRBAV2LiteRuntime {
        init(models: DistilDRBAV2LiteCoreMLModels) throws {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func beginWorkspaceFrame() {
        // 无返回值
    }
    func buffer(`for`: MLMultiArray) throws -> MTLBuffer {
        fatalError("Not implemented")
    }
    func clearTailIfNeeded(_ x0: MLMultiArray, canvasWidth: Int, canvasHeight: Int, contentHeight: Int) throws {
        // 无返回值
    }
    func floatBuffer(`for`: MLMultiArray) throws -> MTLBuffer {
        fatalError("Not implemented")
    }
    func flushPendingMetal() throws {
        // 无返回值
    }
    func makeBGRAImageTensor(pixelBuffer: CVBuffer, canvasWidth: Int, canvasHeight: Int, contentHeight: Int) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeBGRATexture(pixelBuffer: CVBuffer) -> MTLTexture? {
        return nil
    }
    func makeCanonicalContiguousCopy(of: MLMultiArray) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeFloatArray(shape: [Int]) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeHalfArray(shape: [Int]) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeNV12ImageTensor(pixelBuffer: CVBuffer, canvasWidth: Int, canvasHeight: Int, contentHeight: Int) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func makeNV12Textures(pixelBuffer: CVBuffer, is10Bit: Bool) -> (MTLTexture, MTLTexture)? {
        return nil
    }
    func resize(_ x0: MLMultiArray, channels: Int, width: Int, height: Int, valueScale: Float) throws -> MLMultiArray {
        fatalError("Not implemented")
    }
    func runModel(_ x0: MLModel, inputs: [String : MLMultiArray]) throws -> [String : MLMultiArray] {
        return [:]
    }
    func interpolate(request: TripletFrameInterpolationRequest) throws -> DisplayFrame {
        fatalError("Not implemented")
    }

    // MARK: - 嵌套类型 ReferenceCapture（fileprivate）
        final class ReferenceCapture {
                init(descriptor: FrameInterpolationModelDescriptor, modelDir: String, timestep: Float) throws {
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
}
