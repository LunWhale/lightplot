import Testing
import Foundation
@testable import LightPlotCore

/// **对旧管线真实 PDF 的差分回归。**
///
/// 这是整条验收链上最有力的一件工具 —— 它不需要我判断"画得对不对"：
/// 旧管线（`src/*.py`，7,890 行，已调到全绿）的输出 PDF 就是参考答案。
///
/// ## 事实从哪里来
///
/// 从 `out/LX_plan*.pdf` 的**可提取文字层**里读出来的，
/// 不是从 YAML 重算的 —— 否则就变成"自己跟自己比"。
/// 抽取脚本的产物已硬编码在下面，并注明来源，所以即使旧管线被删掉，
/// oracle 依然冻结可用。
///
/// 抽取规则：色片行（`L###` / `OPEN` / `R####`）后紧邻的三位灯号行
/// 构成一条"灯号 → 色片"事实。三份 PDF（基础 / kitchen / boston）
/// 的灯号→色片映射完全相同，因为旧管线从不读 `scenes.yaml` 的
/// `levels`，只在 CSV 里应用替换。
@Suite("Old pipeline PDF oracle")
struct OldPDFOracleTests {

    /// 旧管线 A1 平面图里逐灯印出的色片，按灯号索引。
    ///
    /// 来源：`out/LX_plan.pdf`（PyMuPDF 提取，2026-06 冻结）。
    static let oldPDFGels: [(unit: String, gel: String)] = [
        ("101", "L201"), ("102", "L201"), ("103", "L201"), ("104", "L201"),
        ("105", "L201"), ("106", "L201"),
        ("201", "L132"), ("202", "L132"), ("203", "L132"), ("204", "L132"),
        ("205", "L132"), ("206", "L132"),
        ("301", "L201"), ("302", "L201"), ("303", "L201"), ("304", "L201"),
        ("401", "OPEN"), ("402", "OPEN"), ("403", "OPEN"), ("404", "OPEN"),
        ("501", "L119"), ("502", "L119"), ("503", "L119"),
        ("601", "L156"), ("602", "L156"), ("603", "L156"),
        ("701", "OPEN"), ("702", "OPEN"),
        ("801", "OPEN"), ("802", "OPEN"),
        ("901", "OPEN"), ("902", "L103"),
    ]

    /// 旧管线图签上印的纸张与比例。
    static let oldPaperMM = (w: 841.0, h: 594.0)
    static let oldScaleLine = "SCALE 1:25  @  A1"
    static let oldInstrumentTotal = 32

    @Test("Every lantern keeps the same gel the old pipeline printed")
    func gelsMatchOldPDF() throws {
        let doc = try TestData.realDocument()
        var mismatches: [String] = []
        for (unit, gel) in Self.oldPDFGels {
            guard let n = Int(unit), let f = doc.fixtures.first(where: { $0.unit == n }) else {
                mismatches.append("unit \(unit): missing from the document")
                continue
            }
            if (f.gel ?? "OPEN") != gel {
                mismatches.append("unit \(unit): old PDF says \(gel), document has \(f.gel ?? "OPEN")")
            }
        }
        #expect(mismatches.isEmpty, Comment(rawValue: mismatches.joined(separator: " | ")))
    }

