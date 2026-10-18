// 类型引用：FFAudioStats 与 FFDemuxPacket
//       这两个是 app 自带的 C 结构体（非 FFmpeg 公共头中的类型），
//       原始定义在随 build 丢弃的 bridging header 里，字段布局未恢复。
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

// TODO: 字段定义
struct FFAudioStats {
    var reserved: UInt64 = 0
}

struct FFDemuxPacket {
    var reserved: UInt64 = 0
}
