import Testing
import Foundation
import SwiftUI
import AppKit
@testable import LightPlotCore
@testable import LightPlotUI

/// **应用内的完整流程。**
///
/// 其他人做的测试大多只碰模型层。但用户碰的是窗口：打开文件、拖灯、
/// 改色片、换纸、切场景、导出、关窗。这条测试按那个顺序走一遍，
/// 每一步都经过**真实的视图代码**（`EditorModel` + 画布 + 检查器 +
/// 页面设置面板），而不是直接调底层函数。
///
/// 判据：每一步之后文档都必须合法，且最终导出的 PDF 能打开、尺寸正确。
@MainActor
@Suite("App workflow")
struct AppWorkflowTests {

    private func rigURL() -> URL {
        TestData.workspaceRoot.appendingPathComponent("data/rig.yaml")
    }
    private func scenesURL() -> URL {
        TestData.workspaceRoot.appendingPathComponent("data/scenes.yaml")
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("workflow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func checkValid(_ model: EditorModel, _ stage: String) {
        let errors = model.state.issues.filter { $0.severity == .error }
        #expect(errors.isEmpty,
                Comment(rawValue: "\(stage): "
                        + errors.map { $0.code.rawValue + " " + $0.subject }
                    .joined(separator: " | ")))
    }

    // MARK: 主流程

    @Test("Open → edit → switch scene → change paper → export → reopen")
    func fullWalkthrough() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. 打开真实项目
        let model = EditorModel()
        try model.open(url: rigURL())
        #expect(model.state.doc.fixtures.count == 32)
        #expect(model.state.doc.meta.show == "DEATH OF A SALESMAN")
        checkValid(model, "open")

        // 2. 画布确实产生了绘制指令（不是空壳）
        #expect(model.sheet.ops.count > 500, "the canvas has almost nothing to draw")
        #expect(model.sheet.contentFitsSheet)

        // 3. 点选一台灯 —— 走与 `EditorView.beginDrag` 相同的路径：
        //    视图坐标 → 图纸坐标 → 命中测试 → 分派事件。
        guard let f201 = model.state.doc.fixture(unit: 201),
              let world = Resolver.worldPoint(of: f201, in: model.state.doc) else {
            Issue.record("unit 201 has no world point"); return
        }
        // 视图坐标必须用**模型自己的**变换对（`toView` 收文档坐标，
        // `paperPoint` 返回图纸坐标）。早先用 `state.viewport` 手算，
        // 与模型的自动适配视口不是同一个，于是点哪儿都点不到。
        let viewPoint = model.toView(world)
        let paper = model.paperPoint(viewPoint)
        switch model.hit(paper) {
        case .fixture(let unit):
            model.dispatch(.select(.init(fixtures: [unit])))
            #expect(unit == 201, "clicking on unit 201 hit unit \(unit)")
        case .position(let id):
            Issue.record("clicking the lantern hit the bar '\(id)' instead")
        default:
            Issue.record("clicking the lantern hit nothing")
        }
        #expect(model.state.selection.fixtures.contains(201))

        // 4. 通过检查器改色片与通道
        model.dispatch(.setFixtureGel(unit: 201, gel: "OPEN"))
        // 挑一个没被占用的通道 —— 占用检查是硬门禁（同通道两台灯 = 接线错）
        let used = Set(model.state.doc.fixtures.compactMap { $0.ch })
        let freeCh = (used.max() ?? 0) + 1
        model.dispatch(.setFixtureChannel(unit: 201, ch: freeCh))
        #expect(model.state.doc.fixture(unit: 201)?.gel == "OPEN")
        #expect(model.state.doc.fixture(unit: 201)?.ch == freeCh)
        checkValid(model, "after inspector edits")