    /// 旧 PDF 上没有的灯，新图也不许多出来。
    @Test("The document has no lantern the old PDF did not print")
    func noExtraLanterns() throws {
        let doc = try TestData.realDocument()
        let old = Set(Self.oldPDFGels.compactMap { Int($0.unit) })
        let extra = Set(doc.fixtures.map(\.unit)).subtracting(old)
        #expect(extra.isEmpty,
                "lanterns \(extra.sorted()) exist only in the new document")
    }

    @Test("The page is exactly A1 and the scale line is honest")
    func pageMatches() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)

        // 纸张（0.05mm 容差：PDF 用 pt 表示，换算回来有浮点残差）
        #expect(abs(sheet.layout.paper.widthMM - Self.oldPaperMM.w) < 0.05)
        #expect(abs(sheet.layout.paper.heightMM - Self.oldPaperMM.h) < 0.05)

        // 比例行：旧管线写 "SCALE 1:25  @  A1"（双空格）。
        // 新管线分成两处（说明栏一行 + 图签一格），这里比对语义而不是格式。
        let texts = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        #expect(texts.contains { $0.contains("1:25") && $0.contains("A1") },
                "no line states 1:25 on A1")
    }

    /// 旧 PDF 印的是 "TOTAL 32 INSTRUMENTS"。
    @Test("The instrument total agrees with the old title block")
    func instrumentTotal() throws {
        let doc = try TestData.realDocument()
        #expect(doc.fixtures.count == Self.oldInstrumentTotal)

        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        let texts = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        #expect(texts.contains { $0.contains("32") },
                "the sheet never states the instrument total")
    }

    /// 每台灯在图面上都要出现：灯号 + 色片。
    @Test("Every lantern and its gel appear on the sheet")
    func everyLanternPrinted() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        let texts = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        var missing: [String] = []
        for f in doc.fixtures {
            if !texts.contains(where: { $0 == "\(f.unit)" }) {
                missing.append("unit \(f.unit)")
            }
            if let gel = f.gel, !texts.contains(where: { $0.contains(gel) }) {
                missing.append("gel \(gel) (unit \(f.unit))")
            }
        }
        #expect(missing.isEmpty, Comment(rawValue: missing.joined(separator: " | ")))
    }

    /// 旧 PDF 图例列出 5 个色片 + OPEN，与实际用到的完全一致。
    ///
    /// 这条顺带验证"图例只列在用的色片"这个决定是对的 ——
    /// 旧管线也是这么做的。
    @Test("The legend matches the gel set the old PDF listed")
    func legendMatchesOld() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)

        // 旧 PDF 的 COLOUR LIST 段落
        let oldLegend: Set<String> = ["L201", "OPEN", "L132", "L119", "L156", "L103"]

        var newLegend = Set<String>()
        for op in sheet.ops {
            guard case .text(let t) = op, t.layer == "LEGEND" else { continue }
            let head = t.string.components(separatedBy: "  ").first ?? ""
            if head == "OPEN" { newLegend.insert(head); continue }
            guard head.count >= 2, "LR".contains(head.first!),
                  head.dropFirst().allSatisfy(\.isNumber) else { continue }
            newLegend.insert(head)
        }
        #expect(newLegend == oldLegend,
                "old listed \(oldLegend.sorted()), new lists \(newLegend.sorted())")
    }

    // MARK: - 对真实 PDF 的端到端比对（跑的是 OldPipelineCheck）

    /// 直接跑 `lpx verify-old` 背后的逻辑，对着**真实的旧管线 PDF**。
    ///
    /// 这条才是"端到端"：读 `out/*.pdf` 的文字层，逐灯核对色片。
    /// 若参考文件不在（例如别人 clone 时没带 `out/`），跳过而不是失败 ——
    /// 但会打印说明，不让"跳过"变成"以为验过了"。
    @Test("End-to-end check against the real old pipeline PDFs")
    func endToEndAgainstRealPDFs() throws {
        let root = TestData.workspaceRoot
        let outDir = root.appendingPathComponent("out")
        let plan = outDir.appendingPathComponent("LX_plan.pdf")
        guard FileManager.default.fileExists(atPath: plan.path) else {
            print("note: out/LX_plan.pdf not present — skipped the PDF-level check")
            return
        }

        let doc = try TestData.realDocument()
        let scenes = try LightingStateCodec.decodeYAML(
            Data(contentsOf: root.appendingPathComponent("data/scenes.yaml")))
        let r = try OldPipelineCheck.run(doc: doc, oldOutDir: outDir, states: scenes)

        #expect(r.passed, Comment(rawValue: "\n" + r.text))
        // 三份图都要真的比到，不能因为文件缺失而"空过"
        #expect(r.text.contains("LX_plan.pdf"))
        #expect(r.text.contains("LX_plan_kitchen.pdf"))
        #expect(r.text.contains("LX_plan_boston.pdf"))
        #expect(r.text.contains("lantern gels match"))
        #expect(r.text.contains("identical on every checked fact"))
    }

    /// 场景图必须用场景状态去比 —— 旧图印的是替换后的色片。
    @Test("Scene sheets are compared against the scene's gels, not the base ones")
    func sceneComparisonUsesState() throws {
        let root = TestData.workspaceRoot
        let outDir = root.appendingPathComponent("out")
        guard FileManager.default.fileExists(
            atPath: outDir.appendingPathComponent("LX_plan_kitchen.pdf").path) else {
            print("note: no kitchen reference PDF — skipped")
            return
        }
        let doc = try TestData.realDocument()
        let scenes = try LightingStateCodec.decodeYAML(
            Data(contentsOf: root.appendingPathComponent("data/scenes.yaml")))

        let withState = try OldPipelineCheck.run(doc: doc, oldOutDir: outDir, states: scenes)
        #expect(withState.passed)

        // 拿基础文档去比场景图**必然**失败 —— 证明比对真的用了状态，
        // 而不是碰巧一致。
        let without = try OldPipelineCheck.run(doc: doc, oldOutDir: outDir, states: nil)
        #expect(!without.passed,
                "comparing scene sheets without scene state must fail — otherwise the check is not reading the overrides")
    }

    /// 构件名必须一字不差 —— 这些是现场用语，改名等于沟通失败。
    @Test("Every position name the old PDF printed still exists")
    func positionNames() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        let texts = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        // 旧 PDF 上出现过的构件名
        let expected = ["FOH LX", "LX 1", "LX 2", "LX 3", "BOOM SL", "BOOM SR"]
        for name in expected {
            #expect(texts.contains(name), "position '\(name)' is missing from the sheet")
        }
    }
}
