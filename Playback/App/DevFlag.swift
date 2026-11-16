import Foundation

enum DevFlag {

    /// AppKit 也会把 -macrife.key 后的偏好值作为打开文件事件投递。
    /// 它们已由 UserDefaults 消费，不能再交给 FFmpeg。
    static let preferenceValueURLs = preferenceValueURLs(in: CommandLine.arguments)

    static func preferenceValueURLs(in arguments: [String]) -> Set<URL> {
        Set(arguments.indices.dropFirst().compactMap { index in
            guard arguments[index - 1].hasPrefix("-macrife."),
                  !arguments[index - 1].contains("=") else { return nil }
            return URL(fileURLWithPath: arguments[index]).standardizedFileURL
        })
    }

    /// 有没有打开这个开关。`--dump-stats` / `--dump-stats=x` 两种写法都算打开。
    static func on(_ env: String, _ cli: String) -> Bool {
        if ProcessInfo.processInfo.environment[env] != nil { return true }
        return CommandLine.arguments.contains { $0 == cli || $0.hasPrefix(cli + "=") }
    }

    /// 取一个**带值**的开关：`MP_DUMP_DELAY=3` 或 `--dump-delay=3`。
    /// 两个都没有时返回 nil（调用方自己给默认值）。
    static func value(_ env: String, _ cli: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        let prefix = cli + "="
        return CommandLine.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}

