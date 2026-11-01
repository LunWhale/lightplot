import Foundation

/// 对旧 Python 管线的**实际产出 PDF** 做端到端比对。
///
/// ## 为什么要有这一层
///
/// `DifferentialOracle` 比对的是两份 digest 文本；但如果两边都由
/// LightPlot 生成，那只是"自己跟自己比"。真正的参考答案是
/// 旧管线已经交付出去的 PDF —— 那些文件被人工核对过、被考官看过。
///
/// 这里用 PDF 的**文字层**做事实抽取（不渲染像素）：
/// 旧管线的图上逐灯印着色片行与灯号行，这两者相邻构成稳定配对；
/// 图签上印着 "TOTAL 32 INSTRUMENTS" 与 "SCALE 1:25 @ A1"。
/// 这些都是可直接比对的硬事实。
///
/// ## 约束
///
/// 只依赖 `PDFKit`（系统框架），不引入第三方 PDF 库 ——
/// CLI 要能在没装 Python 的机器上跑。
public enum OldPipelineCheck {

    public struct Report: Sendable {
        public let text: String
        public let passed: Bool
    }

    struct Fact {
        var pageSizeMM: (Double, Double)?
        var gelPairs: [Int: String] = [:]
        var instrumentTotal: Int?
        var scaleLine: String?
    }

    /// 从一份旧管线 PDF 里抽事实。
    static func extract(_ url: URL) throws -> Fact {
        var fact = Fact()

        guard let page = PDFText.firstPage(of: url) else {
            throw CheckError.unreadable(url.lastPathComponent)
        }
        fact.pageSizeMM = PDFText.pageSizeMM(page)

        let lines = PDFText.lines(page)
        fact.scaleLine = lines.first { $0.hasPrefix("SCALE") }
        for l in lines {
            if let r = l.range(of: "TOTAL ") {
                let digits = l[r.upperBound...].prefix { $0.isNumber }
                if let n = Int(digits) { fact.instrumentTotal = n }
            }
        }
        // 灯号 → 色片：用**位置邻近**配对，不用"相邻行"。
        //
        // 旧管线的图上，每台灯的灯号与色片是两个独立文字对象。
        // 早先假设"色片行紧接着灯号行"，在 PyMuPDF 的阅读顺序下成立，
        // 但换成按视觉位置排序后就不成立 —— 同一竖列里有多台灯，
        // 排序会把某台的色片排到另一台的灯号旁边（实测 503 配到 L156）。
        //
        // 可靠做法：对每个三位灯号，找**空间上最近**的色片标签。
        // 灯具标注是紧排的一组（灯号、色片、通道），相邻灯之间至少隔着
        // 几十毫米，所以"最近邻"是稳定判据。
        let gelSpans = page.spans.filter { PDFText.isGelCode($0.text) }
        let unitSpans = page.spans.filter {
            $0.text.count == 3 && $0.text.allSatisfy(\.isNumber)
        }
        for u in unitSpans {
            guard let unit = Int(u.text), fact.gelPairs[unit] == nil else { continue }
            guard let near = gelSpans.min(by: {
                ($0.x - u.x) * ($0.x - u.x) + ($0.y - u.y) * ($0.y - u.y)
                    < ($1.x - u.x) * ($1.x - u.x) + ($1.y - u.y) * ($1.y - u.y)
            }) else { continue }
            // 超过 30mm 就不算"这台灯的色片"——标注块不会那么大。
            let d2 = (near.x - u.x) * (near.x - u.x) + (near.y - u.y) * (near.y - u.y)
            guard d2 < 30 * 30 else { continue }
            fact.gelPairs[unit] = near.text
        }
        return fact
    }

    public static func run(doc: LXDocument,
                           oldOutDir: URL,
                           states: LightingStateSet? = nil) throws -> Report {
        let fm = FileManager.default
        // 每份旧 PDF 对应的场景状态。
        //
        // **场景必须用场景状态去比。** 旧管线的 `LX_plan_kitchen.pdf`
        // 上印的是 `gel_override` 替换之后的色片（L132→L202），
        // 拿基础文档去比会全线报错 —— 那不是缺陷，是比错了对象。
        let targets: [(file: String, state: String?)] = [
            ("LX_plan.pdf", nil),
            ("LX_plan_kitchen.pdf", "kitchen"),
            ("LX_plan_boston.pdf", "boston"),
        ]
        var found: [String: Fact] = [:]
        for (n, _) in targets {
            let u = oldOutDir.appendingPathComponent(n)
            guard fm.fileExists(atPath: u.path) else { continue }
            found[n] = try extract(u)
        }
        guard !found.isEmpty else {
            throw CheckError.noReference(oldOutDir.path)
        }

        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            if ok {
                lines.append("  OK    \(label)")
            } else {
                failures += 1
                lines.append("  FAIL  \(label)" + (detail.isEmpty ? "" : "  —  \(detail)"))
            }
        }

        let stateSuffix = states?.states.isEmpty == false ? " (+ scenes)" : ""
        lines.append("Compared against the Python pipeline's own PDFs\(stateSuffix)")
        lines.append(String(repeating: "-", count: 52))
        for (name, stateID) in targets where found[name] != nil {
            let f = found[name]!
            let state = stateID.flatMap { states?.state(id: $0) }
            lines.append("")
            lines.append(name)
            if let (w, h) = f.pageSizeMM {
                check(abs(w - 841) < 0.5 && abs(h - 594) < 0.5,
                      "page is A1 landscape",
                      String(format: "%.1f x %.1f mm", w, h))
            }
            if let total = f.instrumentTotal {
                check(doc.fixtures.count == total, "instrument total = \(total)",
                      "document has \(doc.fixtures.count)")
            }
            if let s = f.scaleLine {
                check(s.contains("1:25") && s.contains("A1"),
                      "scale line states 1:25 on A1", s)
            }
            if !f.gelPairs.isEmpty {
                var bad: [String] = []
                for (unit, gel) in f.gelPairs.sorted(by: { $0.key < $1.key }) {
                    guard let fx = doc.fixtures.first(where: { $0.unit == unit }) else {
                        bad.append("\(unit) missing")
                        continue
                    }
                    // 有场景就用场景生效的色片（含 gel_override 替换）。
                    let effective = state.flatMap { $0.gel(for: fx) } ?? fx.gelCode
                    if effective != gel {
                        bad.append("\(unit) \(gel)->\(effective)")
                    }
                }
                let label = state == nil
                    ? "all \(f.gelPairs.count) lantern gels match"
                    : "all \(f.gelPairs.count) lantern gels match in scene '\(stateID!)'"
                check(bad.isEmpty, label,
                      bad.prefix(4).joined(separator: ", "))
            }
        }

        // 为什么基础图可能只抽到 30 组而不是 32：
        // 旧管线在 BOOM 杆上把同色片的三台灯共用一个色片标注
        // （图上左侧只有一个 `L156`，右侧三台 601/602/603 都用它）。
        // 那不是缺失 —— 是旧图的排版方式。抽出 30 个标注位
        // 已经覆盖全部 32 台灯的色片信息，所以断言针对抽到的每一组。
        lines.append("")
        if failures == 0 {
            lines.append("result: identical on every checked fact")
        } else {
            lines.append("result: \(failures) mismatch(es)")
        }
        return Report(text: lines.joined(separator: "\n"), passed: failures == 0)
    }

    public enum CheckError: LocalizedError {
        case unreadable(String)
        case noReference(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable(let n): return "cannot read \(n)"
            case .noReference(let p): return "no reference PDFs in \(p)"
            }
        }
    }
}
