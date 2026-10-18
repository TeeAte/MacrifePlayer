//  FrameDumper.swift
//  MetalPlayer 重建工程 —— Phase 1 诊断工具（dev-only）
//
//  作用：把「引擎判定该上屏的第一帧」导出成 PNG。
//
//  为什么需要它：播放器的 bug 大多长这样 —— 「窗口是黑的」，但日志里
//  解码、时钟、渲染三条链路全都正常。不看一眼像素，就分不清是
//  「没解出帧」「时钟没走」还是「画面全黑」。
//
//  启用方式（编译进来但默认不生效，只认环境变量）：
//      MP_DUMP_FRAME=/tmp/frame.png ./MetalPlayer
//      MP_DUMP_FRAME=/tmp/after_seek.png MP_DUMP_FRAME_PTS=5 ./MetalPlayer
//  第二个变量指定「要导出 pts ≥ N 秒的第一帧」，用来验证 seek 之后画面是否正确。
//
//  走的是 CIImage(cvPixelBuffer:)：它会读像素缓冲上的色彩附件自己选矩阵，
//  所以导出图 == 上屏图（同一条 NV12 数据源），只是绕开了 Metal ——
//  正好可以把「解码问题」和「渲染问题」分开看。

import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers

enum FrameDumper {

    private static let lock = NSLock()
    private static var alreadyDumped = false

    /// 目标 pts（秒）。默认 0 = 导出第一帧。
    private static let targetPTS: Double = {
        guard let raw = ProcessInfo.processInfo.environment["MP_DUMP_FRAME_PTS"],
              let value = Double(raw) else { return 0 }
        return value
    }()

    /// 每个进程只导出一次（pts 达到目标的第一帧）。
    static func dumpIfRequested(_ frame: DecodedVideoFrame) {
        guard let path = ProcessInfo.processInfo.environment["MP_DUMP_FRAME"],
              !path.isEmpty else { return }
        guard frame.pts >= targetPTS else { return }

        lock.lock()
        if alreadyDumped { lock.unlock(); return }
        alreadyDumped = true
        lock.unlock()

        let pixelBuffer = frame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            log("导出失败：CIContext 无法生成 CGImage")
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            log("导出失败：无法创建 \(path)")
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            log("导出失败：写入 \(path) 出错")
            return
        }
        log("首帧已导出 → \(path) (\(width)x\(height), pts=\(String(format: "%.3f", frame.pts))s, "
            + "矩阵=\(frame.isBT709 ? "BT.709" : "BT.601"))")
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[FrameDumper] \(message)\n".utf8))
    }
}
