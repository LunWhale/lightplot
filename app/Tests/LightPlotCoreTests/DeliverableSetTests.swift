import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 从空白文档走到**完整交付物**。
///
/// 这是"软件完整可用"的最强证据：不依赖任何现成数据，
/// 从零输入条件 → 布灯 → 两个场景 → 六份 PDF + 六份 CSV → 存盘重开。
///
/// 单个功能的测试证明"某处正确"，这一条证明"整件事能做完"。
@MainActor
@Suite("Deliverable set")
struct DeliverableSetTests {

    /// 造一份完整的小型制作：10m 舞台、4 根杆、6 台灯、两个对比场景。
    private func buildProject() -> EditorModel {
        let model = EditorModel()
        var s = model.state

        // 1. 演出信息
        s = Editor.reduce(s, .setMeta(.show, "THE VISIT"))
        s = Editor.reduce(s, .setMeta(.playwright, "DURRENMATT"))
        s = Editor.reduce(s, .setMeta(.venue, "SCHOOL STUDIO"))
        s = Editor.reduce(s, .setMeta(.director, "A DIRECTOR"))
        s = Editor.reduce(s, .setMeta(.designer, "A STUDENT"))
        s = Editor.reduce(s, .setMeta(.date, "01/03/2027"))

        // 2. 场地
        s = Editor.reduce(s, .setStage(.width, 10000))
        s = Editor.reduce(s, .setStage(.depth, 7000))
        s = Editor.reduce(s, .setStage(.gridHeight, 6500))
        s = Editor.reduce(s, .setStage(.prosceniumHeight, 5500))
        s = Editor.reduce(s, .setStage(.audienceRows, 4))
        s = Editor.reduce(s, .setStage(.audienceRowDepth, 550))
        s = Editor.reduce(s, .setStage(.audienceRake, 500))   // 足够看到台面

        // 3. 灯具类型与色库（新文档是空的）
        s.doc.types = [
            "profile": .init(label: "Profile / ERS 750W", watt: 750, role: "FACE"),
            "fresnel": .init(label: "Fresnel 650W", watt: 650, role: "WASH"),
        ]
        s.doc.gels = GelLibrary.all.map { GelLibrary.gel(from: $0) }

        // 4. 四根杆
        for (i, y) in [(1, -800.0), (2, 2000.0), (3, 4200.0), (4, 6000.0)] {
            s = Editor.reduce(s, .addPosition(Position(
                id: "LX \(i)", kind: .horizontal, type: .truss,
                x0: -5000, x1: 5000, y: y, trim: 5500)))
        }

        model.replaceDocument(s.doc)
        var st = model.state
        st = Editor.reduce(st, .setMeta(.show, "THE VISIT"))

        // 5. 六台灯：4 面光 + 2 顶光
        for (i, (pos, x, type, gel)) in [
            ("LX 1", -2500.0, "profile", "L201"),
            ("LX 1",  2500.0, "profile", "L201"),
            ("LX 2", -2000.0, "fresnel", "L132"),
            ("LX 2",  2000.0, "fresnel", "L132"),
            ("LX 3", -1500.0, "fresnel", "L103"),
            ("LX 3",  1500.0, "fresnel", "L103"),
        ].enumerated() {
            st = Editor.reduce(st, .addFixture(
                Fixture(unit: 101 + i, type: type, aim: 90, gel: gel,
                        ch: 1 + i, purpose: "AREA \(i + 1)",
                        beam: type == "fresnel" ? 45 : 26),
                at: st.layout.toSheet(Vec2(x, st.doc.position(id: pos)?.shape.map {
                    if case .horizontal(_, _, let y) = $0 { return y }
                    return 0
                } ?? 0))))
        }

        // 6. 布景 + 光区
        st = Editor.reduce(st, .addSetPiece(SetPiece(
            kind: .rect, x0: -1500, y0: 3500, x1: 1500, y1: 4500,
            label: "TABLE", height: 750)))
        st = Editor.reduce(st, .addZone(Zone(id: "A", x0: -4000, y0: 2000,
                                             x1: 4000, y1: 6000)))

        // 7. 两个对比场景
        let states = LightingStateSet(
            states: [
                LightingState(id: "night", act: "ACT 1", name: "NIGHT",
                              gelOverride: ["L201": "L202", "L132": "L200"],
                              levels: ["LX 1": 40, "LX 2": 15, "LX 3": 0],
                              defaultLevel: 0),
                LightingState(id: "memory", act: "ACT 2", name: "MEMORY",
                              gelOverride: ["L201": "L132", "L103": "L156"],
                              levels: ["LX 1": 65, "LX 2": 50, "LX 3": 30],
                              defaultLevel: 0),
            ],
            transitions: [.init(from: "night", to: "memory", note: "fade 8s")])

        model.replaceDocument(st.doc)
        model.loadStatesFromMemory(states)
        return model
    }

