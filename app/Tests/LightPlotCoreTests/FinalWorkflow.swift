import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 一次真实的新项目全流程：从空白到可交付图纸。
@MainActor
@Suite("New project workflow")
struct NewProjectWorkflowTests {

    @Test("A blank project can be built into a deliverable sheet")
    func fromScratch() throws {
        // 1. 新文档，输入真实条件
        var s = EditorState(doc: LXDocument())
        s = Editor.reduce(s, .setMeta(.show, "THE VISIT"))
        s = Editor.reduce(s, .setMeta(.playwright, "DURRENMATT"))
        s = Editor.reduce(s, .setMeta(.venue, "SCHOOL STUDIO"))
        s = Editor.reduce(s, .setMeta(.designer, "STUDENT NAME"))
        s = Editor.reduce(s, .setStage(.width, 10000))
        s = Editor.reduce(s, .setStage(.depth, 7000))
        s = Editor.reduce(s, .setStage(.gridHeight, 6500))
        s = Editor.reduce(s, .setStage(.prosceniumHeight, 5500))
        s = Editor.reduce(s, .setStage(.audienceRows, 5))
        s = Editor.reduce(s, .setStage(.audienceRowDepth, 550))
        s = Editor.reduce(s, .setStage(.audienceRake, 450))

        // 2. 灯具类型与色片（真空文档没有这些）
        s.doc.types = [
            "profile": .init(label: "Profile / ERS 750W", watt: 750, role: "FACE"),
            "fresnel": .init(label: "Fresnel 650W", watt: 650, role: "WASH"),
            "par": .init(label: "PAR 500W", watt: 500, role: "SIDE"),
        ]
        s.doc.gels = GelLibrary.all.map { GelLibrary.gel(from: $0) }

        // 3. 布两根杆
        s = Editor.reduce(s, .addPosition(Position(id: "FOH", kind: .horizontal, type: .pipe,
                                                   x0: -5000, x1: 5000, y: -800, trim: 6000)))
        s = Editor.reduce(s, .addPosition(Position(id: "LX 1", kind: .horizontal, type: .truss,
                                                   x0: -5000, x1: 5000, y: 2200, trim: 5500)))

        // 4. 挂 4 台灯
        var ch = 1
        for (pos, x, type, gel, aim) in [
            ("FOH", -2500.0, "profile", "L201", 90.0),
            ("FOH",  2500.0, "profile", "L201", 90.0),
            ("LX 1", -2000.0, "fresnel", "L132", 90.0),
            ("LX 1",  2000.0, "fresnel", "L132", 90.0),
        ] as [(String, Double, String, String, Double)] {
            s = Editor.reduce(s, .addFixture(
                Fixture(unit: 100 + ch, type: type, aim: aim, gel: gel,
                        purpose: "AREA \\(ch)", beam: type == "fresnel" ? 45 : 26),
                at: s.layout.toSheet(Vec2(x, pos == "FOH" ? -800 : 2200))))
            ch += 1
        }

        // 5. 加布景与光区
        s = Editor.reduce(s, .addSetPiece(SetPiece(kind: .rect, x0: -1500, y0: 4000,
                                                   x1: 1500, y1: 5000,
                                                   label: "TABLE", height: 750)))
        s = Editor.reduce(s, .addZone(Zone(id: "A", x0: -5000, y0: 2000,
                                           x1: 5000, y1: 6500)))

        // 6. 全部校验必须通过
        let errors = s.issues.filter { $0.severity == .error }
        let errorText = errors.map { $0.code.rawValue + " " + $0.subject }.joined(separator: ", ")
        #expect(errors.isEmpty, Comment(rawValue: "errors: " + errorText))

        // 7. 平面图能出，且装得下
        let plan = PlanSheet(fitting: s.doc)
        #expect(plan.contentFitsSheet)
        #expect(plan.textCount > 30)
        #expect(plan.doc.fixtures.count == 4)

        // 8. 剖面图能出
        let section = SectionSheet(fitting: s.doc)
        #expect(section.contentFitsSheet)
        #expect(section.sightLines.count == 5)
        // 450mm 起坡应当让全部 5 排看到台面
        let blocked = section.sightLines.filter { !$0.seesStageFloor }
        let blockedText = blocked.map { String($0.row + 1) + ":" + String(Int($0.margin)) }.joined(separator: ", ")
        #expect(blocked.isEmpty, Comment(rawValue: "blocked rows: " + blockedText))

        // 9. 真的写出两份 PDF
        let dir = FileManager.default.temporaryDirectory
        let planURL = dir.appendingPathComponent("wf-plan-\\(UUID().uuidString).pdf")
        let secURL = dir.appendingPathComponent("wf-sec-\\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: planURL)
            try? FileManager.default.removeItem(at: secURL)
        }
        try SheetPDF.write(plan, to: planURL)
        try SheetPDF.write(section, to: secURL)

        let planSize = try FileManager.default.attributesOfItem(atPath: planURL.path)[.size] as? Int ?? 0
        let secSize = try FileManager.default.attributesOfItem(atPath: secURL.path)[.size] as? Int ?? 0
        #expect(planSize > 20_000, "plan pdf too small: \\(planSize)")
        #expect(secSize > 15_000, "section pdf too small: \\(secSize)")

        // 10. 保存并重新打开，文档一致
        let model = EditorModel(doc: s.doc)
        let docURL = dir.appendingPathComponent("wf-\\(UUID().uuidString).lpx")
        defer { try? FileManager.default.removeItem(at: docURL) }
        #expect(model.save(to: docURL))
        let reopened = EditorModel()
        try reopened.open(url: docURL)
        #expect(reopened.state.doc.meta.show == "THE VISIT")
        #expect(reopened.state.doc.fixtures.count == 4)
        #expect(reopened.state.doc.positions.count == 2)
    }
}
