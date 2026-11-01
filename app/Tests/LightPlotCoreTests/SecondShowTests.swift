import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// **换一部戏。**
///
/// 产品承诺之一是"工作流不绑定某部戏"。这条不是口号 ——
/// 换项目只改数据，代码一行不动。所以这里用一部**完全不同的戏**
/// 走完整条链路，逼出任何隐藏的硬编码。
///
/// 数据刻意与《推销员之死》处处不同：
///   · 舞台 9×6m（原 15×9m）
///   · 5 个构件（原 7），其中只有一根 BOOM
///   · 12 台灯（原 32），通道号不连续
///   · 5 个色片（原 9），有 L106 / L156 这些原数据里没有的
///   · 两个场景也完全不同（dusk / memory）
@Suite("Second show")
struct SecondShowTests {

    /// 《The Visit》—— 6m 深的小剧场。
    private func visitDocument() -> LXDocument {
        var doc = LXDocument()
        doc.meta = .init(profile: "study", show: "THE VISIT",
                         playwright: "FRIEDRICH DURRENMATT",
                         venue: "STUDIO 2", sheetTitle: "LX PLAN",
                         scale: 25, date: "12/09/2026", revision: "V1",
                         revNote: "FIRST ISSUE", director: "A DIRECTOR",
                         designer: "A STUDENT")
        doc.stage = .init(width: 9000, depth: 6000, datum: 0,
                          gridHeight: 6500, prosceniumHeight: 5000,
                          prosceniumX: -900, audienceRows: 4,
                          audienceRowDepth: 600, audienceRake: 500)
        doc.types = [
            "profile": .init(label: "Profile / ERS 750W", watt: 750, role: "FACE"),
            "fresnel": .init(label: "Fresnel 650W", watt: 650, role: "WASH"),
            "par": .init(label: "PAR 500W", watt: 500, role: "SIDE"),
            "practical": .init(label: "Practical", watt: 0, role: "PRACTICAL"),
        ]
        doc.gels = [
            Gel(code: "L201", name: "Lee 201  Full CT Blue"),
            Gel(code: "L132", name: "Lee 132  Quarter CT Straw"),
            Gel(code: "L119", name: "Lee 119  Dark Blue"),
            Gel(code: "L106", name: "Lee 106  Primary Red"),
            Gel(code: "L103", name: "Lee 103  Straw"),
            Gel(code: "OPEN", name: "No colour"),
        ]
        doc.positions = [
            Position(id: "FOH", kind: .horizontal, type: .pipe,
                     x0: -4500, x1: 4500, y: -700, trim: 6000),
            Position(id: "LX 1", kind: .horizontal, type: .truss,
                     x0: -4500, x1: 4500, y: 1800, trim: 5500),
            Position(id: "LX 2", kind: .horizontal, type: .truss,
                     x0: -4500, x1: 4500, y: 4200, trim: 5500),
            Position(id: "BOOM SL", kind: .vertical, type: .pipe,
                     x: -4800, y0: 800, y1: 5000, trim: 3000),
            Position(id: "SET EDGE", kind: .horizontal, type: .line,
                     x0: -4000, x1: 4000, y: 1200, trim: 0),
        ]
        doc.zones = [Zone(id: "A", x0: -4500, y0: 1200, x1: 4500, y1: 6000)]
        doc.fixtures = [
            Fixture(unit: 101, pos: "FOH", x: -3000, type: "profile", aim: 90,
                    gel: "L201", ch: 1, purpose: "FACE 1", beam: 26),
            Fixture(unit: 102, pos: "FOH", x: -1000, type: "profile", aim: 90,
                    gel: "L201", ch: 2, purpose: "FACE 2", beam: 26),
            Fixture(unit: 103, pos: "FOH", x: 1000, type: "profile", aim: 90,
                    gel: "L201", ch: 3, purpose: "FACE 3", beam: 26),
            Fixture(unit: 104, pos: "FOH", x: 3000, type: "profile", aim: 90,
                    gel: "L201", ch: 4, purpose: "FACE 4", beam: 26),
            Fixture(unit: 201, pos: "LX 1", x: -2500, type: "fresnel", aim: 90,
                    gel: "L132", ch: 11, purpose: "WASH 1", beam: 45),
            Fixture(unit: 202, pos: "LX 1", x: 0, type: "fresnel", aim: 90,
                    gel: "L132", ch: 12, purpose: "WASH 2", beam: 45),
            Fixture(unit: 203, pos: "LX 1", x: 2500, type: "fresnel", aim: 90,
                    gel: "L132", ch: 13, purpose: "WASH 3", beam: 45),
            Fixture(unit: 301, pos: "LX 2", x: -2000, type: "fresnel", aim: 270,
                    gel: "L119", ch: 21, purpose: "BACK 1", beam: 45),
            Fixture(unit: 302, pos: "LX 2", x: 2000, type: "fresnel", aim: 270,
                    gel: "L119", ch: 22, purpose: "BACK 2", beam: 45),
            Fixture(unit: 501, pos: "BOOM SL", y: 2000, type: "par", aim: 0,
                    gel: "L106", ch: 41, purpose: "SIDE 1", beam: 25),
            Fixture(unit: 502, pos: "BOOM SL", y: 3500, type: "par", aim: 0,
                    gel: "L106", ch: 42, purpose: "SIDE 2", beam: 25),
            Fixture(unit: 901, pos: "SET EDGE", x: -800, y: 2000,
                    type: "practical", aim: 90, gel: "OPEN", ch: 91,
                    purpose: "LAMP", beam: 60),
        ]
        doc.setPieces = [SetPiece(kind: .rect, x0: -1200, y0: 2600,
                                  x1: 1200, y1: 3600, label: "TABLE", height: 750)]
        return doc
    }

