//  TrackInfo.swift
//  MetalPlayer 重建工程 —— 轨道描述（Phase 2）
//
//  原版的这个类型只有骨架：`struct TrackInfo { var displayName: String;
//  var isExternalSubtitle: Bool; func languageDisplayName(String) -> String }`。
//  两个属性与那个方法名是**观测**（来自 `.getter` / `.setter` 符号），但字段全集未知。
//
//  Phase 2 需要它来构菜单（音轨 / 字幕两条菜单要按轨道列表动态生成），
//  所以这里把它补成能用的实现。补的部分按需要加字段，并逐个标注来源。
//
//  为什么字段不能全靠猜：菜单项要显示「第几条 / 编码 / 语言 / 声道」这些信息，
//  而音轨菜单的构造需要**容器里的流索引**才能切轨。所以 `index` 是必须有的。
//
//  与 `RECON-REPORT.md` 的关系：该报告把 `TrackInfo` 归在「观测：struct（元数据访问器 VMa）」
//  一栏 —— 种类是观测，成员是观测，但**字段全集**与函数体是未知。

import Foundation

struct TrackInfo {

    /// 轨道类别。观测：`TrackManager` 有 `audioTracks` / `subtitleTracks` / `videoTracks`
    /// 三个平行数组 —— 所以类别是**分开存**的，不是存在 TrackInfo 里。
    /// 这里带上 `kind` 只是为了方便菜单构造时少传一个参数。
    enum Kind {
        case video
        case audio
        case subtitle
    }

    // MARK: - 观测到的成员

    /// 菜单上显示的名字。
    var displayName: String = ""

    /// 是否来自外挂字幕文件（而非容器内封）。
    var isExternalSubtitle: Bool = false

    /// 把语言码转成可读名。
    ///
    /// 观测到的签名是 `languageDisplayName(_ x0: String) -> String` —— 接受一个字符串。
    /// 那个字符串就是容器里读到的语言码（Matroska 里通常是 ISO 639-2/B 三字母，
    /// 如 `chi` / `jpn` / `eng`）。
    ///
    /// 文案表里能对上的只有三条：`lang_simplified_chinese` / `lang_traditional_chinese` /
    /// `lang_japanese`。其余语言走一个**推断**的小表 —— 原版支持哪些语言无从得知，
    /// 这里只覆盖常见几种，查不到就原样返回语言码（比显示空白强）。
    func languageDisplayName(_ code: String) -> String {
        TrackInfo.languageDisplayName(code)
    }

    // MARK: - Phase 2 补的字段（标注来源）

    /// 容器内的流索引。切轨时用（`av_seek` 之外要靠它挑流）。
    /// **推断**：原版必然需要这个值，但它没有出现在符号表里（可能是私有成员或计算得出）。
    var index: Int = -1

    /// 轨道类别。来源见上面 `Kind` 的注释。
    var kind: Kind = .audio

    /// 编码名（`h264` / `aac` / `ass` / `subrip` …）。由 `avcodec_get_name` 得到。
    var codecName: String = ""

    /// 原始语言码。
    var languageCode: String = ""

    /// 容器里标的轨道标题（Matroska 的 `title` 元数据）。可能为空。
    var title: String = ""

    /// 声道数（音轨才有意义，其它为 0）。
    var channels: Int = 0

    /// 是否为容器标记的默认轨道。
    /// **推断**：文案表里的 `default_bracket` = "[默认]" 说明界面上会给默认轨道加标记。
    var isDefault: Bool = false

    /// 音轨的采样率（其它为 0）。
    var sampleRate: Int = 0

    // MARK: - 构造

    init() {}

    init(index: Int,
         kind: Kind,
         displayName: String,
         codecName: String = "",
         languageCode: String = "",
         title: String = "",
         channels: Int = 0,
         sampleRate: Int = 0,
         isDefault: Bool = false,
         isExternalSubtitle: Bool = false) {
        self.index = index
        self.kind = kind
        self.displayName = displayName
        self.codecName = codecName
        self.languageCode = languageCode
        self.title = title
        self.channels = channels
        self.sampleRate = sampleRate
        self.isDefault = isDefault
        self.isExternalSubtitle = isExternalSubtitle
    }

    /// 生成菜单项标题，形如 `简体中文 · aac (2ch) [默认]`。
    ///
    /// 拼法没有从二进制恢复（是推断），但用的都是观测到的碎片：
    /// 语言名来自 `languageDisplayName`，`[默认]` 来自 `default_bracket`，
    /// 编码与声道来自 FFmpeg 的流信息。
    ///
    /// ┌ 为什么 title 与语言名**二选一**，而不是都显示
    /// │
    /// │ 容器的 `language` 码是**粗粒度**的：简体中文与繁體中文在 Matroska 里
    /// │ 标的都是 `chi` —— 三字母码根本没有区分字形的能力。于是「两个都显示」
    /// │ 会产出实测中出现的这种自相矛盾的条目：
    /// │
    /// │     简体中文 · 繁體中文 · ass
    /// │
    /// │ 而 `title` 恰恰是片方用来区分这两条轨的那一项（实测：
    /// │ 简体中文 / 繁體中文 / 日本語 三条 title 把三条轨分得清清楚楚）。
    /// │ 所以有 title 就用 title，没有才回落到语言名 —— 一个规则，没有特例。
    /// │ 语言码本身仍留在 `languageCode` 里，要看原始值有性能面板的 ① 。
    /// └
    var menuTitle: String {
        var parts: [String] = []
        if !title.isEmpty {
            parts.append(title)
        } else {
            let lang = languageDisplayName(languageCode)
            if !lang.isEmpty { parts.append(lang) }
        }
        if !codecName.isEmpty {
            parts.append(kind == .audio && channels > 0
                         ? "\(codecName) (\(channels)ch)"
                         : codecName)
        }
        if parts.isEmpty { parts.append(displayName.isEmpty ? "轨道 \(index)" : displayName) }
        var text = parts.joined(separator: " · ")
        if isDefault { text += " " + L10n.t("default_bracket") }
        return text
    }

    // MARK: - 语言码表

    /// 语言码 → 可读名。
    ///
    /// 三条来自文案表（**观测**）：简中 / 繁中 / 日。
    /// 其余是**推断**的常见补充；查不到就原样返回语言码，不显示空白。
    static func languageDisplayName(_ code: String) -> String {
        let c = code.lowercased()
        switch c {
        // —— 观测（文案表有对应条目）
        case "chi", "zho", "zh", "zh-hans", "zh_cn", "zh-cn", "chs", "sc":
            return L10n.t("lang_simplified_chinese")
        case "zh-hant", "zh_tw", "zh-tw", "cht", "tc":
            return L10n.t("lang_traditional_chinese")
        case "jpn", "ja", "jp":
            return L10n.t("lang_japanese")

        // —— 推断（常见补充）
        case "eng", "en":  return "English"
        case "kor", "ko":  return "한국어"
        case "fra", "fre", "fr": return "Français"
        case "deu", "ger", "de": return "Deutsch"
        case "spa", "es":  return "Español"
        case "rus", "ru":  return "Русский"
        case "por", "pt":  return "Português"
        case "ita", "it":  return "Italiano"

        case "und", "":    return ""
        default:           return code
        }
    }
}
