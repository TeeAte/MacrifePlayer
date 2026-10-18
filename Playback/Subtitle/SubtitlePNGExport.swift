//  SubtitlePNGExport.swift
//  MetalPlayer 重建工程 —— Phase 3 dev-only：字幕层导出 PNG
//
//  为什么需要它：验收走的是「叠图数 + 峰值 RGB」这套程序化判定（见
//  PlayerContainerView.subtitleDumpText），它足够**断言**，但看不出「好不好看」——
//  字体选对没有、描边粗细合不合适、\N 换行有没有真的换行、简繁字形是不是真的不同。
//  这些只有看一眼才知道。
//
//  与 FrameDumper 的分工：FrameDumper 导的是**视频帧**（走 CIImage，绕开 Metal），
//  这里导的是**字幕层**（CPU 合成出来的预乘 BGRA）。两者合起来才是屏幕上那一格。
//  之所以不直接导「合成后的画面」：那要读回 drawable 纹理，而 MTKView 的 drawable
//  是只写不可读的（.framebufferOnly），真做要额外开一张离屏纹理 —— 为一张调试图不值得。
//
//  只认环境变量/命令行开关，不进生产路径。
//
//  —— 注意这里**没有** `#if USE_FFMPEG` 守卫 ——
//  它只依赖 `SubtitleBitmap`（一个与 FFmpeg 无关的纯值类型）与 CoreGraphics/ImageIO。
//  加守卫的话 `AppDelegate`（两套构建都要编）就引用不到它了。
//  占位构建下 `subtitleSnapshotForExport()` 恒返回 nil，压根走不到这里。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SubtitlePNGExport {

    /// 把字幕位图写成 PNG。
    ///
    /// - Parameter background: 垫在字幕下面的不透明底色。
    ///   字幕位图是**预乘 alpha** 的 BGRA，直接导出会得到「黑底上的半透明字」——
    ///   深色描边在深底上就看不见了。垫一层深灰更接近播放时的观感，
    ///   也顺便验证了合成的 alpha 混合到底对不对。
    /// - Returns: 写成功返回 true。
    @discardableResult
    static func write(_ bitmap: SubtitleBitmap,
                      to url: URL,
                      background: (r: UInt8, g: UInt8, b: UInt8) = (18, 26, 36)) -> Bool {
        let w = bitmap.width, h = bitmap.height
        guard w > 0, h > 0, bitmap.pixels.count >= w * h * 4 else { return false }

        // 预乘 alpha 的「over」合成：dst = src + bg × (1 − a)。
        // src 已经是预乘过的，所以这里不需要再乘一次 a。
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var i = 0
        while i < w * h * 4 {
            let b = Int(bitmap.pixels[i])
            let g = Int(bitmap.pixels[i + 1])
            let r = Int(bitmap.pixels[i + 2])
            let a = Int(bitmap.pixels[i + 3])
            let inv = 255 - a
            out[i]     = UInt8(min(255, b + Int(background.b) * inv / 255))
            out[i + 1] = UInt8(min(255, g + Int(background.g) * inv / 255))
            out[i + 2] = UInt8(min(255, r + Int(background.r) * inv / 255))
            out[i + 3] = 255
            i += 4
        }

        // BGRA 内存布局 ↔ CGImage 的标准配对：
        //   内存里是 [B][G][R][A]，read 成 32 位小端整数就是 0xAARRGGBB。
        //   byteOrder32Little + premultipliedFirst 正是这个含义。
        guard let provider = CGDataProvider(data: Data(out) as CFData),
              let image = CGImage(width: w, height: h,
                                  bitsPerComponent: 8,
                                  bitsPerPixel: 32,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(
                                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider,
                                  decode: nil,
                                  shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { return false }

        guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
