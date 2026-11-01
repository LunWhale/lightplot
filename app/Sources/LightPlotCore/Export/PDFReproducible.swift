import Foundation

/// 把 PDF 变成**逐字节可复现**的。
///
/// ## 为什么需要
///
/// 绘图工具的用户会反复出图：改一盏灯、再出一次、对比。
/// 如果每次输出的字节都不同（因为文件里嵌了生成时间），
/// 那么"图变了"和"只是重新生成了一次"就分不开 ——
/// 没法用 `git diff` 或 `cmp` 判断这一版到底改了什么。
///
/// CoreGraphics 会在 PDF 里写两样随环境变化的东西：
///   · `/CreationDate` `/ModDate` —— 真实时钟
///   · `/ID [ <…> <…> ]` —— 文档唯一标识（PDF 规范要求唯一）
///
/// 这两样都是**文档属性**，不是图面内容。把它们钉成固定值之后，
/// 同一份数据就产出同一串字节。
///
/// ## 为什么可以安全地做字节替换
///
/// CoreGraphics 写出的 Info 字典与 trailer 都是**明文 ASCII**，
/// 只有内容流是压缩的。所以 `D:…` 与 `/ID [ <hex> <hex> ]` 在文件里
/// 各只有一处、形式固定、不含二进制噪声，可以用受限的行内文本替换处理，
/// 不必引入 PDF 库去重写交叉引用表 —— 那才是真正的风险来源。
public enum PDFReproducible {

    /// 固定时间戳（PDF 日期格式）。
    ///
    /// 选 2000-01-01 是因为它明显不是真实时间：一眼就能看出
    /// "这份文件被正规化过"，不会有人把它当成交付日期。
    public static let fixedDate = "D:20000101000000Z"

    /// 就地正规化一个 PDF 文件。
    ///
    /// - Returns: 是否发生了替换（`false` 说明文件本来就没有这些字段）。
    @discardableResult
    public static func normalise(fileAt url: URL) throws -> Bool {
        let original = try Data(contentsOf: url)
        // PDF 的明文部分用 Latin-1 解码是无损的（逐字节一对一）。
        guard let text = String(data: original, encoding: .isoLatin1) else {
            return false
        }
        let patched = normalise(text)
        guard patched != text else { return false }
        guard let out = patched.data(using: .isoLatin1) else { return false }
        try out.write(to: url, options: .atomic)
        return true
    }

    /// 对 PDF 文本做正规化（纯函数，便于测试）。
    public static func normalise(_ text: String) -> String {
        var s = text

        // 1. 日期。**整段替换括号里的值**，不能只替换 `(D:` 之后的部分。
        //
        // 两个曾经踩到的坑：
        //   · `fixedDate` 自带 "D:" 前缀，而键里已经含 "(D:" —— 叠加成
        //     `(D:D:2000…)`，PDF 阅读器照样能读，所以肉眼看不出来。
        //   · CoreGraphics 会把 `/ModDate` 与它的值**拆到两行**：
        //         /ModDate
        //         (D:20261031233515Z00'00')
        //     按行找 `/ModDate (D:` 永远匹配不到 —— 真实时间被留在文件里，
        //     于是"同一份数据两次出图"仍然不同，而这正是本类要解决的问题。
        s = replaceDateValue(s, key: "/CreationDate")
        s = replaceDateValue(s, key: "/ModDate")

        // 2. 文档 ID → 全零。
        //
        // **注意：CoreGraphics 把这两个 hex 分写在两行上**
        //      /ID [ <a9564e07…>
        //      <a9564e07…> ]
        // 早先按 "> <" 找分隔符，跨行就匹配不到，正规化静默失效 ——
        // 而"失效"的表现是"两次输出仍然不同"，很难看出原因。
        // 现在按整段定位：从 `/ID [ <` 到其后的第一个 `> ]`，
        // 中间全部重写，单行与多行两种写法统一成同一结果。
        if let head = s.range(of: "/ID [ <"),
           let tail = s.range(of: "> ]", range: head.upperBound..<s.endIndex) {
            let zero = String(repeating: "0", count: 32)
            let before = String(s[s.startIndex..<head.lowerBound])
            let after = String(s[tail.upperBound...])
            s = before + "/ID [ <" + zero + ">\n<" + zero + "> ]" + after
        }
        return s
    }

    /// 把 `key` 后面那个括号里的日期整段换成 `fixedDate`。
    ///
    /// 不用逐行处理：`/ModDate` 与它的值可能被换行拆开。
    /// PDF 的日期串里不会出现右括号，所以"key 之后第一个 ( 到其后的第一个 )"
    /// 就是完整的值，替换它不会误伤别处。
    private static func replaceDateValue(_ text: String, key: String) -> String {
        guard let k = text.range(of: key) else { return text }
        guard let open = text.range(of: "(", range: k.upperBound..<text.endIndex) else {
            return text
        }
        guard let close = text.range(of: ")", range: open.upperBound..<text.endIndex) else {
            return text
        }
        return String(text[text.startIndex..<open.lowerBound])
            + "(" + fixedDate + ")"
            + String(text[close.upperBound...])
    }
}
