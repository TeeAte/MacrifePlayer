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

    // MARK: - dev-only：解码时间轴探针

    #if USE_FFMPEG

    /// 无窗口验证「解码输出顺序 + 时间轴」的诊断入口。
    ///
    /// 只在环境变量在场时运行，跑完直接 exit(0)，生产路径完全不受影响：
    ///     MP_PROBE_DECODE=/path/movie.mp4 MP_PROBE_FRAMES=12 ./Macrife\ Player
    ///     MP_PROBE_DECODE=... MP_PROBE_AT=60 MP_PROBE_DUMP=/tmp/probe ./Macrife\ Player
    ///     MP_PROBE_DECODE=... MP_PROBE_RAW=1   # 关掉时间轴重建，打出容器原始 pts
    ///
    /// 每帧输出一行 `PROBE idx=<序号> pts=<秒>`：
    ///   · 序号是解码输出顺序（= 显示序）；
    ///   · `MP_PROBE_RAW=1` 时 pts 是容器原样给的时间戳，用来和 ffprobe 对齐取证；
    ///   · 默认走的是生产路径（含时间轴重建），pts 应当严格单调。
    static func runDecodeProbeIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["MP_PROBE_DECODE"], !path.isEmpty else { return }

        let frameLimit = Int(env["MP_PROBE_FRAMES"] ?? "") ?? 12
        let seekTo = Double(env["MP_PROBE_AT"] ?? "")
        let dumpDir = env["MP_PROBE_DUMP"].flatMap { $0.isEmpty ? nil : $0 }
        let dumpFrom = Int(env["MP_PROBE_DUMP_FROM"] ?? "") ?? 0
        let forceRaw = (env["MP_PROBE_RAW"] == "1")

        func out(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        func bail(_ s: String) -> Never { out("PROBE 失败: " + s); exit(2) }

        let url = URL(fileURLWithPath: path)
        guard let src = try? MediaFileSource(url: url) else { bail("打不开 \(path)") }
        guard src.hasVideo, let par = src.codecParameters(at: src.videoStreamIndex) else { bail("没有视频流") }

        out("PROBE 文件=\(url.lastPathComponent) 视频流=\(src.videoStreamIndex) fps=\(src.videoFrameRate) 时间基=\(src.videoTimeBase.num)/\(src.videoTimeBase.den)")
        out("PROBE 容器缺呈现序=\(src.videoTimestampsAreDecodeOrder) 强制原始pts=\(forceRaw)")

        guard let dec = try? VideoDecoder(parameters: par,
                                          timeBase: src.videoTimeBase,
                                          useHardware: PlaybackSettings.shared.decodeMode == .hardware,
                                          frameRate: src.videoFrameRate,
                                          isMTSOrInterlacedHint: src.isMTSOrInterlacedHint,
                                          rebuildTimeline: forceRaw ? false : src.videoTimestampsAreDecodeOrder)
        else { bail("建解码器失败") }
        out("PROBE 解码器=\(dec.codecName) 硬解=\(dec.isHardwareAccelerated) 时间轴重建=\(dec.rebuildTimeline)")

        if let t = seekTo {
            let rc = src.seek(to: t)
            dec.reset()
            out("PROBE seek \(t)s → rc=\(rc)")
        }

        if let dir = dumpDir {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        var emitted = 0
        while emitted < frameLimit {
            guard let item = src.readNextPacket() else { break }
            if item.index != src.videoStreamIndex { continue }
            guard let frames = try? dec.decode(packet: item.packet) else { break }
            for f in frames {
                out(String(format: "PROBE idx=%d pts=%.4f", emitted, f.pts))
                if let dir = dumpDir, emitted >= dumpFrom {
                    dump(f.pixelBuffer, to: String(format: "%@/f%03d.png", dir, emitted))
                }
                emitted += 1
                if emitted >= frameLimit { break }
            }
        }
        // 冲刷解码器，把重排序里残留的帧也吐出来（不影响上面已判定的一致性）
        _ = try? dec.decode(packet: nil)
        out("PROBE 完成，输出 \(emitted) 帧")
        exit(0)
    }

    private static func dump(_ pixelBuffer: CVPixelBuffer, to path: String) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent),
              let destination = CGImageDestinationCreateWithURL(
                  URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        _ = CGImageDestinationFinalize(destination)
    }

    #else

    static func runDecodeProbeIfRequested() {}

    #endif
}
