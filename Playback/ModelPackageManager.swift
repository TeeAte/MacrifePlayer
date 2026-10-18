// ModelPackageManager.swift
// Macrife Player · Phase 4 RIFE 模型包解密与加载管理器
//
// 负责从加密模型归档 models.dat (AES-256-GCM + gzip tar) 中就地提取
// 21 个已编译的 Apple CoreML 神经网络权重树 (.mlmodelc)。

import Foundation
import CryptoKit

public enum ModelPackageState: Equatable {
    case idle
    case extracting(progress: Double)
    case ready(URL)
    case failed(String)

    public static func == (lhs: ModelPackageState, rhs: ModelPackageState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.extracting(let p1), .extracting(let p2)): return abs(p1 - p2) < 0.001
        case (.ready(let u1), .ready(let u2)): return u1 == u2
        case (.failed(let s1), .failed(let s2)): return s1 == s2
        default: return false
        }
    }
}

public final class ModelPackageManager {
    public static let shared = ModelPackageManager()

    // MARK: - 常量与密钥

    private static let magicHeader = Data([0x4D, 0x50, 0x4D, 0x44, 0x41, 0x54, 0x31, 0x00]) // "MPMDAT1\0"

    /// 逆向分析 Original APP 二进制内两段 32 字节数组异或 (eor) 得到的 AES-256 密钥
    private static let packageKey: SymmetricKey = {
        let keyBytes: [UInt8] = [
            0x82, 0xa3, 0xa5, 0xbf, 0xa2, 0xa3, 0xa6, 0xa2,
            0xa2, 0xa2, 0xa5, 0xa3, 0xa3, 0xa3, 0xa2, 0xa3,
            0xa2, 0xa2, 0xa2, 0xa3, 0xa2, 0xa2, 0xa3, 0xa2,
            0xa3, 0xa2, 0xa2, 0xa2, 0xa2, 0xa2, 0xa2, 0xa2
        ]
        return SymmetricKey(data: Data(keyBytes))
    }()

    // MARK: - 状态与并发锁

    private let queue = DispatchQueue(label: "com.macrife.model.package.prepare", qos: .userInitiated)
    private let condition = NSCondition()
    private var state: ModelPackageState = .idle
    private var prewarmStarted = false

    private init() {}

    // MARK: - 路径解析

