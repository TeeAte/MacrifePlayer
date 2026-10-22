//  SubtitleRenderable.swift
//  MacrifePlayer —— 字幕渲染器统一协议

import Foundation

protocol SubtitleRenderable: AnyObject {
    /// 清除所有已排队或已缓存的字幕事件与状态（Seek / 切轨时调用）
    func resetTrack()

    /// 渲染此刻的字幕。主线程（渲染循环）调用。
    /// - Returns: 若画面内容发生变动则返回新的 SubtitleBitmap；若无变动则返回 nil 以避免 GPU 上传。
    func render(at time: Double, width: Int, height: Int) -> SubtitleBitmap?

    /// 强制生成此刻的完整快照（无视“无变动”优化）
    func snapshot(at time: Double, width: Int, height: Int) -> SubtitleBitmap?

    /// 诊断信息摘要
    func debugSummary() -> String
}
