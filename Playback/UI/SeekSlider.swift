//  SeekSlider.swift
//  MetalPlayer 重建工程 —— 进度条（Phase 2）
//
//  原版骨架观测到的成员：`var doubleValue: Double`（继承自 NSSlider）
//  与 `func mouseDown(with: NSEvent)`。
//  反射段另外给出了这三个回调名，说明拖动被拆成了三段：
//      onBeginTracking        按下
//      onPreviewValueChanged  拖动中（限流）
//      onEndTracking          松手
//
//  为什么要拆三段，而不是直接用 NSSlider 的 target/action：
//  NSSlider 在拖动时会**连发几十次** action。每次真的去 seek 的话，
//  解封装线程会被打爆 —— 这在 Phase 1 实测过（拖动进度条时管线卡死）。
//  所以策略是：拖动中只做**限流预览**（默认 0.12s 一次），松手时才精确定位。
//
//  限流逻辑放在这个类里、而不是调用方，是因为反射段把 `onPreviewValueChanged`
//  记在了 SeekSlider 自己身上 —— 原版就是这么分的。

import Foundation
import AppKit

final class SeekSlider: NSSlider {

    /// 按下。调用方一般用它把「正在拖动」标记置位，从而不去覆盖滑块位置。
    var onBeginTracking: (() -> Void)?

    /// 拖动中的限流回调，参数是归一化位置 0...1。
    var onPreviewValueChanged: ((Double) -> Void)?

    /// 松手，参数是最终位置 0...1。调用方在这里做精确定位。
    var onEndTracking: ((Double) -> Void)?

    /// 拖动中的限流间隔（秒）。
    var previewThrottle: TimeInterval = 0.12

    /// 是否正在被拖动。调用方靠它决定「要不要用引擎时间回写滑块位置」。
    private(set) var isScrubbing = false

    private var lastPreviewAt: TimeInterval = 0

    // MARK: - 构造

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonSetup()
    }

    private func commonSetup() {
        // ⚠️ 这一行是「底部控制条整体错位」的根因，删掉会复发。
        //
        // 它原来是**漏的**。于是这个滑块带着一套 **required** 的 autoresizing
        // 约束进了布局引擎（实测 `--dump-frames` 摊出来的原文）：
        //     NSAutoresizingMaskLayoutConstraint  SeekSlider.minX   == 0
        //     NSAutoresizingMaskLayoutConstraint  SeekSlider.width  == 0
        //     NSAutoresizingMaskLayoutConstraint  SeekSlider.minY   == 0
        //     NSAutoresizingMaskLayoutConstraint  SeekSlider.height == 0
        // 这套「零尺寸 + 原点在 0」的硬约束和 ControlOverlayView 里那条链
        //（`时间`-(6)-`进度条`-(12)-`补帧`-…-`全屏`）直接打架，横向系统变成**无解**，
        // Auto Layout 只能放弃一批 required 约束，表现是一整条控制条全线错位：
        //     · 进度条塌成 0x0；
        //     · 时间标签被顶到 x = -8；
        //     · 播放 / 后退 / 前进的宽高约束（28×24 / 26×24）被打破，缩成 11 / 14 / 14；
        //     · 解码胶囊失去约束，撑成 1022pt 的巨型条，压住左边的播放按钮 ——
        //       用户看到的就是「播放暂停按钮和底部 UI 重叠在一起」。
        //
        // 教训：**只要一个视图还是 `translatesAutoresizingMaskIntoConstraints = true`，
        // 它在 Auto Layout 里就同时背着一套零尺寸的硬约束。** 而这类冲突
        // 在 stderr 里**不一定**打印 "Unable to simultaneously satisfy constraints"，
        // 想定位只能把 frame 与约束对象一起摊开看。
        //
        // 放在 `commonSetup` 而不是调用方：这是这个类自身的性质，
        // 任何地方用到它都不该再踩一次。
        translatesAutoresizingMaskIntoConstraints = false

        minValue = 0
        maxValue = 1
        doubleValue = 0
        isContinuous = true
        controlSize = .small
        // 自己是自己的 target：拖动期间的 action 走下面那个方法，
        // 由它决定「这次到底算预览还是算松手」。
        target = self
        action = #selector(handleAction)
    }

    // MARK: - 拖动

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        lastPreviewAt = 0
        onBeginTracking?()
        // super 会一直阻塞到鼠标抬起（内部跑 tracking loop）。
        // 不要把它放进条件里 —— 提前返回会让拖动提前结束。
        super.mouseDown(with: event)
        isScrubbing = false
        onEndTracking?(doubleValue)
    }

    /// 点击轨道直接跳（不经过拖动）。
    /// `mouseDown` 的 tracking loop 也会走这里，所以用 `isScrubbing` 区分。
    @objc private func handleAction() {
        guard isScrubbing else {
            // 单击轨道 / 键盘方向键：直接当一次落到位的操作
            onEndTracking?(doubleValue)
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastPreviewAt >= previewThrottle else { return }
        lastPreviewAt = now
        onPreviewValueChanged?(doubleValue)
    }
}
