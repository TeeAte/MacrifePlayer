//  BitmapSubtitleRenderer.swift
//  MacrifePlayer —— 图形位图字幕（PGS / VobSub / DVB）专用渲染器

import Foundation

final class BitmapSubtitleRenderer: SubtitleRenderable {

    struct Cue {
        let id: Int
        let start: Double
        var end: Double
        let canvasWidth: Int
        let canvasHeight: Int
        let rects: [SubtitleDecoder.BitmapSubtitleRect]
    }

    private let lock = NSLock()
    private var cues: [Cue] = []
    private var nextCueId = 1
    private var activeCueId: Int? = nil

    /// 复用缓冲：仅在尺寸变化时重分配，避免每帧分配 30MB+ 数组导致严重卡顿
    private var scratch: [UInt8] = []
    private var frameWidth = 0
    private var frameHeight = 0

    /// 上一帧绘制的真实脏区，下次合成前清零该区域并与新脏区求并集
    private var lastDrawnRect = SubtitleDirtyRect.empty

    /// seek 或 track 重置后，下一帧强制要求输出一张擦除位图
    private var needsClearOnNextRender = true

    init() {}

    func resetTrack() {
        lock.lock()
        defer { lock.unlock() }
        cues.removeAll()
        activeCueId = nil
        needsClearOnNextRender = true
    }

    /// 解封装线程喂入一个解码后的位图字幕块
    func add(decoded: SubtitleDecoder.DecodedBitmapSubtitle, canvasSize: (width: Int, height: Int)) {
        lock.lock()
        defer { lock.unlock() }

        // 清屏包处理：PGS 的清屏包可能发给所有前面未闭合的 cue
        if decoded.isClear {
            for i in cues.indices {
                if cues[i].end > decoded.start {
                    cues[i].end = decoded.start
                }
            }
            return
        }

        guard !decoded.rects.isEmpty else { return }

        // 对前一个还在悬空的 cue 进行合理截断，避免前后两句对白无限重叠
        for i in cues.indices {
            if cues[i].end > decoded.start {
                cues[i].end = decoded.start
            }
        }

        // 默认保底时长：如果未给出有效 duration，设为保底 7.0 秒，杜绝因漏掉清屏包导致字幕永久卡死在屏幕上
        let maxWatchdogDuration: Double = 7.0
        let effectiveEnd = (decoded.end.isFinite && decoded.end > decoded.start)
            ? min(decoded.end, decoded.start + 12.0)
            : (decoded.start + maxWatchdogDuration)

        let cue = Cue(id: nextCueId,
                      start: decoded.start,
                      end: effectiveEnd,
                      canvasWidth: canvasSize.width,
                      canvasHeight: canvasSize.height,
                      rects: decoded.rects)
        nextCueId += 1
        cues.append(cue)

        // 防止 cues 数组无限增长（如长时间播放），裁剪掉早于当前 30 秒以前且已经失效的 cue
        if cues.count > 100 {
            let cutoff = decoded.start - 30.0
            cues.removeAll(where: { $0.end < cutoff })
        }
    }

    func render(at time: Double, width: Int, height: Int) -> SubtitleBitmap? {
        guard width > 0, height > 0 else { return nil }

        lock.lock()
        defer { lock.unlock() }

        ensureScratch(width: width, height: height)

        // 查找命中当前时刻的 cue，优先取最晚开始的那条有效字幕
        let active = cues.last(where: { time >= $0.start && time < $0.end })

        if let cue = active {
            if activeCueId == cue.id && !needsClearOnNextRender {
                // 内容与上一帧相同，无需重新上传 Metal 纹理
                return nil
            }
            activeCueId = cue.id
            needsClearOnNextRender = false
            return compose(cue: cue, targetWidth: width, targetHeight: height)
        } else {
            // 当前时刻没有有效字幕
            if activeCueId != nil || needsClearOnNextRender || !lastDrawnRect.isEmpty {
                activeCueId = nil
                needsClearOnNextRender = false
                return erasePreviousFrame(width: width, height: height)
            }
            return nil
        }
    }

    func snapshot(at time: Double, width: Int, height: Int) -> SubtitleBitmap? {
        lock.lock()
        defer { lock.unlock() }

        ensureScratch(width: width, height: height)
        if let cue = cues.last(where: { time >= $0.start && time < $0.end }) {
            return compose(cue: cue, targetWidth: width, targetHeight: height)
        }
        return SubtitleBitmap.transparent(width: width, height: height)
    }

