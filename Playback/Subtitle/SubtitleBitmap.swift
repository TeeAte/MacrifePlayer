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

    init(width: Int, height: Int, pixels: [UInt8], imageCount: Int) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.imageCount = imageCount
    }

    var isEmpty: Bool { imageCount == 0 }

    /// 一张全透明的同尺寸位图（用来把上一帧的字幕擦掉）。
    static func transparent(width: Int, height: Int) -> SubtitleBitmap {
        SubtitleBitmap(width: width, height: height,
                       pixels: [UInt8](repeating: 0, count: width * height * 4),
                       imageCount: 0)
    }
}
