import Testing
import Foundation
@testable import LightPlotCore

/// 极端/退化输入：渲染器不能崩、不能画到纸外。
@Suite("Render edge cases")
struct RenderEdgeCaseTests {

    private func renderBoth(_ doc: LXDocument) throws -> (plan: PlanSheet, section: SectionSheet) {
        (PlanSheet(fitting: doc), SectionSheet(fitting: doc))
    }

    private func assertSane(_ s: PlanSheet, _ label: String) {
        let paper = s.layout.paper
        let bounds = Rect(x0: -1, y0: -1, x1: paper.widthMM + 1, y1: paper.heightMM + 1)
        for op in s.ops {
            guard case .text(let t) = op else { continue }
            #expect(bounds.contains(t.origin), "\(label): text '\(t.string)' off paper")
            #expect(t.capMM > 0 && t.capMM < 60, "\(label): absurd cap \(t.capMM)")
            #expect(t.string.unicodeScalars.allSatisfy { $0.value < 0x7F },
                    "\(label): non-ASCII '\(t.string)'")
        }
    }

    private func assertSane(_ s: SectionSheet, _ label: String) {
        let paper = s.layout.paper
        let bounds = Rect(x0: -1, y0: -1, x1: paper.widthMM + 1, y1: paper.heightMM + 1)
        for op in s.ops {
            guard case .text(let t) = op else { continue }
            #expect(bounds.contains(t.origin), "\(label): text '\(t.string)' off paper")
            #expect(t.capMM > 0 && t.capMM < 60, "\(label): absurd cap \(t.capMM)")
        }
    }

    @Test("An empty document renders without crashing")
    func emptyDoc() throws {
        let doc = LXDocument()
        let (p, s) = try renderBoth(doc)
        assertSane(p, "empty/plan")
        assertSane(s, "empty/section")
        #expect(!p.ops.isEmpty, "even an empty doc must draw a frame")
        #expect(!s.ops.isEmpty)
    }

    @Test("A document with no fixtures renders")
    func noFixtures() throws {
        var doc = TestData.validDocument()
        doc.fixtures = []
        let (p, s) = try renderBoth(doc)
        assertSane(p, "nofixtures/plan")
        assertSane(s, "nofixtures/section")
    }

    @Test("A document with no positions renders")
    func noPositions() throws {
        var doc = TestData.validDocument()
        doc.positions = []
        doc.fixtures = []
        let (p, s) = try renderBoth(doc)
        assertSane(p, "nopos/plan")
        assertSane(s, "nopos/section")
    }

    @Test("A tiny stage still produces a sane sheet")
    func tinyStage() throws {
        var doc = TestData.validDocument()
        doc.stage.width = 2000
        doc.stage.depth = 1500
        doc.stage.audienceRows = 0
        doc.positions = [Position(id: "LX 1", kind: .horizontal, type: .truss,
                                  x0: -800, x1: 800, y: 700, trim: 3000)]
        doc.fixtures = [Fixture(unit: 1, pos: "LX 1", x: 0, type: "profile",
                                gel: "L201", ch: 1, purpose: "X", beam: 26)]
        let (p, s) = try renderBoth(doc)
        assertSane(p, "tiny/plan")
        assertSane(s, "tiny/section")
        #expect(p.contentFitsSheet)
    }

    @Test("A huge stage overflows visibly rather than silently")
    func hugeStage() throws {
        var doc = TestData.validDocument()
        doc.stage.width = 60000
        doc.stage.depth = 40000
        let (p, s) = try renderBoth(doc)
        #expect(p.contentFitsSheet == false, "60 m stage must not fit A1 at 1:25")
        assertSane(p, "huge/plan")
        assertSane(s, "huge/section")
    }

    @Test("Zero-height grid does not divide by zero")
    func degenerateStage() throws {
        var doc = TestData.validDocument()
        doc.stage.gridHeight = 0
        doc.stage.prosceniumHeight = 0
        doc.stage.audienceRowDepth = 1
        let (p, s) = try renderBoth(doc)
        assertSane(p, "degenerate/plan")
        assertSane(s, "degenerate/section")
    }

    @Test("A fixture with absurd values does not break layout")
    func absurdFixture() throws {
        var doc = TestData.validDocument()
        doc.fixtures = [
            Fixture(unit: 1, pos: "LX 1", x: 0, type: "profile", aim: 0,
                    gel: "L201", ch: 1, purpose: "X", beam: 0.1),
            Fixture(unit: 2, pos: "LX 1", x: 1000, type: "fresnel", aim: 359.9,
                    gel: "L201", ch: 2, purpose: "Y", beam: 179),
        ]
        let (p, s) = try renderBoth(doc)
        assertSane(p, "absurd/plan")
        assertSane(s, "absurd/section")
    }

    @Test("A very long show name is fitted, not overflowed")
    func longText() throws {
        var doc = TestData.validDocument()
        doc.meta.show = String(repeating: "A VERY LONG SHOW TITLE ", count: 6)
        doc.meta.venue = String(repeating: "VENUE ", count: 30)
        let (p, s) = try renderBoth(doc)
        assertSane(p, "longtext/plan")
        assertSane(s, "longtext/section")
        // 图签里的字必须落在纸内
        let paper = p.layout.paper
        for op in p.ops {
            guard case .text(let t) = op, t.layer == "TB_TEXT" else { continue }
            #expect(t.origin.x >= 0 && t.origin.x <= paper.widthMM)
        }
    }

    @Test("Set pieces with zero size do not crash the section")
    func degenerateSetPieces() throws {
        var doc = TestData.validDocument()
        doc.setPieces = [
            SetPiece(kind: .rect, x0: 0, y0: 4000, x1: 0, y1: 4000),
            SetPiece(kind: .line, x0: 100, y0: 100, x1: 100, y1: 100),
            SetPiece(kind: .stair, x0: 0, y0: 0, x1: 500, y1: 0, steps: 0),
        ]
        let (_, s) = try renderBoth(doc)
        assertSane(s, "degenerateset/section")
    }

    /// 每张纸都用**适合它的比例**验证：小纸配小比例。
    /// 这不是"放宽标准"—— 而是真实用法：A3 上画 15m 舞台本来就该用 1:50。
    @Test("Every paper size renders sanely at an appropriate scale")
    func allPapers() throws {
        let combos: [(PaperSize, Double)] = [
            (.a0, 25), (.a1, 25), (.a2, 50), (.a3, 50),
        ]
        for (paper, scale) in combos {
            var doc = TestData.validDocument()
            doc.meta.scale = scale
            let sheet = PlanSheet(fitting: doc, paper: paper)
            assertSane(sheet, "paper/\(paper.name)@1:\(Int(scale))")
            #expect(sheet.layout.scaleDenominator == scale,
                    "\(paper.name): scale must not be changed silently")
        }
    }

    /// 装不下时必须给出**可见的提示**，而不是一张空白纸。
    @Test("An overflowing sheet explains itself instead of going blank")
    func overflowIsExplained() throws {
        var doc = TestData.validDocument()
        doc.stage.width = 60000
        doc.stage.depth = 40000

        let plan = PlanSheet(fitting: doc)
        #expect(!plan.contentFitsSheet)
        let planText = plan.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }.joined(separator: " ")
        #expect(planText.contains("DOES NOT FIT"),
                "an overflowing plan must say so, not render blank")

        let section = SectionSheet(fitting: doc)
        #expect(!section.contentFitsSheet)
        let secText = section.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }.joined(separator: " ")
        #expect(secText.contains("DOES NOT FIT"),
                "an overflowing section must say so too")

        // 提示页仍然必须是可打印的 A1/A3
        #expect(plan.layout.paper == .a1)
        #expect(section.layout.paper == .a3)
    }
}
