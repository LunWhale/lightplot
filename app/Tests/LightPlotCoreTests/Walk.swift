import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 把所有界面能触发的动作，在无头环境里真实执行一遍。
@MainActor
@Suite("UI action walkthrough")
struct UIActionWalkthroughTests {

    @Test("Every toolbar and inspector action leaves the document valid")
    func everyAction() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        var failures: [String] = []

        func check(_ label: String) {
            let errors = model.state.issues.filter { $0.severity == .error }
            if !errors.isEmpty {
                failures.append("\(label): " + errors.map { $0.code.rawValue }.joined(separator: ","))
            }
        }

        // 1. 输入演出信息
        for f in MetaField.allCases {
            model.dispatch(.setMeta(f, "TEST " + f.rawValue.uppercased()))
            check("setMeta \(f.rawValue)")
        }

        // 2. 输入场地
        for (f, v) in [(StageField.width, 15000.0), (.depth, 9000.0),
                       (.gridHeight, 8000.0), (.prosceniumHeight, 6500.0),
                       (.prosceniumX, -1200.0), (.audienceRows, 7.0),
                       (.audienceRowDepth, 560.0), (.audienceRake, 160.0)] {
            model.dispatch(.setStage(f, v))
            check("setStage \(f.rawValue)")
        }

        // 3. 换纸幅与比例
        for p in PaperSize.all {
            model.dispatch(.setPaper(p))
            check("setPaper \(p.name)")
        }
        model.dispatch(.setPaper(.a1))
        model.dispatch(.setScale(25))
        check("setScale")

        // 4. 加三种构件
        for t in PositionType.allCases {
            model.addBar(type: t)
            check("addBar \(t.rawValue)")
        }

        // 5. 选一根杆，挂每种灯
        if let bar = model.state.doc.positions.first(where: { $0.kind == .horizontal }) {
            model.dispatch(.select(.init(positions: [bar.id])))
            for t in model.addableTypes {
                model.addFixture(type: t)
                check("addFixture \(t)")
            }
        }

        // 6. 选中第一台灯，改所有属性
        if let f = model.state.doc.fixtures.first {
            model.dispatch(.select(.init(fixtures: [f.unit])))
            model.dispatch(.setFixtureAim(unit: f.unit, aim: 135))
            model.dispatch(.setFixtureGel(unit: f.unit, gel: model.state.doc.gels[0].code))
            model.dispatch(.setFixtureChannel(unit: f.unit, ch: 200))
            model.dispatch(.setFixturePurpose(unit: f.unit, purpose: "WALKTHROUGH"))
            check("fixture edits")
        }

        // 7. 拖动与旋转
        if let f = model.state.doc.fixtures.first {
            model.dispatch(.moveFixture(unit: f.unit, to: model.state.layout.toSheet(Vec2(0, 2400))))
            check("moveFixture")
        }

        // 8. 加布景三种
        for k in SetPieceKind.allCases {
            model.addSetPiece(kind: k)
            check("addSetPiece \(k.rawValue)")
        }

        // 9. 加光区
        model.addZone()
        check("addZone")

        // 10. 合并两根杆
        let bars = model.state.doc.positions.filter { $0.kind == .horizontal && $0.type == .truss }
        if bars.count >= 2 {
            model.dispatch(.select(.init(positions: [bars[0].id, bars[1].id])))
            model.mergeSelection()
            check("merge")
        }

        // 11. 选中并删除
        if let piece = model.state.doc.setPieces.first {
            model.dispatch(.select(.init(setPieces: [piece.id])))
            model.deleteSelectedExtras()
            check("delete set piece")
        }

        // 12. 切页
        model.switchPage(.section)
        model.switchPage(.plan)
        check("switch page")

        // 13. 导出与保存
        let dir = FileManager.default.temporaryDirectory
        let pdf = dir.appendingPathComponent("walk-\(UUID().uuidString).pdf")
        let sec = dir.appendingPathComponent("walk-sec-\(UUID().uuidString).pdf")
        let lpx = dir.appendingPathComponent("walk-\(UUID().uuidString).lpx")
        defer {
            for u in [pdf, sec, lpx] { try? FileManager.default.removeItem(at: u) }
        }
        #expect(model.exportPDF(to: pdf) != nil, "plan export failed")
        #expect(model.exportSectionPDF(to: sec) != nil, "section export failed")
        #expect(model.save(to: lpx), "save failed")

        // 14. 撤销到初始
        var guardCount = 0
        while model.state.canUndo && guardCount < 500 {
            model.dispatch(.undo)
            guardCount += 1
        }
        #expect(guardCount < 500, "undo did not terminate")

        let text = failures.prefix(5).joined(separator: " | ")
        #expect(failures.isEmpty, Comment(rawValue: "invalid states after: " + text))
    }

    @Test("The app renders both pages without throwing")
    func rendersBothPages() throws {
        let doc = try TestData.realDocument()
        let model = EditorModel(doc: doc)
        for page in EditorModel.SheetPage.allCases {
            model.switchPage(page)
            // 视图本身不需要真的挂到窗口上 —— 只要 sheet/section 是有效的
            #expect(model.sheet.ops.count > 100)
            #expect(model.section.ops.count > 100)
            #expect(model.currentPaperFrame.width > 0)
        }
    }

    @Test("Zoom and pan never produce an invalid viewport")
    func zoomPan() throws {
        let model = EditorModel(doc: try TestData.realDocument())
        model.setCanvasSize(Vec2(900, 700))
        for _ in 0..<50 {
            model.zoom(by: 1.3, around: Vec2(450, 350))
            #expect(model.viewport.zoom.isFinite && model.viewport.zoom > 0)
            model.pan(by: Vec2(17, -23))
        }
        model.zoom(by: 0.0001, around: Vec2(1, 1))
        #expect(model.viewport.zoom > 0)
        model.fitToSheet()
        #expect(model.viewport.zoom.isFinite)
    }
}
