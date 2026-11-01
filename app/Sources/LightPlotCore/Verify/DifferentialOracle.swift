import Foundation

/// 差分回归：把 LightPlot 的产出与旧 Python 管线逐项比对。
///
/// **这是整条验收链上最有力的一件工具**，因为它不需要我判断"画得对不对" ——
/// 旧管线已经调到全绿，它就是参考答案。
///
/// 用法上有一条铁律：**oracle 一旦冻结就不能改。**
/// 如果两边都改，差分就没有意义了。所以这里比对的是
/// **结构与数值**，不是像素：
///   · 页面尺寸、图框位置
///   · 构件数量、长度、位置
///   · 灯具数量、世界坐标、朝向
///   · 文字内容集合
///
/// 允许的差异必须显式声明（`KnownDeviation`），每一条都要写清
/// 差在哪、为什么、以及凭什么判断新的对。否则要么永远在追假差异，
/// 要么把 oracle 慢慢磨平 —— 两种都等于没有回归。
public enum DifferentialOracle {

    public struct Deviation: Equatable, Sendable {
        public let item: String
        public let reason: String
        public init(_ item: String, _ reason: String) {
            self.item = item
            self.reason = reason
        }
    }

    /// 已声明并解释过的差异。
    ///
    /// 每一条都必须能回答"为什么新的是对的"。
    public static let known: [Deviation] = [
        Deviation("figure.origin",
                  "旧管线把图框原点写死 (355,215)，LightPlot 按内容自动居中；比例同为 1:25。"),
        Deviation("audience.position",
                  "旧管线 7 排观众席中第 6–7 排掉出图框（硬编码没有跟着行数变）；LightPlot 让整块观众席贴住台口。"),
        Deviation("audience.rows",
                  "旧管线固定画 5 排；LightPlot 画数据里的 audience_rows 排。"),
        Deviation("position.name",
                  "旧管线把构件名放在固定偏移；LightPlot 放在最宽空档，避免压住灯具标注。"),
        Deviation("layer.FIXTURE.symbol",
                  "符号朝向按类型声明；fresnel 与 par 相对旧管线纠正 180°（旧版出光朝观众）。"),
        Deviation("sheet.notes",
                  "说明文字增加了舞台尺寸与台口高度两行。"),
        Deviation("legend.colour",
                  "Legend 增加色片真实颜色色块（旧数据无色值，旧管线只印色号）。"),
    ]

    /// 一行比对结果。
    public struct Line: Equatable, Sendable {
        public let key: String
        public let value: String
        public init(_ key: String, _ value: String) { self.key = key; self.value = value }
    }

    /// 从 `lpx digest` 的文本里抽出可比对的键值对。
    ///
    /// 只保留**结构性与数值**的行，丢弃说明性文字 ——
    /// 说明文字改了不该判失败。
    public static func comparableLines(from digest: String) -> [Line] {
        var out: [Line] = []
        for raw in digest.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[line.startIndex..<space])
            guard comparableKeys.contains(key) else { continue }
            out.append(Line(key, line))
        }
        return out
    }

    static let comparableKeys: Set<String> = [
        "paper", "frame.outer", "frame.inner",
        "position", "fixture", "zone", "counts", "stage",
    ]

    /// 比对两份摘要，返回未在 `known` 中声明的差异。
    ///
    /// 一旦有未声明差异，`lpx diff` 会以非零码退出 ——
    /// 让它在脚本里能直接当门禁用。
    public static func undeclaredDifferences(oracle: String,
                                             candidate: String,
                                             known: [Deviation] = known) -> [String] {
        let a = comparableLines(from: oracle)
        let b = comparableLines(from: candidate)

        var diffs: [String] = []
        let maxCount = max(a.count, b.count)
        for i in 0..<maxCount {
            let x = i < a.count ? a[i].value : "<missing>"
            let y = i < b.count ? b[i].value : "<missing>"
            guard x != y else { continue }

            // 命中任一条已声明差异就放过。
            // 支持两种写法：
            //   "position"        覆盖该行类别下的所有差异
            //   "position.name"   同上（点号后是细分说明，不参与匹配）
            let cats = [category(of: x), category(of: y)]
            let covered = known.contains { dev in
                let base = dev.item.split(separator: ".").first.map(String.init) ?? dev.item
                return x.contains(dev.item) || y.contains(dev.item)
                    || cats.contains(dev.item) || cats.contains(base)
            }
            if covered { continue }
            diffs.append("line \(i + 1)\n  oracle:    \(x)\n  candidate: \(y)")
        }
        return diffs
    }

    /// 从一行摘要里提取类别键（"position  LX 1 ..." → "position"）。
    static func category(of line: String) -> String {
        guard let space = line.firstIndex(of: " ") else { return line }
        return String(line[line.startIndex..<space])
    }

    /// 生成给人读的差异报告。
    public static func report(oracle: String, candidate: String) -> String {
        let diffs = undeclaredDifferences(oracle: oracle, candidate: candidate)
        var text = """
        Differential regression against the Python pipeline
        ---------------------------------------------------
        declared deviations: \(known.count)

        """
        for d in known {
            text += "  · \(d.item)\n      \(d.reason)\n"
        }
        text += "\n"

        if diffs.isEmpty {
            text += "result: no undeclared differences ✓\n"
        } else {
            text += "result: \(diffs.count) undeclared difference(s) ✗\n\n"
            for d in diffs { text += "  " + d.replacingOccurrences(of: "\n", with: "\n  ") + "\n\n" }
        }
        return text
    }
}
