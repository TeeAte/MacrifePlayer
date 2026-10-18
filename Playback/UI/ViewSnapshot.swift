//  ViewSnapshot.swift
//  MetalPlayer 重建工程 —— dev：NSView → PNG
//
//  只服务于验收用的两个开关（`--stats-png` / `--window-png`），不进生产路径。
//
//  为什么不用 `CGWindowListCreateImage`：它在新 SDK 里已经**编译不过**了
//  （`'CGWindowListCreateImage' is unavailable in macOS: Please use
//  ScreenCaptureKit instead`），而 ScreenCaptureKit 要授权 + 异步，
//  为一个 dev 开关付这个代价不值。系统级 `screencapture` 也不行 ——
//  实测在本环境里直接报 `could not create image from display`（没有录屏授权）。
//
//  于是只剩进程内渲染这一条路。两条实现都留着，但**用途不同**：
//
//    · `image(of:)` —— `cacheDisplay(in:to:)`，驱动 AppKit 的 `draw(_:)` 路径。
//      **对这套 UI 基本没用**：实测抓整个窗口得到的是纯黑 3024x1690。
//      原因见下面 `layerImage` 的注释 —— 这里的视觉全在图层上，不在 `draw(_:)` 里。
//      保留它只是因为它对「纯 `draw`-based 的视图」仍然是对的。
//
//    · `layerImage(of:)` —— `CALayer.render(in:)`，直接渲染图层树。
//      本工程的验收图**一律走这条**（面板 / 控制条 / 整窗都是 layer-backed）。
//
//  一个必须记住的前提：**两条路都要先强制跑一次布局**。
//  不跑的话读到的是上一轮的版式，会得到「约束明明 active 却对不上 frame」
//  这种自相矛盾的结果 —— 那不是在渲染，是在读脏数据。

import AppKit
import CoreGraphics
import ImageIO

enum ViewSnapshot {

    /// 把视图（连同子视图）画成一张位图。返回 nil = 尺寸为零 / 建不出位图。
    ///
    /// 分辨率跟着窗口的 `backingScaleFactor` 走（Retina 上 2x）——
    /// 由 `bitmapImageRepForCachingDisplay` 自动决定，不用手工乘。
    static func image(of view: NSView) -> CGImage? {
        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        // 先把待处理的布局跑完，否则抓到的是上一帧的版式（甚至空）。
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    /// 写成 PNG。返回是否成功 —— 由调用方决定怎么报告，不在这里吞掉失败。
    static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         "public.png" as CFString,
                                                         1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    // MARK: - 图层渲染（layer-backed 视图必须走这条）

    /// 把视图的**图层树**渲染成一张位图。
    ///
    /// 为什么还需要这条路（`cacheDisplay` 不够）：
    /// 本工程里面板与控制条上的视觉全是**图层**给的 —— `NSVisualEffectView` 的材质、
    /// 按钮的 `layer.backgroundColor`、`decodePathPill` 的圆角底色、控件的文字
    ///（layer-backed 的 `NSTextField` 把文本画在自己的 backing store 里）。
    /// 这些都不经过 `draw(_:)`，所以 `cacheDisplay` 一条都拿不到。
    ///
    /// 实测过：用 `cacheDisplay` 抓整个窗口，导出的 PNG 是**纯黑**（3024x1690，
    /// 只有画面里那个 Metal 层的位置留了一点痕迹），完全没法用来判版式。
    ///
    /// 这条路会把图层树直接画进 context，所以上面那些都拿得到。
    /// 它拿不到 `CAMetalLayer`（视频画面），但视频画面本来就不在这个视图里，
    /// 无妨 —— 这里要看的正是压在画面上的那些 UI。
    ///
    /// 缩放跟着窗口的 `backingScaleFactor`（Retina 上 2x）：不放大出图的话
    /// 文字会被采样糊掉，而「描边粗细 / 字号大小」恰恰是这张图要看的东西。
    static func layerImage(of view: NSView) -> CGImage? {
        // 与 `image(of:)` 同样先跑布局：`CALayer.render` 只负责画，
        // 不管布局，读早了拿到的是上一轮的版式。
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()

        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        guard let layer = view.layer else { return nil }

        let scale = view.window?.backingScaleFactor ?? 2
        let pixelWidth = Int((bounds.width * scale).rounded())
        let pixelHeight = Int((bounds.height * scale).rounded())
        guard pixelWidth >= 1, pixelHeight >= 1,
              let ctx = CGContext(data: nil,
                                  width: pixelWidth, height: pixelHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        // 先把各图层自己的 backing store 画出来，再整体渲染 ——
        // `render(in:)` 自己不保证触发一次绘制，漏掉这步会拿到半张图。
        layer.displayIfNeeded()
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        return ctx.makeImage()
    }
}
