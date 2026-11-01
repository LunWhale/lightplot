import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// **应用与命令行必须是同一个程序。**
///
/// 图形界面和 `lpx` 是同一核心的两个外壳。如果它们对同一份数据
/// 产出不同的图，那么用户看到的东西和他交付的东西就不是一回事 ——
/// 这类缺陷最难发现，因为两边各自"看起来都对"。
///
/// 这里用**逐字节比较**：两边都写 PDF，正规化掉时间戳与文档 ID 之后，
/// `Data` 必须完全相同。比"视觉相似"强得多，也比"元素数量相同"强得多。
///
/// （时间戳与 `/ID` 是 PDF 规范要求随文件变化的字段，不是图面内容 ——
/// 正规化由 `PDFReproducible` 负责，见它的注释。）
@MainActor
@Suite("App matches CLI")
struct AppMatchesCLITests {

    private func rigURL() -> URL {
        TestData.workspaceRoot.appendingPathComponent("data/rig.yaml")
    }

    private func scenesURL() -> URL {
        TestData.workspaceRoot.appendingPathComponent("data/scenes.yaml")
    }

    private func tmp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("appcli-\(UUID().uuidString)-\(name)")
    }

    /// 应用里"打开 → 直接导出"必须与 CLI 的 `render` 字节一致。
    @Test("The app's plan PDF is byte-identical to the CLI's")
    func planBytesMatch() throws {
        // CLI 路径：独立读 YAML、补色、按 A1@1:25 建图、写 PDF
        let cliDoc = try DocumentCodec.decodeYAML(Data(contentsOf: rigURL()))
        var cli = cliDoc
        _ = GelLibrary.fillMissingColours(in: &cli)
        let cliURL = tmp("cli-plan.pdf")
        try SheetPDF.write(PlanSheet(fitting: cli), to: cliURL)

        // 应用路径：用 EditorModel 打开同一个文件
        let model = EditorModel()
        try model.open(url: rigURL())
        let appURL = tmp("app-plan.pdf")
        _ = model.exportPDF(to: appURL)

        try PDFReproducible.normalise(fileAt: cliURL)
        try PDFReproducible.normalise(fileAt: appURL)
        let a = try Data(contentsOf: cliURL)
        let b = try Data(contentsOf: appURL)
        if a != b {
            // 失败时留证据：把两份都拷出来，便于看清到底哪个字节不同
            try? a.write(to: URL(fileURLWithPath: "/tmp/DIAG_cli_section.pdf"))
            try? b.write(to: URL(fileURLWithPath: "/tmp/DIAG_app_section.pdf"))
        }
        #expect(a.count == b.count,
                "sizes differ: CLI \(a.count) vs app \(b.count)")
        #expect(a == b, "the app and the CLI must produce the same bytes")
        try? FileManager.default.removeItem(at: cliURL)
        try? FileManager.default.removeItem(at: appURL)
    }

    /// 剖面图同理。
    @Test("The app's section PDF is byte-identical to the CLI's")
    func sectionBytesMatch() throws {
        var cli = try DocumentCodec.decodeYAML(Data(contentsOf: rigURL()))
        _ = GelLibrary.fillMissingColours(in: &cli)
        let cliURL = tmp("cli-section.pdf")
        try SheetPDF.write(SectionSheet(fitting: cli), to: cliURL)

        let model = EditorModel()
        try model.open(url: rigURL())
        let appURL = tmp("app-section.pdf")
        _ = model.exportSectionPDF(to: appURL)

        try PDFReproducible.normalise(fileAt: cliURL)
        try PDFReproducible.normalise(fileAt: appURL)
        let a = try Data(contentsOf: cliURL)
        let b = try Data(contentsOf: appURL)
        if a != b {
            // 失败时留证据：把两份都拷出来，便于看清到底哪个字节不同
            try? a.write(to: URL(fileURLWithPath: "/tmp/DIAG_cli_section.pdf"))
            try? b.write(to: URL(fileURLWithPath: "/tmp/DIAG_app_section.pdf"))
        }
        #expect(a.count == b.count,
                "sizes differ: CLI \(a.count) vs app \(b.count)")
        #expect(a == b, "the app and the CLI must produce the same bytes")
        try? FileManager.default.removeItem(at: cliURL)
        try? FileManager.default.removeItem(at: appURL)
    }

    /// 场景图也要一致 —— 应用的"场景"是视图状态，不能悄悄改文档。
    @Test("Scene sheets from the app match the CLI's")
    func sceneBytesMatch() throws {
        let cliDoc = try DocumentCodec.decodeYAML(Data(contentsOf: rigURL()))
        let states = try LightingStateCodec.decodeYAML(Data(contentsOf: scenesURL()))

        let model = EditorModel()
        try model.open(url: rigURL())
        model.loadStatesFromMemory(states)

        for st in states.states {
            var cli = cliDoc
            _ = GelLibrary.fillMissingColours(in: &cli)
            let cliURL = tmp("cli-\(st.id).pdf")
            try SheetPDF.write(
                PlanSheet(fitting: cli, paper: .a1, scale: 25, lightingState: st),
                to: cliURL)

            model.selectState(st.id)
            let appURL = tmp("app-\(st.id).pdf")
            _ = model.exportPDF(to: appURL)

            try PDFReproducible.normalise(fileAt: cliURL)
            try PDFReproducible.normalise(fileAt: appURL)
            let a = try Data(contentsOf: cliURL)
            let b = try Data(contentsOf: appURL)
            #expect(a == b, "scene '\(st.id)': app and CLI differ")
            try? FileManager.default.removeItem(at: cliURL)
            try? FileManager.default.removeItem(at: appURL)
        }
        model.selectState(nil)
    }

    /// 应用打开真实旧数据之后，文档必须仍然通过校验 —— 没有静默改动。
    @Test("Opening the real data leaves the document clean")
    func openKeepsDocumentClean() throws {
        let model = EditorModel()
        try model.open(url: rigURL())

        let errors = model.state.issues.filter { $0.severity == .error }
        #expect(errors.isEmpty,
                Comment(rawValue: errors.map { $0.code.rawValue }.joined(separator: ",")))

        // 打开不该产生撤销点
        #expect(model.state.canUndo == false)
        #expect(model.state.doc.fixtures.count == 32)
        #expect(model.state.doc.positions.count == 7)
    }

    /// 打开 → 保存 → 重开，文档必须完全等价。
    @Test("A round trip through the app preserves the document")
    func saveRoundTrip() throws {
        let model = EditorModel()
        try model.open(url: rigURL())
        let before = try DocumentCodec.encodeJSON(model.state.doc)

        let url = tmp("roundtrip.lpx")
        #expect(model.save(to: url))

        let reopened = EditorModel()
        try reopened.open(url: url)
        let after = try DocumentCodec.encodeJSON(reopened.state.doc)

        #expect(before == after, "saving and reopening must not change the document")
        try? FileManager.default.removeItem(at: url)
    }
}
