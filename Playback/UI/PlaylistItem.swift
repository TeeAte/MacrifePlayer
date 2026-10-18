//  PlaylistItem.swift
//  MetalPlayer 重建工程 —— 播放列表条目（Phase 2）
//
//  原版骨架观测到的全部内容只有一条：
//      init(from: Decoder) throws
//  —— 但这一条信息量很大：它说明 `PlaylistItem` **是 Codable 的**，
//  也就是说播放列表**能被存盘再读回来**。这与文案表里的
//  `save_playlist_ellipsis`（"保存播放列表..."）/ `open_playlist_ellipsis`
//  （"打开播放列表..."）完全对得上。
//
//  所以这里按 Codable 实现，存盘用 JSON。
//  ⚠️ 原版的存盘格式**未知**（可能是 m3u、可能是 JSON、可能是 plist）。
//  重建工程用自己的 JSON 格式，只求自洽 —— 不要去试图读原版的列表文件。

import Foundation

struct PlaylistItem: Codable, Equatable {

    /// 媒体文件位置。
    var url: URL

    /// 列表上显示的名字。
    var title: String

    init(url: URL, title: String? = nil) {
        self.url = url
        self.title = (title?.isEmpty == false)
            ? title!
            : url.deletingPathExtension().lastPathComponent
    }

    /// 文件是否还在。
    /// 不参与编码 —— 这是**当下**的事实，不是存盘时的状态。
    var isMissing: Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }

    /// 文件大小（字节）。取不到返回 0。
    var byteSize: Int64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(v ?? 0)
    }

    /// 副标题：尺寸 + 路径。表里第二行显示它。
    var subtitle: String {
        var parts: [String] = []
        if isMissing {
            parts.append("文件不存在")
        } else if byteSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: byteSize,
                                                   countStyle: .file))
        }
        parts.append(url.deletingLastPathComponent().path)
        return parts.joined(separator: " · ")
    }
}
