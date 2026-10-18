//  SubtitleFormat.swift
//  MetalPlayer 重建工程 —— Phase 3 外挂字幕格式适配
//
//  libass 的 `ass_read_memory` **只认 ASS/SSA 方言**。网上流传的外挂字幕里，
//  SRT 占绝大多数，VTT 次之，ASS 反而是少数。所以外挂这条路必须带一层转换。
//
//  三件事，按发生顺序：
//    ① 编码探测   —— 中文字幕有大量 GB18030 / Big5 的，直接按 UTF-8 读会全是乱码
//    ② 格式识别   —— ASS/SSA 原样透传（一个字节都不动）；SRT / VTT 转
//    ③ 文本转义   —— SRT 的换行与花括号要按 ASS 的规矩转写
//
//  为什么不做「更聪明的自动识别」：转换错了比不转更糟 —— 用户看到的是一堆
//  时间码糊在画面上。所以这里只认三种明确的格式，认不出来就返回 nil，
//  让调用方如实报「这个格式不支持」，而不是猜。

import Foundation
import CoreFoundation

enum SubtitleFormat {

    /// 一段字幕。
    struct Cue {
        var start: Double
        var end: Double
        var text: String
    }

    /// 把外挂字幕文件的内容转成 libass 能吃的 ASS 字节。
    ///
    /// - Returns: nil 表示「认不出这个格式」或「解不出任何一条」。
    static func toASS(data: Data, path: String) -> [UInt8]? {
        guard let text = decodeText(data) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()

        // ASS / SSA：原样透传。**不做任何整理** —— 这类文件里全是精调的样式与
        // override tag，动一个字符都可能改变观感。
        if ext == "ass" || ext == "ssa" || looksLikeASS(text) {
            var out = text
            if !out.hasSuffix("\n") { out += "\n" }
            return Array(out.utf8)
        }

        // SRT 与 VTT 共用同一个时序解析器（理由见 parseTimed 的注释）。
        let cues = parseTimed(text)
        guard !cues.isEmpty else { return nil }
        return Array(buildASS(cues).utf8)
    }

    /// 支持的文件扩展名（给文件选择面板用）。
    static let supportedExtensions = ["ass", "ssa", "srt", "vtt", "txt"]

    // MARK: - ① 编码探测

