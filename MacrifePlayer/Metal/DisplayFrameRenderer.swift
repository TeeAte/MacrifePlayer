// DisplayFrameRenderer.swift
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

final class DisplayFrameRenderer {
        init(device: MTLDevice) throws {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func clearAnime4KModeSwitchState(reason: String) {
        // 无返回值
    }
    func copyTextureForDisplay(_ x0: MTLTexture, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        return nil
    }
    func logDecodedColorOnce(_ x0: String, resolved: VideoFrameColorPipeline.ResolvedFrameColor) {
        // 无返回值
    }
    func makeOffscreenSourceTexture(pixelBuffer: CVBuffer, commandBuffer: MTLCommandBuffer) -> (texture: MTLTexture, width: Int, height: Int)? {
        return nil
    }
    func makeSubtitleTexture(from: SubtitleBitmap) -> MTLTexture? {
        return nil
    }
    func beginPlaybackTimeline(generation: Int?, reason: String, clearFrame: Bool) {
        // 无返回值
    }
    func currentSubtitleRenderSize(drawableSize: CGSize) -> CGSize {
        return .zero
    }
    func update(frame: DisplayFrame) {
        // 无返回值
    }
    func update(frame: DisplayFrame, generation: Int) {
        // 无返回值
    }
}
