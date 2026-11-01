import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 端到端：真实数据 → 真实 PDF → 重新打开验证。
///
/// 这一组测试守的是"别处都对了，但产出物是坏的"这一类问题。
/// 之前踩过：`verify.py` 全绿而 PDF 里一个字都没有。
@Suite("End to end")
struct EndToEndTests {

    private func renderPDF(_ doc: LXDocument) throws -> URL {
        let sheet = PlanSheet(fitting: doc)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpx-e2e-\(UUID().uuidString).pdf")
        try SheetPDF.write(sheet, to: url)
        return url
    }

    @Test("The PDF is a real file with content")
    func pdfIsNotTiny() throws {
        let doc = try TestData.realDocument()
        let url = try renderPDF(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        // 32 台灯 + 7 根构件 + 图签的矢量 PDF 不可能只有几 KB。
        // 阈值故意设低 —— 它要抓的是"空文件"，不是压缩率。
        #expect(size > 40_000, "PDF is only \(size) bytes — content is probably missing")
    }

    @Test("The rendered sheet covers every lantern and every gel")
    func sheetCoverage() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)

        let strings = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        for f in doc.fixtures {
            #expect(strings.contains("\(f.unit)"), "unit \(f.unit) missing")
            if let ch = f.ch {
                #expect(strings.contains("\(ch)"), "channel \(ch) missing")
            }
        }
        // 图例只列**图上真正用到**的色片。
        //
        // 早先这里断言"色片表里每一项都必须出现在图上" ——
        // 那条断言为旧行为背书：图例列全本色库（45 项），
        // 而实际只有 5 个在用。列 40 个没用的色片既压爆版面，
        // 又会让装灯的人以为还有别的东西要装。
        let used = Set(doc.fixtures.compactMap { $0.gel })
        for code in used {
            #expect(strings.contains { $0.contains(code) },
                    "gel \(code) is used by a lantern but missing from the legend")
        }
    }

    @Test("Sheet content always fits the paper")
    func fitsPaper() throws {
        let doc = try TestData.realDocument()
        let sheet = PlanSheet(fitting: doc)
        #expect(sheet.contentFitsSheet)

        // 所有绘制指令都必须落在纸张范围内（允许 0.5mm 的线宽溢出）
        let paper = sheet.layout.paper
        let bounds = Rect(x0: -0.5, y0: -0.5,
                          x1: paper.widthMM + 0.5, y1: paper.heightMM + 0.5)
        for op in sheet.ops {
            guard case .text(let t) = op else { continue }
            #expect(bounds.contains(t.origin),
                    "text '\(t.string)' at \(t.origin) is off the paper")
        }
    }

    @Test("A document edited through the editor still exports")
    func editedDocumentExports() throws {
        var state = EditorState(doc: try TestData.realDocument())
        // 做几件真实的编辑动作
        state = Editor.reduce(state, .movePosition(id: "LX 1", by: Vec2(0, 200)))
        state = Editor.reduce(state, .setFixtureAim(unit: 101, aim: 45))
        state = Editor.reduce(state, .addFixture(
            Fixture(unit: 999, type: "fresnel", aim: 90, gel: "L132",
                    purpose: "TEST", beam: 45),
            at: state.layout.toSheet(Vec2(0, 2400))))
        state = Editor.reduce(state, .setScale(25))

        let sheet = PlanSheet(fitting: state.doc)
        #expect(sheet.contentFitsSheet)
        let url = try renderPDF(state.doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 40_000)
    }

    @Test("YAML written by the app is read back identically")
    func yamlRoundTripThroughDisk() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let text = try DocumentCodec.encodeYAML(doc)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpx-rt-\(UUID().uuidString).yaml")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let back = try DocumentCodec.decodeYAML(Data(contentsOf: url))
        #expect(back == doc)
    }
}

/// 保存 / 打开往返。
///
/// 守的是"能编辑但不能存"这一类致命缺口 —— 一个不能保存的编辑器
/// 会让用户每次关窗口都丢工作，而这在功能清单上很容易被漏掉。
@MainActor
@Suite("Document persistence")
struct PersistenceTests {

