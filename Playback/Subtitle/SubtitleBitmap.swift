//  SubtitleBitmap.swift
//  MetalPlayer 重建工程 —— Phase 3 字幕渲染产物
//
//  ┌ 为什么这个文件在 Playback/ 而不是 MetalPlayer/Subtitle/
//  │
//  │ 符号表里这个类型**存在**（`struct SubtitleBitmap`，元数据访问器 VMa），
//  │ 所以 REA 在 MetalPlayer/Subtitle/SubtitleBitmap.swift 里留下了骨架。
//  │ 但骨架里的它是个空 struct —— 成员「未暴露」（libass 的产物不会被
//  │ 反射段记录），拿不到成员就用不了。
//  │
//  │ 按本工程的惯例（见 _reverse/generate.py 的 HANDWRITTEN 表注释），
//  │ 这类「骨架里存在、但必须补出真实内容」的类型，实现写在 Playback/ 下，
//  │ 并把类型名登记进那张表 —— 脚本便不再生成同名骨架，避免 redeclaration。
//  └
//
//  ┌ 成员是我补的（原版未知），但补的形状由**下游需要**决定，不是拍脑袋
//  │
//  │ 下游只有一个消费者：把这张位图变成一张 MTLTexture 叠到画面上。
//  │ 那需要的就是「多大 + 每个像素什么颜色」。
//  │
//  │ 于是就有 width / height / pixels。多一个 imageCount 是因为
//  │ 界面需要区分「这一帧没有字幕」和「这一帧有字幕但恰好全透明」——
//  │ 前者可以整个跳过绘制，后者不行（它得把上一帧的字幕擦掉）。
//  └
//
//  ┌ 为什么是 [UInt8] 而不是 MTLTexture
//  │
//  │ 因为这个类型跨线程产生（主线程渲染时合成）与消费（下一帧上传 GPU），
//  │ 而 MTLTexture 是 GPU 资源，跟着 drawable 生命周期走。让它持有纹理会把
//  │ 「合成」和「上传」耦死，也会让 render(at:width:height:) 的「没有变化就返回 nil」
//  │ 这条优化变得没法表达（纹理总得有一张）。
//  └

import Foundation

/// 一块像素矩形。原点在**左上角**，与 Metal 纹理的行序一致
///（libass 的 `dst_x/dst_y` 也是左上角原点，所以这里不需要翻）。
///
/// 存在的理由：字幕层每帧真正变的只有「上一帧画过的位置」∪「这一帧要画的位置」，
/// 两者往往只占全幅的百分之几（4K 全幅 29.5MB，字幕却只在底部几行）。
/// 按整幅清 + 整幅上传，等于每秒白搬 1.4GB 内存 —— 这就是「4K + PGS 字幕卡死」
/// 那条链路上被量化出来的开销。
struct SubtitleDirtyRect: Equatable {

    var x: Int
    var y: Int
    var width: Int
    var height: Int

    static let empty = SubtitleDirtyRect(x: 0, y: 0, width: 0, height: 0)

    var isEmpty: Bool { width <= 0 || height <= 0 }

    /// 并集。空矩形是单位元（与「什么都没画」求并 = 什么都不用传）。
    func union(_ other: SubtitleDirtyRect) -> SubtitleDirtyRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let x0 = min(x, other.x)
        let y0 = min(y, other.y)
        let x1 = max(x + width, other.x + other.width)
        let y1 = max(y + height, other.y + other.height)
        return SubtitleDirtyRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 裁到画面内。越界的部分 libass 本来就被 `composite` 丢掉了，这里同样丢掉。
    func clamped(width limitW: Int, height limitH: Int) -> SubtitleDirtyRect {
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(limitW, x + width)
        let y1 = min(limitH, y + height)
        guard x1 > x0, y1 > y0 else { return .empty }
        return SubtitleDirtyRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    var debugText: String { isEmpty ? "空" : "\(x),\(y) \(width)x\(height)" }
}

struct SubtitleBitmap {

    /// 位图宽高（像素）。等于渲染时请求的 width / height。
    var width: Int
    var height: Int

    /// 像素数据：**B, G, R, A** 顺序，长度 = width * height * 4。
    ///
    /// alpha **已预乘**（RGB 分量已经乘过 alpha）。理由见 AssSubtitleRenderer
    /// 文件头那段「为什么预乘」：描边 + 阴影 + 半透明文字叠在一起时，
    /// 预乘只要一次乘加，非预乘要逐层做除法还容易出低 alpha 色边。
    var pixels: [UInt8]

    /// 这一帧叠了几张 libass 图（阴影 / 描边 / 正文各算一张）。
    /// 0 表示这一帧没有字幕 —— 可以整个跳过，不必上传一张全透明的纹理。
    var imageCount: Int

    /// **只有这块区域的内容变了**，上传时只需要传它。
    ///
    /// 语义是「相对上一帧的差异范围」，不是「有内容的范围」——
    /// 字幕消失时它指的是刚被擦干净的那块（像素全 0，但必须传上去才擦得掉）。
    var dirty: SubtitleDirtyRect

    init(width: Int, height: Int, pixels: [UInt8], imageCount: Int,
         dirty: SubtitleDirtyRect? = nil) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.imageCount = imageCount
        self.dirty = dirty ?? SubtitleDirtyRect(x: 0, y: 0, width: width, height: height)
    }

    var isEmpty: Bool { imageCount == 0 }

    /// 一张全透明的同尺寸位图（用来把上一帧的字幕擦掉）。
    ///
    /// 这里无法只擦「上一帧画过的位置」：调用方拿到的是一张新位图，
    /// 不知道旧内容在哪。所以整幅给 —— 好在它只在**换轨 / 关字幕**时出现一次。
    static func transparent(width: Int, height: Int) -> SubtitleBitmap {
        SubtitleBitmap(width: width, height: height,
                       pixels: [UInt8](repeating: 0, count: width * height * 4),
                       imageCount: 0)
    }
}