    /// 模型解压存储的目标根目录: ~/Library/Application Support/MacrifePlayer/Models
    public static var modelsDestinationURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("MacrifePlayer/Models", isDirectory: true)
    }

    /// 定位 models.dat 原始加密文件
    public static func bundledDatURL() -> URL? {
        let fm = FileManager.default

        // 1. App Bundle 内
        if let url = Bundle.main.url(forResource: "models", withExtension: "dat"), fm.fileExists(atPath: url.path) {
            return url
        }

        // 2. Contents/Resources
        let resUrl = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/models.dat")
        if fm.fileExists(atPath: resUrl.path) { return resUrl }

        // 3. 开发环境备用路径
        let devPaths = [
            "/Users/teeate/Dev/MetalPlayer/Original APP.app/Contents/Resources/models.dat",
            "/Users/teeate/Dev/MetalPlayer/MacrifePlayer/Resources/models.dat"
        ]
        for p in devPaths {
            if fm.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    // MARK: - 对外接口

    /// 异步预热并准备模型包
    public static func prewarmAsync() {
        shared.queue.async {
            shared.prepareIfNeeded()
        }
    }

    /// 同步获取解压就绪的模型目录（带超时）
    public static func waitForModelsRootURL(timeout: Double = 12.0) -> URL? {
        return shared.waitForReady(timeout: timeout)
    }

    /// 若已就绪立即返回 URL，否则返回 nil
    public static func cachedModelsRootURLIfReady() -> URL? {
        return shared.cachedURLIfReady()
    }

    /// 获取特定模型的具体 CoreML 目录
    /// - Parameter variant: 如 "rife_426_fp16_1080p_blocks"
    public static func modelDirectory(for variant: String) -> URL? {
        guard let root = cachedModelsRootURLIfReady() ?? waitForModelsRootURL(timeout: 2.0) else {
            return nil
        }
        let coremlDir = root.appendingPathComponent("coreml", isDirectory: true)
        let modelDir = coremlDir.appendingPathComponent(variant, isDirectory: true)
        if FileManager.default.fileExists(atPath: modelDir.path) {
            return modelDir
        }
        return nil
    }

    // MARK: - 内部解密与提取管线

    private func cachedURLIfReady() -> URL? {
        condition.lock()
        defer { condition.unlock() }
        if case .ready(let url) = state { return url }

        // 检查本地磁盘是否已经提取好
        let dest = Self.modelsDestinationURL
        let manifest = dest.appendingPathComponent("manifest.json")
        let coreml = dest.appendingPathComponent("coreml")
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: coreml.path) {
            state = .ready(dest)
            return dest
        }
        return nil
    }

    private func waitForReady(timeout: Double) -> URL? {
        if let url = cachedURLIfReady() { return url }

        queue.async { [weak self] in
            self?.prepareIfNeeded()
        }

        condition.lock()
        defer { condition.unlock() }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            switch state {
            case .ready(let url):
                return url
            case .failed(let err):
                NSLog("[ModelPackageManager] 等待模型包失败: %@", err)
                return nil
            case .idle, .extracting:
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    NSLog("[ModelPackageManager] 等待 models.dat 解压超时 (%.1fs)", timeout)
                    return nil
                }
                condition.wait(until: deadline)
            }
        }
    }

    private func prepareIfNeeded() {
        condition.lock()
        if case .ready = state {
            condition.unlock()
            return
        }
        if case .extracting = state {
            condition.unlock()
            return
        }

        let dest = Self.modelsDestinationURL
        let manifest = dest.appendingPathComponent("manifest.json")
        let coreml = dest.appendingPathComponent("coreml")
        if FileManager.default.fileExists(atPath: manifest.path),
           FileManager.default.fileExists(atPath: coreml.path) {
            state = .ready(dest)
            condition.broadcast()
            condition.unlock()
            NSLog("[ModelPackageManager] 缓存模型包已就绪: %@", dest.path)
            return
        }

        guard let datURL = Self.bundledDatURL() else {
            let msg = "未找到 models.dat 原始加密文件"
            state = .failed(msg)
            condition.broadcast()
            condition.unlock()
            NSLog("[ModelPackageManager] 错误: %@", msg)
            return
        }

        state = .extracting(progress: 0.1)
        condition.broadcast()
        condition.unlock()

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            try preparePackage(datURL: datURL, destination: dest)
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

            condition.lock()
            state = .ready(dest)
            condition.broadcast()
            condition.unlock()
            NSLog("[ModelPackageManager] models.dat 解密解压成功 · 耗时 %.1f ms · 目录: %@", elapsed, dest.path)
        } catch {
            let msg = "解密解包失败: \(error.localizedDescription)"
            condition.lock()
            state = .failed(msg)
            condition.broadcast()
            condition.unlock()
            NSLog("[ModelPackageManager] 致命错误: %@", msg)
        }
    }

    private func preparePackage(datURL: URL, destination: URL) throws {
        let fm = FileManager.default

        // 1. 读取原始二进制
        let t0 = CFAbsoluteTimeGetCurrent()
        let fileData = try Data(contentsOf: datURL, options: .mappedIfSafe)
        guard fileData.count > 40 else {
            throw NSError(domain: "ModelPackageManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "models.dat is too small"])
        }

        // 2. 校验 Header Magic
        let magic = fileData.subdata(in: 0..<8)
        guard magic == Self.magicHeader else {
            throw NSError(domain: "ModelPackageManager", code: -2, userInfo: [NSLocalizedDescriptionKey: "Invalid models.dat magic"])
        }

        // 3. 解离 Nonce (12 字节) 与密文 + Tag (尾部 16 字节)
        let nonceData = fileData.subdata(in: 8..<20)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let payload = fileData.subdata(in: 20..<fileData.count)

        guard payload.count > 16 else {
            throw NSError(domain: "ModelPackageManager", code: -3, userInfo: [NSLocalizedDescriptionKey: "Ciphertext too small for GCM tag"])
        }
        let ciphertext = payload.subdata(in: 0..<(payload.count - 16))
        let tag = payload.subdata(in: (payload.count - 16)..<payload.count)

        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)

        // 4. AES-GCM 解密
        let t1 = CFAbsoluteTimeGetCurrent()
        let decryptedData = try AES.GCM.open(sealedBox, using: Self.packageKey)
        let t2 = CFAbsoluteTimeGetCurrent()
        NSLog("[ModelPackageManager] 读取: %.1f ms · 解密: %.1f ms · 明文大小: %ld 字节",
              (t1 - t0) * 1000.0, (t2 - t1) * 1000.0, decryptedData.count)

        // 5. 写入临时 .tar.gz
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let tgzPath = tempDir.appendingPathComponent("models.tgz")
        try decryptedData.write(to: tgzPath, options: .atomic)

        // 6. 提取 tar 归档到 destination
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let t3 = CFAbsoluteTimeGetCurrent()
        try runTarExtract(archive: tgzPath, destination: destination)
        let t4 = CFAbsoluteTimeGetCurrent()
        NSLog("[ModelPackageManager] tar 解压提取: %.1f ms", (t4 - t3) * 1000.0)
    }

    private func runTarExtract(archive: URL, destination: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xzf", archive.path, "-C", destination.path]

        let pipe = Pipe()
        task.standardError = pipe
        try task.run()
        task.waitUntilExit()

        if task.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "status \(task.terminationStatus)"
            throw NSError(domain: "ModelPackageManager", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "tar extraction failed: \(errMsg)"])
        }
    }
}
