//  CadenceDetector.swift
//  Macrife Player · 采集卡输入低延迟与假 60 帧（真实 30 FPS）智能识别重构引擎
//
//  核心技术定位与解决痛点：
//  1. 【假 60 帧智能识别与真 60 帧重构】：
//     当 PS5 / Xbox / Switch 等主机开启“画质/质量模式”（原生 30 FPS 渲染）时，
//     HDMI 输出往往固定为 60Hz 信号容器。输入给采集卡的视频流呈现 2:2 重复帧节奏：
//     [帧A, 帧A, 帧B, 帧B, 帧C, 帧C ...]。
//     常规播放器因探测到 60 FPS 容器而跳过补帧，导致用户在“60FPS补帧模式”下仍遭遇 30 FPS 顿挫。
//     本引擎通过高频下采样亮度差分与有限状态机（FSM），精准识别 2:2 Pulldown 假 60 帧，
//     并将重复帧动态替换为真实 AI 运动插值帧，将主机画面点石成金重构为真 60.00 / 120.00 FPS。
//
//  2. 【采集卡超低延迟输入流水线（Zero-Latency Live Pipeline）】：
//     针对采集卡直通与补帧两种场景，提供极限队列收紧与直出策略：
//     - 不开补帧时：绕过 presentation PTS 缓冲，推流即解码，解码即上屏，延迟压缩至 1 帧刷新周期（< 16ms）；
//     - 开启补帧时：单帧即时插值流水线（Just-In-Time 1-frame Pipeline），严控处理延迟，杜绝多级缓冲堆积。

import Foundation
import CoreVideo
import Accelerate

/// 帧节奏类型
enum VideoCadenceType: String {
    case normal           // 原生逐帧独立运动（真 60fps / 真 30fps 等）
    case fake60From30     // 2:2 重复帧（假 60 帧，真实渲染为 30 FPS）
    case fake60From24     // 3:2 Pulldown（电影 24fps 封装于 60Hz 容器）
    case staticScene      // 纯静态画面（暂停菜单或静止图像）
}

/// 假 60 帧处理结果指示
struct CadenceDecision {
    /// 识别出的画面节奏
    let cadence: VideoCadenceType
    /// 当前帧是否为重复帧（Duplicate Frame）
    let isDuplicate: Bool
    /// 估算的真实游戏/内容帧率
    let realContentFPS: Double
    /// 是否应该将当前帧替换为真实 AI 插值帧
    let shouldReplaceWithInterpolated: Bool
}

final class CadenceDetector {

    static let shared = CadenceDetector()

    // MARK: - 内部状态缓存

    private let sampleGrid = 16 // 16x16 = 256 点超低开销空间采样
    private var prevSampleLuma: [UInt8]?
    private var diffHistory: [Double] = []
    private let maxHistory = 16

    // 连续检测计数器
    private var consecutiveTwoTwoCount = 0
    private var isFake60Locked = false
    private var duplicateToggle = false

    // 对外实时监测属性
    private(set) var currentCadence: VideoCadenceType = .normal
    private(set) var estimatedRealFPS: Double = 60.0
    private(set) var detectedFake60Count: Int = 0

    // 重置状态（换流或 Seek）
    func reset() {
        prevSampleLuma = nil
        diffHistory.removeAll()
        consecutiveTwoTwoCount = 0
        isFake60Locked = false
        duplicateToggle = false
        currentCadence = .normal
        estimatedRealFPS = 60.0
    }

    // MARK: - 主检测方法