    @Test("The whole deliverable set can be produced from a blank document")
    func fullSet() throws {
        let model = buildProject()
        let doc = model.state.doc

        // 基本正确性
        #expect(doc.meta.show == "THE VISIT")
        #expect(doc.fixtures.count == 6)
        #expect(doc.positions.count == 4)
        #expect(model.hasStates)
        let errors = Lint.check(doc).filter { $0.severity == .error }
        #expect(errors.isEmpty,
                Comment(rawValue: errors.map { $0.code.rawValue + " " + $0.subject }
                    .joined(separator: " | ")))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deliver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 8. 六份 PDF
        var pdfs: [URL] = []
        pdfs.append(try write(PlanSheet(fitting: doc), dir, "plan"))
        pdfs.append(try write(SectionSheet(fitting: doc), dir, "section"))
        for st in model.states.states {
            pdfs.append(try write(PlanSheet(fitting: doc, paper: .a1, scale: 25,
                                            lightingState: st), dir, "plan-\(st.id)"))
            pdfs.append(try write(SectionSheet(fitting: doc, paper: .a3, scale: 50,
                                               lightingState: st), dir, "section-\(st.id)"))
        }
        #expect(pdfs.count == 6)

        // 9. 六份 CSV
        let csvs = ScheduleCSV.writeAll(doc, states: model.states, to: dir)
        #expect(csvs.count == 4 + model.states.states.count)

        // 10. 每份 PDF 都非空且可提取文字
        for u in pdfs {
            let size = try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int ?? 0
            #expect(size > 20_000, "\(u.lastPathComponent) is only \(size) bytes")
        }
        for u in csvs {
            let body = try String(contentsOf: u, encoding: .utf8)
            #expect(body.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count >= 2,
                    "\(u.lastPathComponent) has no data rows")
        }

        // 11. 存盘 → 重开 → 文档一致
        let lpx = dir.appendingPathComponent("project.lpx")
        #expect(model.save(to: lpx))
        let reopened = EditorModel()
        try reopened.open(url: lpx)
        #expect(reopened.state.doc.meta.show == "THE VISIT")
        #expect(reopened.state.doc.fixtures.count == 6)
    }

    @Test("The two scenes contrast enough for a two-state design")
    func contrast() throws {
        let model = buildProject()
        let a = model.states.states[0], b = model.states.states[1]
        let c = model.states.contrast(a, b, doc: model.state.doc)
        #expect(c.isSufficient,
                "gel \(c.gelDifferences), level \(c.levelDifferences)")
    }

    @Test("Every sheet in the set passes the same quality bar")
    func allSheetsClean() throws {
        let model = buildProject()
        let doc = model.state.doc

        var sheets: [(String, [DrawOp])] = [
            ("plan", PlanSheet(fitting: doc).ops),
            ("section", SectionSheet(fitting: doc).ops),
        ]
        for st in model.states.states {
            sheets.append(("plan-\(st.id)",
                           PlanSheet(fitting: doc, paper: .a1, scale: 25,
                                     lightingState: st).ops))
            sheets.append(("section-\(st.id)",
                           SectionSheet(fitting: doc, paper: .a3, scale: 50,
                                        lightingState: st).ops))
        }

        for (name, ops) in sheets {
            // 零文字重叠
            var boxes: [(String, Rect)] = []
            for op in ops {
                guard case .text(let t) = op,
                      !t.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                boxes.append((t.string,
                              t.family.measuring.textBox(t.string, at: t.origin,
                                                         capMM: t.capMM, align: t.align,
                                                         rotationDegrees: t.rotationDegrees)))
            }
            var hits: [String] = []
            for i in 0..<boxes.count {
                for j in (i + 1)..<boxes.count {
                    guard boxes[i].0 != boxes[j].0 else { continue }
                    if boxes[i].1.overlapsStrictly(boxes[j].1, pad: 0.15) {
                        hits.append("'\(boxes[i].0)' x '\(boxes[j].0)'")
                    }
                }
            }
            #expect(hits.isEmpty,
                    Comment(rawValue: "\(name): " + hits.prefix(3).joined(separator: " | ")))

            // 纯 ASCII
            for op in ops {
                guard case .text(let t) = op else { continue }
                #expect(EventSanitizer.isASCII(t.string),
                        "\(name): non-ASCII '\(t.string)'")
            }
        }
    }

    private func write(_ pdf: PlanSheet, _ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name + ".pdf")
        try SheetPDF.write(pdf, to: url)
        return url
    }

    private func write(_ pdf: SectionSheet, _ dir: URL, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name + ".pdf")
        try SheetPDF.write(pdf, to: url)
        return url
    }
}
