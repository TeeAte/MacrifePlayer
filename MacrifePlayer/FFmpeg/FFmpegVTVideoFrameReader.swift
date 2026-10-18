// FFmpegVTVideoFrameReader.swift
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

final class FFmpegVTVideoFrameReader {
        init(input: String, sourceURL: URL?, startSeconds: Double) throws {
        // TODO: Not implemented
    }
        init(input: String, sourceURL: URL?, startSeconds: Double, distributor: FFmpegPacketDistributor, videoStreamIndex: Int?, packetQueuePolicy: VideoPacketQueuePolicy) throws {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func decodeOnePacket() -> Bool {
        return false
    }
    func handleDecodeError(_ x0: Int32) {
        // 无返回值
    }
    func makeCMTime(_ x0: Int64) -> CMTime {
        return .zero
    }
    func makeSampleBuffer(packet: MediaPacket) -> CMSampleBuffer? {
        return nil
    }
    func makeSampleBuffer(packet: FFDemuxPacket, dataPtr: UnsafeMutablePointer<UInt8>) -> CMSampleBuffer? {
        return nil
    }
    func popDisplayableFrame(timeout: Double, minBuffered: Int) -> RIFEVideoFrame? {
        return nil
    }
    func recoverVideoToolboxIfNeeded() {
        // 无返回值
    }
    func recreateSessionAfterDecodeFailure() {
        // 无返回值
    }
    func startPacketDistributorIfNeeded() {
        // 无返回值
    }
    func close() {
        // 无返回值
    }
    func nextFrame() -> RIFEVideoFrame? {
        return nil
    }
}