    private func ensureScratch(width: Int, height: Int) {
        guard width != frameWidth || height != frameHeight else { return }
        frameWidth = width
        frameHeight = height
        scratch = [UInt8](repeating: 0, count: width * height * 4)
        lastDrawnRect = .empty
        needsClearOnNextRender = true
    }

    private func clear(_ rect: SubtitleDirtyRect) {
        let r = rect.clamped(width: frameWidth, height: frameHeight)
        guard !r.isEmpty, scratch.count >= frameWidth * frameHeight * 4 else { return }
        scratch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for y in r.y..<(r.y + r.height) {
                memset(base + (y * frameWidth + r.x) * 4, 0, r.width * 4)
            }
        }
    }

    private func erasePreviousFrame(width: Int, height: Int) -> SubtitleBitmap? {
        let cleared = lastDrawnRect.clamped(width: width, height: height)
        lastDrawnRect = .empty
        if !cleared.isEmpty {
            clear(cleared)
            return SubtitleBitmap(width: width, height: height,
                                  pixels: scratch, imageCount: 0, dirty: cleared)
        } else {
            // 没有明确的上一帧脏区（比如刚 seek 后），整幅透明清屏兜底
            return SubtitleBitmap.transparent(width: width, height: height)
        }
    }

    private func compose(cue: Cue, targetWidth: Int, targetHeight: Int) -> SubtitleBitmap {
        let cleared = lastDrawnRect.clamped(width: targetWidth, height: targetHeight)
        if !cleared.isEmpty {
            clear(cleared)
        }

        var drawn = SubtitleDirtyRect.empty

        // 如果片源与字幕制作声明尺寸不同，按比例坐标映射
        let scaleX: Double = (cue.canvasWidth > 0 && cue.canvasWidth != targetWidth)
            ? Double(targetWidth) / Double(cue.canvasWidth) : 1.0
        let scaleY: Double = (cue.canvasHeight > 0 && cue.canvasHeight != targetHeight)
            ? Double(targetHeight) / Double(cue.canvasHeight) : 1.0

        scratch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }

            for rect in cue.rects {
                let dstX = Int((Double(rect.x) * scaleX).rounded())
                let dstY = Int((Double(rect.y) * scaleY).rounded())
                let dstW = Int((Double(rect.width) * scaleX).rounded())
                let dstH = Int((Double(rect.height) * scaleY).rounded())

                guard dstX >= 0, dstY >= 0, dstX + dstW <= targetWidth, dstY + dstH <= targetHeight else {
                    continue
                }

                if scaleX == 1.0 && scaleY == 1.0 {
                    // 1:1 像素拷贝
                    rect.bgraPixels.withUnsafeBytes { srcRaw in
                        guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                        for row in 0..<rect.height {
                            let srcPtr = srcBase + row * rect.width * 4
                            let dstPtr = base + ((dstY + row) * targetWidth + dstX) * 4
                            memcpy(dstPtr, srcPtr, rect.width * 4)
                        }
                    }
                } else {
                    // 等比映射
                    rect.bgraPixels.withUnsafeBytes { srcRaw in
                        guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                        for r in 0..<dstH {
                            let srcRow = min(rect.height - 1, Int(Double(r) / scaleY))
                            let srcRowOffset = srcRow * rect.width * 4
                            let dstRowOffset = ((dstY + r) * targetWidth + dstX) * 4
                            for c in 0..<dstW {
                                let srcCol = min(rect.width - 1, Int(Double(c) / scaleX))
                                let srcIdx = srcRowOffset + srcCol * 4
                                let dstIdx = dstRowOffset + c * 4
                                base[dstIdx + 0] = srcBase[srcIdx + 0]
                                base[dstIdx + 1] = srcBase[srcIdx + 1]
                                base[dstIdx + 2] = srcBase[srcIdx + 2]
                                base[dstIdx + 3] = srcBase[srcIdx + 3]
                            }
                        }
                    }
                }

                let rectDirty = SubtitleDirtyRect(x: dstX, y: dstY, width: dstW, height: dstH)
                drawn = drawn.union(rectDirty)
            }
        }

        lastDrawnRect = drawn.clamped(width: targetWidth, height: targetHeight)
        let dirty = cleared.union(lastDrawnRect)

        return SubtitleBitmap(width: targetWidth, height: targetHeight,
                              pixels: scratch, imageCount: cue.rects.count,
                              dirty: dirty.isEmpty ? SubtitleDirtyRect(x: 0, y: 0, width: targetWidth, height: targetHeight) : dirty)
    }

    func debugSummary() -> String {
        lock.lock(); defer { lock.unlock() }
        return "图形字幕（PGS/位图） · 已缓存 \(cues.count) 条"
    }
}

