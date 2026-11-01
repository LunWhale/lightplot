import Foundation

/// 输入清洗。
///
/// **为什么要在编辑时拦，而不是导出时拦。**
/// 图纸只能有 ASCII：DXF 交付物是纯 ASCII，中文会被转义成 `\U+`，
/// 而 CAD 不保证支持那些转义。等到导出才报错时，用户已经输了一堆字，
/// 却不知道是哪一处、也不知道该怎么改。
///
/// 所以在事件入口就把非 ASCII 字符替换掉，并让 `Lint` 同时能报出来
/// （用于打开旧文件时检查）。这是"即时反馈 > 事后报错"。
public enum EventSanitizer {

    /// 把文字压成 ASCII 可打印字符。
    ///
    /// 处理顺序很重要：
    ///   1. 常见标点先做**有意义的替换**（`±` → `+/-`，`©` → `(C)`）
    ///   2. 其余非 ASCII 转成问号 —— 不静默删除，因为"少了几个字"
    ///      比"看到问号"更难排查
    public static func ascii(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)

        let replacements: [Character: String] = [
            "±": "+/-", "×": "x", "÷": "/", "°": "deg",
            "—": "-", "–": "-", "‘": "'", "’": "'",
            "“": "\"", "”": "\"", "…": "...", "·": ".",
            "©": "(C)", "®": "(R)", "™": "(TM)",
            "≤": "<=", "≥": ">=", "≠": "!=", "≈": "~",
            "\u{00A0}": " ",       // 不换行空格：PDF 提取时很常见
        ]

        for ch in input {
            if let rep = replacements[ch] {
                out += rep
            } else if let scalar = ch.unicodeScalars.first,
                      ch.unicodeScalars.count == 1 {
                if scalar.value >= 0x20 && scalar.value <= 0x7E {
                    out.append(ch)
                } else if scalar.value == 0x09 {
                    out.append(" ")
                } else {
                    // 非 ASCII：可见地问号，而不是悄悄丢掉
                    out.append("?")
                }
            } else {
                // 组合字符（é 之类）：拆成基础字符后仍非 ASCII → 问号
                out.append("?")
            }
        }
        return out
    }

    /// 判断一段文字是否已是纯 ASCII（`Lint` 用）。
    public static func isASCII(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value <= 0x7E || $0.value == 0x09 }
    }
}
