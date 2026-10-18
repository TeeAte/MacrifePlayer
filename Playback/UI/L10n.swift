//  L10n.swift
//  MetalPlayer 重建工程 —— 本地化取词
//
//  原版把 162 条界面文案放在 `Resources/{en,zh-Hans}.lproj/Localizable.strings`。
//  `make_project.py` 的 `copy_resources()` 把这两份原样拷进重建工程的 bundle，
//  所以这里直接走 `Bundle.main`，语言跟系统走，不需要自己判断用哪份。
//
//  为什么不用 `NSLocalizedString` 宏：
//    宏要求 key 是**字面量**（编译期要能提取）。本工程很多 key 是拼出来的
//    （`rife_status_\(mode.rawValue)`、`rife_worker_\(n)`），宏用不了。
//    所以统一走 `Bundle.localizedString(forKey:value:table:)` 这个运行时接口。
//
//  一个必须知道的坑：这个接口在**查不到 key 时返回 key 本身**，不报错。
//  也就是说文案缺失会静默变成界面上的 `rife_foo_bar`。所以本文件带一个
//  开发期的缺失检测（见 `reportMissingKeys`），启动时扫一遍，缺了就在日志里点名。

import Foundation

enum L10n {

    /// 取一条文案。查不到时返回 key 本身（Foundation 的既有行为）。
    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: nil, table: nil)
    }

    /// 取一条带 `%@` / `%d` 占位符的文案。
    ///
    /// 注意参数顺序必须与文案里占位符出现顺序一致，且数量不能错 ——
    /// `String(format:)` 对不上会读到野内存，这在 Objective-C 时代是崩溃常客。
    /// 所以本工程里凡是用到带占位符的文案，都在下面 `Placeholders` 里集中登记，
    /// 不在调用点手写 key。
    static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    // MARK: - 带占位符的文案（集中登记，避免调用点写错顺序）

    enum Placeholders {
        /// `"version_format"` = "版本 %@" / "Version %@"
        static func version(_ v: String) -> String { L10n.t("version_format", v) }

        /// `"external_subtitle_loaded_format"` = "已加载外挂字幕：%@"
        static func externalSubtitleLoaded(_ name: String) -> String {
            L10n.t("external_subtitle_loaded_format", name)
        }

        /// `"window_capture_found_windows_format"` = "找到 %d 个窗口"
        static func windowCaptureFound(_ n: Int) -> String {
            L10n.t("window_capture_found_windows_format", n)
        }

        /// `"rife_worker_count"` = "%d 个 核心" / "%d Cores"
        static func workerCount(_ n: Int) -> String {
            L10n.t("rife_worker_count", n)
        }

        /// `"copyright_format"` = "© %d MetalPlayer。保留所有权利。"
        static func copyright(_ year: Int) -> String {
            L10n.t("copyright_format", year)
        }
    }

    /// 原版有、但**本工程不再显示**的文案 key（Phase 2 热切换之后退役）。
    ///
    /// 留这份清单是为了下次有人翻到 `Localizable.strings` 里的这几条时，
    /// 能立刻知道「不是漏用了，是刻意不用了」，而不是当成 bug 去补回来。
    ///
    /// 退役原因：原版对影响管线的设置一律提示「下次重启播放器后生效」；
    /// 本工程改成管线就地重建（`PlaybackEngine.reloadInPlace()`），
    /// 弹窗换成状态胶囊里的一句话，所以这几条提示不再出现。
    static let retiredKeys: [String] = [
        "rife_settings_saved",                  // 「设置已保存」弹窗标题
        "restart_next_launch_with_mode",        // "%@\n下次重启播放器后生效。"
        "rife_model_selected_restart",          // "已选择：%@\n下次重启播放器后生效。"
        "rife_resolution_selected_restart",     // 「已选择 RIFE 模型配置：%@。…」
        "rife_worker_selected_restart",         // 「已选择 RIFE 核心 数量：%d 个。…」
        "drba_model_selected_restart",
        "drba_resolution_selected_restart",
    ]

    // MARK: - 开发期：文案缺失检测

    /// 本工程会在菜单/控制条里实际用到的 key。启动时（`MP_TRACE` 打开时）
    /// 逐个查一遍，把查不到的打印出来。
    ///
    /// 为什么要做这件事：`Localizable.strings` 是原版 app 的资源，重建工程只是
    /// 原样拷贝 —— 一旦拷贝漏了、或者哪份 .lproj 没进 bundle，界面会静默显示成
    /// 一堆 key，而不会报任何错。这个自检把「静默」变成「一行日志」。
    static let allUsedKeys: [String] = [
        // 文件
        "file", "open_video_ellipsis", "open_playlist_ellipsis", "save_playlist_ellipsis",
        "show_playlist", "close_current_video", "recent_open", "no_recent_open",
        "clear_recent_open", "open_video", "open_playlist", "save_playlist",
        "choose_video_file", "open", "cancel", "apply",
        // 音轨 / 字幕
        "audio_tracks", "no_audio_tracks", "subtitles", "disable_subtitles",
        "external_subtitle", "default_bracket", "lang_simplified_chinese",
        "lang_traditional_chinese", "lang_japanese", "authorize_external_subtitle",
        "authorize_external_subtitle_message", "authorize_subtitle",
        "open_video_before_subtitle", "external_subtitle_loaded_format",
        "external_subtitle_load_failed", "subtitle_file_not_found",
        // 模型 / RIFE
        "model", "drba_model", "model_version", "model_resolution",
        "rife_model", "rife_heavy_model", "rife_workers",
        "rife_lite_mode", "rife_full_mode",
        "rife_worker_6", "rife_worker_8", "rife_worker_10", "rife_worker_12",
        "rife_worker_count",
        "rife_model_425_lite", "rife_model_425_high_quality",
        "rife_model_426_high_quality", "rife_model_426_heavy",
        "rife_resolution_sweet", "rife_resolution_normal",
        "rife_resolution_quality", "rife_resolution_top",
        "frame_transition_detection",
        // 档位
        "rife_mode_off", "rife_mode_2x", "rife_mode_3x", "rife_mode_4x",
        "rife_mode_5x", "rife_mode_60",
        "rife_status_off", "rife_status_2x", "rife_status_3x", "rife_status_4x",
        "rife_status_5x", "rife_status_60",
        "rife_off", "rife_on", "metalfx_off", "anime4k_off", "anime4k_off_detail",
        "anime4k_panel_title", "anime4k_preset", "off",
        "decode_hw", "decode_sw", "playback_normal",
        // 其它
        "no_video_opened", "drop_video_or_open", "playlist", "delete_short",
        "video", "ok", "close", "quit", "about_metalplayer", "quit_metalplayer",
        "version_format", "app_description", "developer_info",
        "support_metalplayer", "donate_about_text", "wechat_alipay",
    ]

    /// 返回「查不到的 key」列表。空数组表示文案链路完好。
    static func missingKeys(_ keys: [String] = allUsedKeys) -> [String] {
        keys.filter { Bundle.main.localizedString(forKey: $0, value: nil, table: nil) == $0 }
    }

    /// 把本地化自检结果打到 stderr（开发期用，默认静默）。
    static func reportMissingKeys() {
        guard DevFlag.on("MP_TRACE", "--trace") else { return }
        let missing = missingKeys()
        let lang = Bundle.main.preferredLocalizations.first ?? "?"
        let line = "[L10n] 语言=\(lang) 已登记=\(allUsedKeys.count) 缺失=\(missing.count)"
            + (missing.isEmpty ? "" : "\n[L10n] 缺失的 key: \(missing.joined(separator: ", "))")
            + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

// MARK: - 本工程**新增**的文案（原版文案表里没有的）

/// 原版 `Localizable.strings` 里查不到、由重建工程自己引入的文案。
///
/// ⚠️ 为什么不能往 `Localizable.strings` 里加 key：
/// `MetalPlayerRecon/Resources/{en,zh-Hans}.lproj/Localizable.strings` 是
/// `_reverse/make_project.py` 的 `copy_resources()` 每次生成工程时从
/// 「Original APP.app」**覆盖拷贝**过来的 —— 往里加的 key 会在下次重跑
/// `make_project.py` 时被整份冲掉，而且不会有任何报错（`L10n.t` 查不到 key 时
/// 返回 key 本身，界面上只会静默显示成 `performance_monitor`）。
///
/// 所以这批文案直接在代码里写死，并按**首选语言**做中英二选一。
///
/// 覆盖范围：
///   · 新增的菜单项（「性能监看」）
///   · 热切换的状态胶囊（「正在就地应用 / 已就地生效」）
///   · `PlaybackSettings.Key.humanTitle`（胶囊里要说出改的是哪一项）
///
/// ⚠️ **不含**性能面板的正文。面板里那一堆（`视频` / `像素` / `队列` / `音画` / `资源` …）
/// 刻意保持单一语言：它是读数面板，一行一个标签加数字，双语化会让
/// `StatsPanelView` 的渲染代码被文案包裹一层、可读性明显变差，
/// 收益（一个调试向面板的英文标签）不值这个代价。这是**已知的取舍**，
/// 不是漏做 —— 详见 `StatsPanelView` 的文件头。
enum MPText {

    /// 首选语言是中文（含 `zh-Hans` / `zh-Hant` / `zh`）就用中文，否则英文。
    static func t(_ zh: String, _ en: String) -> String {
        let lang = Bundle.main.preferredLocalizations.first ?? "zh"
        return lang.hasPrefix("zh") ? zh : en
    }
}