    @Test("Editing marks the document dirty, saving clears it")
    func dirtyTracking() {
        let model = EditorModel(doc: TestData.validDocument())
        #expect(model.isDirty == false)

        model.dispatch(.movePosition(id: "LX 1", by: Vec2(0, 100)))
        #expect(model.isDirty)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpx-save-\(UUID().uuidString).lpx")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(model.save(to: url))
        #expect(model.isDirty == false)
        #expect(model.documentURL == url)
    }

    @Test("A saved document reopens identically")
    func roundTripThroughFile() throws {
        let model = EditorModel(doc: TestData.validDocument())
        model.dispatch(.setFixtureAim(unit: 101, aim: 45))
        model.dispatch(.movePosition(id: "LX 1", by: Vec2(0, 300)))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpx-rt-\(UUID().uuidString).lpx")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(model.save(to: url))

        // 文件里存的必须与内存中完全一致（逐字段，含 meta 与版面无关的字段）
        let raw = try DocumentCodec.decodeJSON(Data(contentsOf: url))
        #expect(raw == model.state.doc)

        let reopened = EditorModel()
        try reopened.open(url: url)
        #expect(reopened.isDirty == false)
        #expect(reopened.documentURL == url)

        // 打开时会补全色片颜色（设计如此：旧数据没有 RGB）。
        // 补全只填空缺，不覆盖已有值，所以其余字段必须逐项相等。
        #expect(reopened.state.doc.meta == model.state.doc.meta)
        #expect(reopened.state.doc.stage == model.state.doc.stage)
        #expect(reopened.state.doc.positions == model.state.doc.positions)
        #expect(reopened.state.doc.fixtures == model.state.doc.fixtures)
        #expect(reopened.state.doc.zones == model.state.doc.zones)
        for gel in reopened.state.doc.gels {
            let original = model.state.doc.gels.first { $0.code == gel.code }
            #expect(original != nil)
            #expect(gel.name == original?.name)
            // OPEN 在新文档里没有 RGB，打开后应被补上白色
            if original?.rgb == nil {
                #expect(gel.rgb != nil, "gel \(gel.code) colour should be filled on open")
            } else {
                #expect(gel.rgb == original?.rgb, "existing colour must not be overwritten")
            }
        }
    }

    @Test("Opening a legacy rig.yaml does not claim ownership of it")
    func openingYAMLDoesNotMarkAsSavedFile() throws {
        // 关键语义：从旧管线的 rig.yaml 打开后，documentURL 必须是 nil。
        // 否则一次 Cmd-S 就会把旧文件的注释和排版全部覆盖掉。
        let model = EditorModel()
        try model.open(url: TestData.rigYAML)
        #expect(model.documentURL == nil,
                "opening rig.yaml must not become its save target")
        #expect(model.state.doc.fixtures.count == 32)
    }

    @Test("Opening a legacy YAML fills gel colours without overwriting")
    func openingFillsColours() throws {
        let model = EditorModel()
        try model.open(url: TestData.rigYAML)
        // 旧数据没有 RGB；打开后应当被补上
        let missing = model.state.doc.gels.filter { $0.rgb == nil }
        #expect(missing.isEmpty, "still missing: \(missing.map(\.code))")
    }

    @Test("Saving in place fails before the first save")
    func saveInPlaceRequiresURL() {
        let model = EditorModel(doc: TestData.validDocument())
        #expect(model.saveInPlace() == false)
    }

    @Test("A corrupt file does not crash and does not replace the document")
    func corruptFileIsSafe() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lpx-bad-\(UUID().uuidString).lpx")
        try? Data("this is not a document".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let model = EditorModel(doc: TestData.validDocument())
        let before = model.state.doc
        #expect(throws: (any Error).self) {
            try model.open(url: url)
        }
        #expect(model.state.doc == before, "a failed open must not alter the document")
    }
}