        // 5. 拖一台灯（沿杆移动）—— 同样是视图的真实路径
        guard let f202 = model.state.doc.fixture(unit: 202),
              let w202 = Resolver.worldPoint(of: f202, in: model.state.doc) else {
            Issue.record("unit 202 has no world point"); return
        }
        let before202 = model.state.doc.fixture(unit: 202)?.x
        let dragTo = model.toView(w202) + Vec2(40, 0)
        model.dispatch(.moveFixture(unit: 202, to: model.paperPoint(dragTo)))
        let after202 = model.state.doc.fixture(unit: 202)?.x
        #expect(before202 != after202, "dragging along the bar must move it")
        #expect(model.state.doc.fixture(unit: 202)?.pos == f202.pos,
                "dragging along the bar must keep it on the bar")
        checkValid(model, "after drag")

        // 6. 切换场景
        model.loadStatesFromMemory(try LightingStateCodec.decodeYAML(
            Data(contentsOf: scenesURL())))
        #expect(model.hasStates)
        model.selectState("kitchen")
        #expect(model.activeState?.id == "kitchen")
        #expect(model.sheet.ops.count > 500)
        #expect(!model.sheet.labelsWereOmitted, "the kitchen sheet should keep its labels")
        model.selectState("boston")
        #expect(model.activeState?.id == "boston")
        model.selectState(nil)
        #expect(model.activeState == nil)

        // 7. 换纸幅（走真实的分派路径）+ 换比例
        model.dispatch(.setPaper(PaperSize(standard: .a0, orientation: .landscape)))
        #expect(model.state.layout.paper.widthMM == 1189)
        #expect(model.sheet.contentFitsSheet)
        model.dispatch(.setPaper(.a1))
        model.dispatch(.setScale(25))

        // 8. 导出
        let pdf = dir.appendingPathComponent("plan.pdf")
        let written = model.exportPDF(to: pdf)
        #expect(written != nil)
        let size = try FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int ?? 0
        #expect(size > 40_000, "PDF only \(size) bytes")

        let sec = dir.appendingPathComponent("section.pdf")
        #expect(model.exportSectionPDF(to: sec) != nil)

        let csvDir = dir.appendingPathComponent("tables")
        try FileManager.default.createDirectory(at: csvDir, withIntermediateDirectories: true)
        let csvs = model.exportSchedules(to: csvDir)
        #expect(csvs.count >= 4)

        // 9. 存盘 → 重开 → 内容仍在
        let lpx = dir.appendingPathComponent("project.lpx")
        #expect(model.save(to: lpx))
        let reopened = EditorModel()
        try reopened.open(url: lpx)
        #expect(reopened.state.doc.fixture(unit: 201)?.gel == "OPEN",
                "the edited gel must survive the round trip")
        #expect(reopened.state.doc.fixture(unit: 201)?.ch == freeCh)

        // 10. PDF 尺寸必须是真实 A1（用 PDFKit 读回来量）
        #expect(PDFText.firstPage(of: pdf).map { abs($0.widthMM - 841) < 0.5 } == true,
                "exported plan is not A1")
        #expect(PDFText.firstPage(of: sec).map { abs($0.widthMM - 420) < 0.5 } == true,
                "exported section is not A3")
    }

    /// 每一步都要能撤销回去 —— 用户会改错，撤销是他的安全带。
    @Test("Every edit in the walkthrough can be undone")
    func everyEditIsUndoable() throws {
        let model = EditorModel()
        try model.open(url: rigURL())
        let base = String(decoding: try DocumentCodec.encodeJSON(model.state.doc),
                          as: UTF8.self)

        model.dispatch(.setFixtureGel(unit: 201, gel: "OPEN"))
        model.dispatch(.setFixtureChannel(unit: 201, ch: 42))
        model.dispatch(.setFixtureAim(unit: 201, aim: 45))
        model.dispatch(.setFixturePurpose(unit: 201, purpose: "CHANGED"))
        model.dispatch(.setPositionTrim(id: "LX 1", trim: 4200))
        model.dispatch(.setPaper(PaperSize(standard: .a2, orientation: .landscape)))
        model.dispatch(.setScale(50))

        var guardCount = 0
        while model.state.canUndo && guardCount < 100 {
            model.dispatch(.undo)
            guardCount += 1
        }
        let back = String(decoding: try DocumentCodec.encodeJSON(model.state.doc),
                          as: UTF8.self)
        #expect(back == base, "undo did not restore the opened document")
    }

    /// 用户改了数据但没存就关窗 —— 必须有"未保存"信号。
    @Test("Editing marks the document dirty and saving clears it")
    func dirtyFlag() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = EditorModel()
        try model.open(url: rigURL())
        #expect(!model.isDirty, "a freshly opened document is not dirty")

        model.dispatch(.setFixtureGel(unit: 201, gel: "OPEN"))
        #expect(model.isDirty, "an edit must mark the document dirty")

        let url = dir.appendingPathComponent("saved.lpx")
        #expect(model.save(to: url))
        #expect(!model.isDirty, "saving must clear the dirty flag")

        model.dispatch(.setFixtureGel(unit: 201, gel: "L201"))
        #expect(model.isDirty)
        model.dispatch(.undo)
        // 撤销回到已保存状态 —— 是否清除脏标记是产品选择；
        // 这里只要求"不会崩、状态自洽"。
        #expect(model.state.doc.fixture(unit: 201)?.gel == "OPEN")
    }

    /// 画布上的每一层都要真的画出来（防止某一层悄悄变成空）。
    @Test("The canvas emits every layer the sheet needs")
    func canvasLayers() throws {
        let model = EditorModel()
        try model.open(url: rigURL())
        let layers = Set(model.sheet.ops.compactMap { $0.layer })
        for required in ["BORDER", "TITLEBLK", "TB_TEXT", "LEGEND", "NOTES",
                         "FIXTURE", "FIXTURE_TXT", "TRUSS", "ZONE", "SEAT"] {
            #expect(layers.contains(required), "layer \(required) is missing from the canvas")
        }
    }

    /// 剖面页也要能画、能导。
    @Test("The section page is reachable from the app")
    func sectionPage() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = EditorModel()
        try model.open(url: rigURL())
        model.page = .section
        #expect(model.page == .section)

        let url = dir.appendingPathComponent("s.pdf")
        #expect(model.exportSectionPDF(to: url) != nil)
        guard let page = PDFText.firstPage(of: url) else {
            Issue.record("the section PDF is unreadable"); return
        }
        #expect(abs(page.widthMM - 420) < 0.5)
        let text = PDFText.lines(page).joined(separator: " ")
        #expect(text.contains("SECTION A-A"))
        #expect(text.contains("TRIM SCHEDULE"))
        #expect(text.contains("SIGHTLINE"))
    }
}
