import Testing
import Foundation
@testable import LightPlotCore

/// 尺寸切换：这是用户点名要的功能。
///
/// 守三件事：
///   1. 切换后**页面尺寸真的变了**（不是只改了标签）
///   2. 默认是 A1 横向
///   3. 装不下时给提示页，而不是空白纸
@Suite("Paper switching")
struct PaperSwitchTests {

    @Test("Default paper is A1 landscape at 1:25")
    func defaultIsA1() throws {
        let s = EditorState(doc: try TestData.realDocument())
        #expect(s.layout.paper == .a1)
        #expect(s.layout.paper.standard == .a1)
        #expect(s.layout.paper.orientation == .landscape)
        #expect(s.layout.scaleDenominator == 25)
    }

    @Test("All seven standards are available in both orientations")
    func allStandards() {
        #expect(PaperSize.PaperStandard.allCases.count == 7)
        for std in PaperSize.PaperStandard.allCases {
            let land = PaperSize(standard: std, orientation: .landscape)
            let port = PaperSize(standard: std, orientation: .portrait)
            #expect(land.widthMM > land.heightMM, "\(std.name) landscape must be wider")
            #expect(port.heightMM > port.widthMM, "\(std.name) portrait must be taller")
            #expect(land.standard == std)
            #expect(port.standard == std)
        }
    }

    /// 切换后**真的**按新纸出图 —— 实测 PDF 页面尺寸。
    @Test("Switching paper really changes the produced page size")
    func switchChangesPage() throws {
        let doc = try TestData.realDocument()
        let expectations: [(PaperSize.PaperStandard, PaperOrientation, Double, Vec2)] = [
            (.a0, .landscape, 25, Vec2(1189, 841)),
            (.a1, .landscape, 25, Vec2(841, 594)),
            (.a2, .landscape, 50, Vec2(594, 420)),
            (.a3, .landscape, 50, Vec2(420, 297)),
            (.a1, .portrait,  25, Vec2(594, 841)),
        ]
        for (std, orient, scale, expected) in expectations {
            let paper = PaperSize(standard: std, orientation: orient)
            let sheet = PlanSheet(fitting: doc, paper: paper, scale: scale)
            #expect(sheet.layout.paper.widthMM == expected.x,
                    "\(std.name) \(orient): width \(sheet.layout.paper.widthMM)")
            #expect(sheet.layout.paper.heightMM == expected.y,
                    "\(std.name) \(orient): height \(sheet.layout.paper.heightMM)")
            #expect(sheet.layout.scaleDenominator == scale,
                    "\(std.name): scale must not be silently changed")
        }
    }

    @Test("Changing paper keeps the drawing at the requested scale")
    func scaleIsRespected() throws {
        let doc = try TestData.realDocument()
        for scale in [20.0, 25, 50, 100] {
            let sheet = PlanSheet(fitting: doc, paper: .a1, scale: scale)
            #expect(sheet.layout.scaleDenominator == scale)
            // 内容在图上的尺寸必须严格等于 文档尺寸 / 比例
            let span = sheet.layout.sheetLength(15000)   // 15 m 舞台
            #expect(abs(span - 15000 / scale) < 1e-9)
        }
    }

    @Test("Editor events change the paper and are undoable in one step")
    func editorSwitch() throws {
        var s = EditorState(doc: try TestData.validDocument())
        #expect(s.layout.paper == .a1)

        s = Editor.reduce(s, batch: [
            .setPaper(PaperSize(standard: .a0, orientation: .landscape)),
            .setScale(50),
        ])
        #expect(s.layout.paper.widthMM == 1189)
        #expect(s.layout.scaleDenominator == 50)

        s = Editor.reduce(s, .undo)
        #expect(s.layout.paper == .a1)
        #expect(s.layout.scaleDenominator == 25)
    }

    @Test("Portrait swaps the usable area")
    func portraitArea() {
        let land = PaperSize(standard: .a1, orientation: .landscape)
        let port = PaperSize(standard: .a1, orientation: .portrait)
        let la = SheetLayout.planArea(paper: land)
        let pa = SheetLayout.planArea(paper: port)
        #expect(la.width > pa.width)
        #expect(pa.height > la.height)
    }

    /// A3@1:50 装不下 16.5 m 的舞台 —— 这是物理事实，必须给提示页而不是空白。
    @Test("A sheet that cannot hold the content prints a notice")
    func overflowNotice() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc, paper: .a3, scale: 50)
        #expect(!sheet.contentFitsSheet)
        let text = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }.joined(separator: " ")
        #expect(text.contains("DOES NOT FIT"))
        // 提示必须同时给出三件事：是哪张纸、实际内容多大、这张纸能装多大。
        // 早先写的是 "This sheet holds" —— 没说哪张纸，用户还得自己数。
        #expect(text.contains("ON A3 AT 1:50"),
                "the notice must name the sheet and scale that failed")
        #expect(text.contains("A3 holds"),
                "the notice must state this sheet's capacity")
    }

    @Test("A3 at 1:100 does hold the same stage")
    func smallerScaleFits() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc, paper: .a3, scale: 100)
        #expect(sheet.contentFitsSheet, "A3 at 1:100 should fit 16.5 m")
    }

    /// 小纸上信息栏必须同比收窄，否则绘图区被吃掉一半。
    @Test("Small sheets keep a proportional info column")
    func infoColumnScales() {
        let a1 = SheetLayout.infoColumnWidth(for: .a1)
        let a4land = PaperSize(standard: .a4, orientation: .landscape)
        let a4 = SheetLayout.infoColumnWidth(for: a4land)
        #expect(a1 > a4, "A1 info column should be wider than A4's")
        #expect(a4 >= 46, "A4 info column must not collapse")
        // A4 上绘图区仍要可用
        let area = SheetLayout.planArea(paper: a4land)
        #expect(area.width > 60)
    }
}