    /// 字节流 → 字符串。
    ///
    /// 顺序有讲究：UTF-8 优先（最严，不会误判），其次带 BOM 的 UTF-16（有 BOM 就不会错），
    /// 再往后才是 GB18030 / Big5 —— 这两个是宽松编码，几乎任何字节流都能「解出」
    /// 一堆汉字，所以必须排在最后，否则会把正常的 UTF-8 文件解成乱码。
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return stripBOM(s) }

        // UTF-16 的 BOM
        let head = [UInt8](data.prefix(2))
        if head == [0xFF, 0xFE] || head == [0xFE, 0xFF] {
            if let s = String(data: data, encoding: .utf16) { return stripBOM(s) }
        }

        for enc in [CFStringEncodings.GB_18030_2000, .big5] {
            let nsEnc = String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(enc.rawValue)))
            if let s = String(data: data, encoding: nsEnc) { return s }
        }
        return nil
    }

    private static func stripBOM(_ s: String) -> String {
        s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
    }

    // MARK: - ② 格式识别

    private static func looksLikeASS(_ s: String) -> Bool {
        let head = s.prefix(400)
        return head.contains("[Script Info]") || head.contains("[V4+ Styles]")
             || head.contains("[V4 Styles]") || head.contains("[Events]")
    }

    // MARK: - ③ 解析

    /// SRT 与 VTT 的时序块长得几乎一样（`时间 --> 时间`，下一行起是正文），
    /// 所以用同一个解析器。差别只在 VTT 多几种时间码写法与行内标记。
    ///
    /// 策略：**不依赖「块之间用空行分隔」**。SRT 规范是那样，但实际文件里经常
    /// 多一个少一个空行。这里改成「逐行扫，遇到带 `-->` 的行就开一条 cue，
    /// 直到下一条 `-->` 或文件结束」。
    ///
    /// ┌ 空行不能无脑吃掉（踩过）
    /// │
    /// │ 上面那条规则单独用会出事：SRT 每条 cue 前面还有一个**序号行**，
    /// │ 而序号行既不是时间行也不是正文 —— 于是它会被当成上一条 cue 的正文收进去：
    /// │
    /// │     Dialogue: …,\N外部第一句 白色\N\N2      ← 末尾这个 2 就是下一条的序号
    /// │
    /// │ 表现是「单行字幕渲染成两行、叠图数 3 变 6」。所以遇到空行要看一眼后面：
    /// │ 跳过空行后若是**时间行**或**纯数字序号**，说明这是块与块之间的分隔，
    /// │ 正文到此为止；否则是正文内部的空行，保留。
    /// └
    private static func parseTimed(_ text: String) -> [Cue] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
                        .components(separatedBy: "\n")

        var cues: [Cue] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let range = parseTimeRange(line) else { i += 1; continue }

            // 收集正文，直到「下一条时间行」或「块分隔空行」
            var body: [String] = []
            var j = i + 1
            while j < lines.count {
                if parseTimeRange(lines[j]) != nil { break }
                if isBlank(lines[j]) {
                    // 跳过连续空行，看后面是不是下一条 cue 的开头
                    var k = j
                    while k < lines.count, isBlank(lines[k]) { k += 1 }
                    if k >= lines.count { break }
                    if parseTimeRange(lines[k]) != nil || isCueIndex(lines[k]) { break }
                }
                body.append(lines[j])
                j += 1
            }

            let text = body.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                cues.append(Cue(start: range.0, end: range.1,
                                text: stripMarkup(text)))
            }
            i = j
        }
        return cues
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// SRT 的序号行：整行只有一个数字。
    ///
    /// 只认「整行都是数字」是刻意的 —— 正文里单独一行写「2」是合法的
    ///（想想台词就是数字的场景），但那属于「空行之后的数字」才误判；
    /// 而这种组合在真实字幕里几乎不会出现，代价可以接受。
    private static func isCueIndex(_ line: String) -> Bool {
        let s = line.trimmingCharacters(in: .whitespaces)
        return !s.isEmpty && s.allSatisfy { $0.isNumber }
    }

    /// `00:00:01,000 --> 00:00:03,000` / `00:01.000 --> 00:03.000 position:50%`
    private static func parseTimeRange(_ line: String) -> (Double, Double)? {
        guard line.contains("-->") else { return nil }
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }

        let left = parts[0].trimmingCharacters(in: .whitespaces)
        // VTT 允许在第二个时间码后面跟 cue settings（position / align…），切掉
        let rightField = parts[1].trimmingCharacters(in: .whitespaces)
        let right = rightField.components(separatedBy: " ").first ?? ""

        guard let s = parseTime(left), let e = parseTime(right) else { return nil }
        return (s, e)
    }

    /// 支持 `H:MM:SS.mmm` / `MM:SS.mmm` / `H:MM:SS,mmm`。小数点与逗号都收。
    private static func parseTime(_ raw: String) -> Double? {
        let norm = raw.replacingOccurrences(of: ",", with: ".")
                      .trimmingCharacters(in: .whitespaces)
        let parts = norm.split(separator: ":").map(String.init)
        guard parts.count >= 2 else { return nil }
        var seconds = 0.0
        for p in parts {
            guard let v = Double(p), v.isFinite else { return nil }
            seconds = seconds * 60 + v
        }
        return seconds
    }

    /// 剥掉 VTT 的行内标记（`<i>` `<c.yellow>` `<00:00:01.000>` 这类）与 HTML 实体。
    private static func stripMarkup(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<[^>]*>", with: "",
                                         options: .regularExpression)
        // VTT 里也可以写成 `{...}` 的 karaoke 标记，但那是 ASS 的语法，
        // 不能在转换期删 —— 交给下游的 ASS 编码阶段处理。
        for (entity, ch) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                             ("&nbsp;", " "), ("&#39;", "'"), ("&quot;", "\"")] {
            out = out.replacingOccurrences(of: entity, with: ch)
        }
        return out
    }

    // MARK: - ④ 生成 ASS

    /// 把 cue 列表拼成一份完整的 ASS。
    ///
    /// 画布定成 1920x1080：libass 会把整个画布等比缩放到实际帧尺寸，所以
    /// 只要**比例**对，字号就跟着帧走 —— 720p 视频上这 64 号字会显示成约 43px，
    /// 是常见外挂字幕的大小。
    private static func buildASS(_ cues: [Cue]) -> String {
        var out = """
        [Script Info]
        ScriptType: v4.00+
        WrapStyle: 0
        ScaledBorderAndShadow: yes
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,64,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,40,40,48,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        for c in cues {
            let body = escapeForASS(c.text)
            out += "Dialogue: 0,\(assTime(c.start)),\(assTime(c.end)),Default,,0,0,0,,\(body)\n"
        }
        return out
    }

    /// 换行 → `\N`；`{` `}` → 转义（否则内容会被当成 override tag 吃掉）。
    private static func escapeForASS(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\n", with: "\\N")
        out = out.replacingOccurrences(of: "{", with: "\\{")
        out = out.replacingOccurrences(of: "}", with: "\\}")
        return out
    }

    /// ASS 的时间格式：`H:MM:SS.cc`，最后两位是**厘秒**。
    ///
    /// 先取整到厘秒再拆时分秒，而不是直接 `%05.2f` —— 后者把 59.999 格式化成
    /// `"60.00"`，产出 `0:00:60.00` 这种畸形时间戳。字幕的结束时间经常正好落在
    /// 整秒上，差一个厘秒就会被 `%f` 的进位带偏，不值得赌下游解析器宽容。
    private static func assTime(_ seconds: Double) -> String {
        let totalCs = Int((max(0, seconds) * 100).rounded())
        let totalS = totalCs / 100
        return String(format: "%d:%02d:%02d.%02d",
                      totalS / 3600, (totalS / 60) % 60, totalS % 60, totalCs % 100)
    }
}
