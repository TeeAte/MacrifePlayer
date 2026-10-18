// TrackManager.swift
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

final class TrackManager {
    // MARK: - 属性
    var audioTracks: [TrackInfo] = []
    var subtitleTracks: [TrackInfo] = []
    var videoTracks: [TrackInfo] = []
    // MARK: - 方法
    func loadTracks() -> Bool {
        return false
    }
}
