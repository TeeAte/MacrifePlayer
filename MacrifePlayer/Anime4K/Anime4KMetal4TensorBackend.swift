// Anime4KMetal4TensorBackend.swift
// Macrife Player · Phase 5 Anime4K Metal 权重加载与后端管理

import Foundation
import Metal

final class Anime4KMetal4TensorBackend {

    private(set) var loadedModels: [String: Data] = [:]
    private var cachedWeightsDir: URL?

    init() {}

    /// 定位 Anime4K 权重文件目录
    func weightsDirectory() throws -> URL {
        if let cached = cachedWeightsDir { return cached }

        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Anime4K/Metal4Weights"),
            Bundle.main.resourceURL?.appendingPathComponent("Metal4Weights"),
            Bundle.main.resourceURL,
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("MacrifePlayer/Anime4K")
        ]

        for case let dir? in candidates {
            if FileManager.default.fileExists(atPath: dir.path) {
                cachedWeightsDir = dir
                return dir
            }
        }

        // 回退默认 resource 目录
        let fallback = Bundle.main.resourceURL ?? URL(fileURLWithPath: "/tmp")
        cachedWeightsDir = fallback
        return fallback
    }

    /// 加载指定的模型权重
    func loadEngines(names: [String]) throws {
        let dir = try weightsDirectory()
        for name in names {
            let weightsURL = dir.appendingPathComponent("\(name).weights")
            if FileManager.default.fileExists(atPath: weightsURL.path) {
                let data = try Data(contentsOf: weightsURL)
                loadedModels[name] = data
                NSLog("[Anime4KMetal4TensorBackend] 成功载入权重: %@ (%d bytes)", name, data.count)
            }
        }
    }

    func invalidateTimeline(reason: String) {
        NSLog("[Anime4KMetal4TensorBackend] Invalidate timeline: %@", reason)
    }
}
