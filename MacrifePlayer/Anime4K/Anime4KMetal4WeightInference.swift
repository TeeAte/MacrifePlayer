// Anime4KMetal4WeightInference.swift
// Macrife Player · Phase 5 Anime4K 权重推理实现

import Foundation
import Metal

final class Anime4KMetal4WeightInference {

    private let device: MTLDevice
    private let weightsData: Data
    private let metadata: [String: Any]?

    enum GraphKind {
        case smallOrMedium
        case veryLarge
    }

    struct LayerWeights {
        var offset: Int = 0
        var size: Int = 0
    }

    init(device: MTLDevice, weightsFileURL: URL, metadataURL: URL) throws {
        self.device = device
        self.weightsData = try Data(contentsOf: weightsFileURL)
        if let metaData = try? Data(contentsOf: metadataURL),
           let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            self.metadata = json
        } else {
            self.metadata = nil
        }
    }

    func acquireFrameSlot(commandBuffer: MTLCommandBuffer) throws -> Int {
        return 0
    }

    func encodeDedicatedSmallOrMedium(commandBuffer: MTLCommandBuffer, inputTexture: MTLTexture) throws -> MTLTexture {
        return inputTexture
    }

    func encodeDedicatedVL(commandBuffer: MTLCommandBuffer, inputTexture: MTLTexture) throws -> MTLTexture {
        return inputTexture
    }

    func loadLayerWeights(layerIndex: Int) throws -> LayerWeights {
        return LayerWeights(offset: 0, size: weightsData.count)
    }

    func makeOutputTextureLike(_ texture: MTLTexture, slot: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let out = device.makeTexture(descriptor: desc) else {
            throw Anime4KError.pipelineCreationFailed("无法为 slot \(slot) 创建输出纹理")
        }
        return out
    }

    func makePrivateBufferFromWeights(offset: Int, size: Int, label: String) throws -> MTLBuffer {
        guard offset + size <= weightsData.count else {
            throw Anime4KError.invalidWeightFormat("偏移越界")
        }
        let sub = weightsData.subdata(in: offset..<(offset + size))
        guard let buf = sub.withUnsafeBytes({ ptr in
            device.makeBuffer(bytes: ptr.baseAddress!, length: size, options: .storageModeShared)
        }) else {
            throw Anime4KError.pipelineCreationFailed("无法为 \(label) 创建 MTLBuffer")
        }
        buf.label = label
        return buf
    }

    func makeTensor(width: Int, height: Int, channels: Int, slot: Int) throws -> MTLBuffer {
        let length = width * height * channels * MemoryLayout<Float>.size
        guard let buf = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw Anime4KError.pipelineCreationFailed("无法分配张量缓冲区")
        }
        return buf
    }

    func resolveGraphKindLocked() -> GraphKind {
        if let name = metadata?["shader"] as? String, name.contains("VL") {
            return .veryLarge
        }
        return .smallOrMedium
    }

    func invalidateTimeline(reason: String) {}
}
