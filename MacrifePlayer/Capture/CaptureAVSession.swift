// CaptureAVSession.swift
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

final class CaptureAVSession {
        init(source: CaptureDeviceSource) {
        // TODO: Not implemented
    }
    // MARK: - 方法
    func actualCaptureMismatch(threshold: Double) -> Bool {
        return false
    }
    func applyVideoFormat(_ x0: AVCaptureDevice.Format, on: AVCaptureDevice, requestedFPS: Double, reason: String) throws -> UInt32 {
        return 0
    }
    func applyVideoOutputConnectionFrameRate(reason: String) {
        // 无返回值
    }
    func configureSession() throws {
        // 无返回值
    }
    func configureVideoDevice(_ x0: AVCaptureDevice, reason: String) throws -> UInt32 {
        return 0
    }
    func convertAudio(_ x0: CMSampleBuffer) {
        // 无返回值
    }
    func logActualCaptureState(reason: String) {
        // 无返回值
    }
    func pushAudio(left: [Float], right: [Float], pts: Double) {
        // 无返回值
    }
    func pushVideo(_ x0: RIFEVideoFrame) {
        // 无返回值
    }
    func repairFrameRateAfterStartIfNeeded() {
        // 无返回值
    }
    func retryRankedFormatsAfterStart() {
        // 无返回值
    }
    func audioStats() -> FFAudioStats {
        fatalError("Not implemented")
    }
    func nextVideoFrame(timeout: Double?) -> RIFEVideoFrame? {
        return nil
    }
    func readAudio(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, maxFrames: Int) -> AudioReadResult? {
        return nil
    }
    func start() throws {
        // 无返回值
    }
    func stop() {
        // 无返回值
    }
}
