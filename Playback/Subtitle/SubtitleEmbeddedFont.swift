//  SubtitleEmbeddedFont.swift
//  MetalPlayer 重建工程 —— Phase 3 内嵌字体
//
//  符号表里 `struct SubtitleEmbeddedFont` 存在（VMa），成员未暴露 ——
//  与 SubtitleBitmap 同一类情况，实现写在 Playback/ 并登记到手写覆盖表。
//
//  ┌ 它是什么
//  │
//  │ Matroska 允许把字体文件当作**附件**塞进容器里（`AVMEDIA_TYPE_ATTACHMENT`
//  │ 的流），文件名在 `metadata["filename"]`，字节内容在 `codecpar->extradata`。
//  │ 做字幕组的时候这是标配：ASS 里写了 `Style: ...,方正兰亭黑,...`，而用户机器上
//  │ 没有这个字体，就只能靠容器自带。
//  │
//  │ 没有它也不至于渲染不出来 —— libass 会退回到系统字体 —— 但字幕的
//  │ 字形、字宽、断行位置会全变，跟片方的意图差很远。
//  └
//
//  ┌ 为什么 AssSubtitleRenderer 的 init 要收它
//  │
//  │ 因为 libass 的 `ass_add_font` 是**library 层**的注册，
//  │ 必须在 `ass_renderer_init` 之前完成 —— 之后再加的字体不会被已经建好的
//  │ 字体缓存认到。所以它只能作为构造参数进去，而不是「先建好再喂」。
//  └

import Foundation

struct SubtitleEmbeddedFont {

    /// 容器里标的文件名，如 `arial.ttf` / `方正兰亭黑_GBK.ttf`。
    /// 这个名字要和 ASS 样式里的 `Fontname` 对得上才起作用 ——
    /// libass 会按**字体内部的名字**（name table）匹配，文件名只是给人看的。
    var name: String

    /// 字体文件本体（ttf / otf / ttc）。
    var data: Data

    init(name: String, data: Data) {
        self.name = name
        self.data = data
    }

    var isEmpty: Bool { data.isEmpty }
}
