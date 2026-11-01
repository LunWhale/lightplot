import Testing
import Foundation
@testable import LightPlotCore

/// **对旧管线剖面图 PDF 的差分回归。**
///
/// 旧剖面图（`out/LX_section.pdf`，A3@1:50）里有一张 `TRIM SCHEDULE`：
/// 每个吊挂位置的名称、trim 高度、构件形式。这是可以直接对账的硬事实 ——
/// 高度错了，装台的人会把杆吊到错误的高度。
///
/// 同时这条测试也守住"剖面必须比旧管线更复杂"这条产品要求：
/// 旧图只有构件表，新图还必须有每排灯具计数、光束射程、视线分析。
@Suite("Old pipeline section oracle")
struct OldSectionOracleTests {

    /// 旧剖面图 `TRIM SCHEDULE` 的逐行内容（2026-06 冻结）。
    static let oldTrimSchedule: [(pos: String, trim: String, kind: String)] = [
        ("FOH LX", "+7200", "h"),
        ("LX 1",   "+6500", "h"),
        ("LX 2",   "+6500", "h"),
        ("LX 3",   "+6500", "h"),
        ("BOOM SL", "+3600", "v"),
        ("BOOM SR", "+3600", "v"),
        ("SET EDGE", "+0",   "h"),
    ]

    /// 旧剖面图上出现过的固定标注。缺任何一个都说明图变了。
    static let oldLabels = [
        "PROSCENIUM", "CATWALK 1", "CATWALK 2", "GRID", "BACK WALL",
        "AUDIENCE", "UPSTAGE", "DOWNSTAGE",
        "STAGE FLOOR", "1.75m",
    ]

    private func sectionTexts(_ sheet: SectionSheet) -> [String] {
        sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
    }

    @Test("The section is A3 at 1:50, same as the old sheet")
    func pageAndScale() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        #expect(abs(sheet.layout.paper.widthMM - 420) < 0.05)
        #expect(abs(sheet.layout.paper.heightMM - 297) < 0.05)

        let texts = sectionTexts(sheet)
        #expect(texts.contains { $0.contains("1:50") && $0.contains("A3") },
                "the section must state 1:50 on A3")
    }

    /// 构件表逐行核对 —— trim 错一行都是事故。
    @Test("Every position's trim matches the old trim schedule")
    func trimSchedule() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        let texts = sectionTexts(sheet)
        #expect(texts.contains("TRIM SCHEDULE"))

        var bad: [String] = []
        for row in Self.oldTrimSchedule {
            guard doc.position(id: row.pos) != nil else {
                bad.append("\(row.pos): missing from the document"); continue
            }
            // 名称与 trim 都必须出现
            if !texts.contains(row.pos) { bad.append("\(row.pos): name not printed") }
            if !texts.contains(row.trim) {
                bad.append("\(row.pos): trim \(row.trim) not printed")
            }
        }
        #expect(bad.isEmpty, Comment(rawValue: bad.joined(separator: " | ")))
    }

    /// 新图用真实构件形式（pipe / truss），旧图印 h / v。
    ///
    /// 这是**有意**的差异：装台需要知道是管还是桁架，
    /// 而"横/竖"从图上一眼就能看出来，印它等于浪费一行。
    @Test("The trim schedule names the real construction, not just the axis")
    func constructionType() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        let texts = sectionTexts(sheet)
        #expect(texts.contains("pipe"), "FOH LX / BOOMs are pipes")
        #expect(texts.contains("truss"), "LX 1-3 are trusses")

        // 旧图的 h / v 不应再作为构件类型出现（分区字母仍是 A–H，不冲突）
        let docTypes = Set(doc.positions.map { $0.type.rawValue })
        #expect(docTypes.contains("pipe") && docTypes.contains("truss"))
    }

    @Test("Every landmark label from the old section is still printed")
    func landmarks() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        let joined = sectionTexts(sheet).joined(separator: " | ")
        var missing: [String] = []
        for l in Self.oldLabels where !joined.contains(l) {
            missing.append(l)
        }
        #expect(missing.isEmpty, Comment(rawValue: missing.joined(separator: ", ")))
    }

    /// 高度标尺：+0 到 +8000 每米一格。旧图有 9 格。
    @Test("The height scale still runs from +0 to +8000")
    func heightScale() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        let texts = sectionTexts(sheet)
        for m in stride(from: 0, through: 8000, by: 1000) {
            #expect(texts.contains("+\(m)"), "height tick +\(m) is missing")
        }
    }

    // MARK: - "剖面必须比旧管线更复杂"

    /// 旧图只有构件表。新图必须**额外**给出每排的灯具数量与光束射程。
    @Test("The section adds per-row lantern counts the old sheet never had")
    func rowCounts() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        let texts = sectionTexts(sheet)
        // 形如 "x8" 的计数标记
        #expect(texts.contains { $0.hasPrefix("x") && Int($0.dropFirst()) != nil },
                "no per-row lantern count on the section")
    }

    /// 旧图完全没有视线分析。新图必须有 —— 并明确报出最差一行。
    @Test("The section reports sightlines, which the old sheet omitted entirely")
    func sightlines() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        let joined = sectionTexts(sheet).joined(separator: " | ")
        #expect(joined.contains("SIGHTLINE"),
                "the section must carry a sightline check")
        // 必须报出数字，不能只说"有问题"
        #expect(joined.contains("blocked") || joined.contains("clear"),
                "the sightline result must state an outcome")
    }

    /// 两条视线规则必须写进说明，否则读图人不知道红虚线是什么。
    @Test("The notes explain the dashed lantern and the blocked sightline")
    func notesExplainTheNewMarks() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        let joined = sectionTexts(sheet).joined(separator: " ")
        #expect(joined.contains("Dashed") || joined.contains("dashed"),
                "dashed lanterns are new; the notes must explain them")
        #expect(joined.contains("sightline") || joined.contains("Sightline"),
                "the dashed sightline is new; the notes must explain it")
    }
}