    private func visitScenes() -> LightingStateSet {
        LightingStateSet(
            states: [
                LightingState(id: "dusk", act: "ACT 1", name: "DUSK",
                              gelOverride: ["L201": "L132", "L119": "L156"],
                              levels: ["FOH": 40, "LX 1": 25, "LX 2": 0,
                                       "BOOM SL": 50, "SET": 60],
                              defaultLevel: 0),
                LightingState(id: "memory", act: "ACT 2", name: "MEMORY",
                              gelOverride: ["L201": "L202", "L132": "L200",
                                            "L106": "L113"],
                              levels: ["FOH": 70, "LX 1": 55, "LX 2": 35,
                                       "BOOM SL": 20, "SET": 15],
                              defaultLevel: 0),
            ],
            transitions: [.init(from: "dusk", to: "memory",
                                note: "8s fade, music under")])
    }

    @Test("A completely different show lints clean")
    func lintsClean() throws {
        var doc = visitDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let errors = Lint.check(doc).filter { $0.severity == .error }
        #expect(errors.isEmpty,
                Comment(rawValue: errors.map { $0.code.rawValue + " " + $0.subject }
                    .joined(separator: " | ")))
    }

    @Test("Both sheets render, fit, and carry no overlapping text")
    func sheetsAreClean() throws {
        var doc = visitDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)

        let plan = PlanSheet(fitting: doc)
        #expect(plan.contentFitsSheet, "plan should fit A1 @ 1:25")

        // 核心标注（灯号 / 色片 / 通道）一个都不能丢。
        //
        // 允许**非核心**标注让位：这台实物灯放在 y=2000，
        // 正好压在 LX 1 的构件名上。构件名让位是对的 ——
        // 杆本身画在图上、构件表里也有名字，而通道号只出现在这一处。
        #expect(!plan.textFit.lostEssentialLabels,
                Comment(rawValue: "plan dropped essential labels: \(plan.textFit.dropped)"))

        let section = SectionSheet(fitting: doc)
        #expect(section.contentFitsSheet, "section should fit A3 @ 1:50")

        for (name, ops) in [("plan", plan.ops), ("section", section.ops)] {
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
        }
    }

    @Test("The title block reads the new show, not the old one")
    func titlesComeFromData() throws {
        var doc = visitDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let texts = PlanSheet(fitting: doc).ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        #expect(texts.contains("THE VISIT"))
        #expect(texts.contains("FRIEDRICH DURRENMATT"))
        #expect(texts.contains("STUDIO 2"))
        #expect(!texts.contains("DEATH OF A SALESMAN"), "old show leaked into the sheet")
        #expect(!texts.contains("ARTHUR MILLER"))
    }

    @Test("Scenes work on the new show too")
    func scenesWork() throws {
        var doc = visitDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let set = visitScenes()

        for st in set.states {
            let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: st)
            #expect(!sheet.textFit.lostEssentialLabels,
                    Comment(rawValue: "\(st.id): \(sheet.textFit.dropped)"))
            let texts = sheet.ops.compactMap { op -> String? in
                if case .text(let t) = op { return t.string }
                return nil
            }
            #expect(texts.contains { $0.contains(st.name) },
                    "\(st.id): the scene name is not printed")
        }

        let c = set.contrast(set.states[0], set.states[1], doc: doc)
        #expect(c.isSufficient,
                "gel \(c.gelDifferences), level \(c.levelDifferences)")
    }

    @Test("The CSV set comes out complete for the new show")
    func csvSet() throws {
        var doc = visitDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = ScheduleCSV.writeAll(doc, states: visitScenes(), to: dir,
                                        prefix: doc.meta.show)
        #expect(urls.count == 4 + 2)
        for u in urls {
            let body = try String(contentsOf: u, encoding: .utf8)
            // 剧名在**文件名**里，不在表格里 —— 表格必须保持可直接被
            // pandas / Excel 读取（有标题行就会多出一行假数据）。
            // 旧管线的 CSV 也是这个做法，只是文件名不带剧名。
            #expect(u.lastPathComponent.contains("THE VISIT"),
                    "\(u.lastPathComponent) does not identify the show")
            let rows = body.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            #expect(rows.count >= 2, "\(u.lastPathComponent) has no data rows")
            // 第一行是表头：全大写、无空列
            #expect(rows[0].uppercased() == rows[0],
                    "\(u.lastPathComponent): header should be upper case")
        }
    }

    /// 应用里也能直接打开这部戏的数据，并且不崩。
    @MainActor
    @Test("The app opens the second show without complaint")
    func appOpens() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("visit-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var doc = visitDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let url = dir.appendingPathComponent("visit.yaml")
        try DocumentCodec.encodeYAML(doc).write(to: url, atomically: true, encoding: .utf8)

        let model = EditorModel()
        try model.open(url: url)
        #expect(model.state.doc.meta.show == "THE VISIT")
        #expect(model.state.doc.fixtures.count == 12)
        #expect(model.state.issues.filter { $0.severity == .error }.isEmpty)

        let pdf = dir.appendingPathComponent("plan.pdf")
        #expect(model.exportPDF(to: pdf) != nil)
        let size = try FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int ?? 0
        #expect(size > 20_000, "PDF is only \(size) bytes")
    }
}