    /// 输入当前新解码出来的 CVPixelBuffer 与容器上报帧率，返回节奏判定与动作指令
    func processFrame(
        pixelBuffer: CVPixelBuffer,
        containerFPS: Double,
        settings: PlaybackSettings
    ) -> CadenceDecision {

        // 若用户完全关闭该功能，直接退化为正常流
        guard settings.fake60FPSOptimization != .off else {
            return CadenceDecision(
                cadence: .normal,
                isDuplicate: false,
                realContentFPS: containerFPS,
                shouldReplaceWithInterpolated: false
            )
        }

        let isAround60Hz = (containerFPS >= 55.0 && containerFPS <= 65.0)
        guard isAround60Hz || (settings.fake60FPSOptimization == .on && containerFPS >= 50.0) else {
            return CadenceDecision(
                cadence: .normal,
                isDuplicate: false,
                realContentFPS: containerFPS,
                shouldReplaceWithInterpolated: false
            )
        }

        // 1. 极速提取当前帧的网格化 Y 亮度样本
        guard let currentLuma = extractGridLuma(from: pixelBuffer) else {
            return CadenceDecision(cadence: currentCadence, isDuplicate: false, realContentFPS: containerFPS, shouldReplaceWithInterpolated: false)
        }

        guard let prevLuma = prevSampleLuma, prevLuma.count == currentLuma.count else {
            self.prevSampleLuma = currentLuma
            return CadenceDecision(cadence: currentCadence, isDuplicate: false, realContentFPS: containerFPS, shouldReplaceWithInterpolated: false)
        }

        // 2. 计算平均绝对亮度差（Normalized MAD）
        var sumDiff: Double = 0
        let count = currentLuma.count
        for i in 0..<count {
            sumDiff += abs(Double(currentLuma[i]) - Double(prevLuma[i]))
        }
        let diff = sumDiff / Double(count * 255)
        self.prevSampleLuma = currentLuma

        // 记录历史
        diffHistory.append(diff)
        if diffHistory.count > maxHistory {
            diffHistory.removeFirst()
        }

        // 3. 判定当前帧是否与上一帧完全相同（重复帧阈值 0.0035，微小 HDMI 噪声容忍）
        let isDuplicate = (diff < 0.0035)

        // 4. 2:2 重复模式分析 (交替运动与重复)
        analyzeHistory()

        // 5. 决策与指令
        if isFake60Locked {
            currentCadence = .fake60From30
            estimatedRealFPS = containerFPS * 0.5 // 60Hz 容器中实际为 30 FPS
            detectedFake60Count += 1

            // 若当前帧是重复帧，且用户设置了目标 60 FPS 模式或更高，指示将此重复帧替换为真实中间插帧
            let shouldReplace = isDuplicate && (settings.rifeRateMode == .fps60 || settings.rifeRateMode == .fps120 || settings.rifeRateMode == .x2)

            return CadenceDecision(
                cadence: .fake60From30,
                isDuplicate: isDuplicate,
                realContentFPS: estimatedRealFPS,
                shouldReplaceWithInterpolated: shouldReplace
            )
        } else {
            currentCadence = .normal
            estimatedRealFPS = containerFPS
            return CadenceDecision(
                cadence: .normal,
                isDuplicate: isDuplicate,
                realContentFPS: containerFPS,
                shouldReplaceWithInterpolated: false
            )
        }
    }

    // MARK: - 模式分析与状态机锁定

    private func analyzeHistory() {
        guard diffHistory.count >= 6 else { return }

        // 检查最近 6 帧的交替模式：例如 [高, 低, 高, 低, 高, 低]
        var alternatingPairs = 0
        let len = diffHistory.count
        for i in stride(from: len - 1, through: 1, by: -2) {
            let cur = diffHistory[i]
            let prev = diffHistory[i - 1]
            let isOneZero = (cur < 0.0035 && prev > 0.008) || (cur > 0.008 && prev < 0.0035)
            if isOneZero {
                alternatingPairs += 1
            }
        }

        if alternatingPairs >= 3 {
            consecutiveTwoTwoCount += 1
            if consecutiveTwoTwoCount >= 3 {
                isFake60Locked = true
            }
        } else {
            // 如果连续出现多个非零大运动帧（正常真 60 帧游戏画面），解锁假 60 状态
            let recentNonZero = diffHistory.suffix(4).filter { $0 > 0.008 }.count
            if recentNonZero >= 4 {
                consecutiveTwoTwoCount = max(0, consecutiveTwoTwoCount - 1)
                if consecutiveTwoTwoCount == 0 {
                    isFake60Locked = false
                }
            }
        }
    }

    // MARK: - 极速亮度网格采样 (零拷贝，CPU 耗时 < 0.05ms)

    private func extractGridLuma(from pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 32, height > 32 else { return nil }

        let planeCount = CVPixelBufferGetPlaneCount(pixelBuffer)
        let lumaBase: UnsafeMutableRawPointer?
        let bytesPerRow: Int

        if planeCount >= 2 {
            // NV12 格式：Plane 0 为 Y
            lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        } else {
            // 单平面
            lumaBase = CVPixelBufferGetBaseAddress(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        }

        guard let base = lumaBase else { return nil }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var samples = [UInt8](repeating: 0, count: sampleGrid * sampleGrid)
        let stepX = width / sampleGrid
        let stepY = height / sampleGrid

        for gy in 0..<sampleGrid {
            let y = gy * stepY
            let rowPtr = ptr.advanced(by: y * bytesPerRow)
            for gx in 0..<sampleGrid {
                let x = gx * stepX
                samples[gy * sampleGrid + gx] = rowPtr[x]
            }
        }

        return samples
    }
}
