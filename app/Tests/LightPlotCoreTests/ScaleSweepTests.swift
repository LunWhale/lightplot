import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 规模扫描：同一套代码在不同体量的制作上都必须成立。
///
/// 只用自己的示例数据测会漏掉一整类缺陷 —— 尺寸、trim、台口高
/// 任意一个变化都会改变版面关系。这里扫三档：
/// 极小（6m/3 灯）、中等（10m）、大（20m/40 灯）。
@MainActor
@Suite("Scale sweep")
struct ScaleSweepTests {

    private struct Project {
        let name: String
        let stageW: Double
        let stageD: Double
        let trim: Double
        let bars: Int
        let perBar: Int
        let paper: PaperSize
        let scale: Double
    }

    private func make(_ p: Project) -> LXDocument {
        var doc = LXDocument()
        doc.meta = .init(profile: "study", show: p.name, playwright: "A", venue: "V",
                         sheetTitle: "LX PLAN", scale: p.scale,
                         date: "01/01/2027", revision: "V1", revNote: "X",
                         director: "D", designer: "S")
        doc.stage = .init(width: p.stageW, depth: p.stageD, datum: 0,
                          gridHeight: p.trim + 1500,
                          prosceniumHeight: p.trim - 500,
                          prosceniumX: -800,
                          audienceRows: 5, audienceRowDepth: 550, audienceRake: 400)
        doc.types = [
            "profile": .init(label: "Profile / ERS 750W", watt: 750, role: "FACE"),
            "fresnel": .init(label: "Fresnel 650W", watt: 650, role: "WASH"),
        ]
        doc.gels = GelLibrary.all.map { GelLibrary.gel(from: $0) }

        let halfW = p.stageW / 2 - 200
        for b in 0..<p.bars {
            let y = p.stageD * Double(b + 1) / Double(p.bars + 1)
            doc.positions.append(Position(id: "LX \(b + 1)", kind: .horizontal,
                                          type: .truss, x0: -halfW, x1: halfW,
                                          y: y, trim: p.trim))
        }
        var unit = 101
        var ch = 1
        for b in 0..<p.bars {
            for i in 0..<p.perBar {
                let t = Double(i) / Double(max(1, p.perBar - 1))
                let x = -halfW + t * 2 * halfW
                doc.fixtures.append(Fixture(
                    unit: unit, pos: "LX \(b + 1)", x: x,
                    type: i % 2 == 0 ? "profile" : "fresnel",
                    aim: 90, gel: i % 2 == 0 ? "L201" : "L132",
                    ch: ch, purpose: "AREA \(i + 1)",
                    beam: i % 2 == 0 ? 26 : 45))
                unit += 1
                ch += 1
            }
        }
        return doc
    }

    private func checkAllSheets(_ doc: LXDocument, label: String,
                                paper: PaperSize, scale: Double) {
        let plan = PlanSheet(fitting: doc, paper: paper, scale: scale, lightingState: nil)
        #expect(plan.contentFitsSheet,
                "\(label): plan does not fit \(paper.name) at 1:\(Int(scale))")

        // 零文字重叠
        var boxes: [(String, Rect)] = []
        for op in plan.ops {
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
                Comment(rawValue: "\(label): " + hits.prefix(4).joined(separator: " | ")))

        // 纯 ASCII
        for op in plan.ops {
            guard case .text(let t) = op else { continue }
            #expect(EventSanitizer.isASCII(t.string), "\(label): non-ASCII '\(t.string)'")
        }
    }

    @Test("A tiny project renders cleanly")
    func tiny() throws {
        let p = Project(name: "TINY", stageW: 6000, stageD: 4500,
                        trim: 4000, bars: 1, perBar: 3, paper: .a3, scale: 50)
        let doc = make(p)
        checkAllSheets(doc, label: "tiny", paper: p.paper, scale: p.scale)

        let errors = Lint.check(doc).filter { $0.severity == .error }
        #expect(errors.isEmpty,
                Comment(rawValue: errors.map { $0.code.rawValue + " " + $0.subject }
                    .joined(separator: " | ")))
    }

    @Test("A medium project renders cleanly")
    func medium() throws {
        let p = Project(name: "MEDIUM", stageW: 12000, stageD: 8000,
                        trim: 6000, bars: 3, perBar: 4, paper: .a1, scale: 25)
        checkAllSheets(make(p), label: "medium", paper: p.paper, scale: p.scale)
    }

    /// 大制作：20m 舞台、40 台灯、A0@1:50。
    @Test("A large project renders cleanly on A0")
    func large() throws {
        let p = Project(name: "LARGE", stageW: 20000, stageD: 14000,
                        trim: 9000, bars: 5, perBar: 8, paper: .a0, scale: 50)
        checkAllSheets(make(p), label: "large", paper: p.paper, scale: p.scale)
    }

    /// 同一个大制作在 A1@1:25 上装不下 —— 必须给提示页，不能出空白纸。
    @Test("An undersized sheet reports overflow instead of going blank")
    func overflow() throws {
        let p = Project(name: "LARGE", stageW: 20000, stageD: 14000,
                        trim: 9000, bars: 5, perBar: 8, paper: .a1, scale: 25)
        let doc = make(p)
        let sheet = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        #expect(!sheet.contentFitsSheet)
        let texts = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        #expect(texts.contains { $0.contains("DOES NOT FIT") })
    }

    /// 灯数越多，标注越密 —— 检查大纲在这一档仍成立。
    @Test("Dense fixture rows keep labels readable and non-overlapping")
    func denseRows() throws {
        let p = Project(name: "DENSE", stageW: 16000, stageD: 10000,
                        trim: 7000, bars: 2, perBar: 12, paper: .a0, scale: 25)
        let doc = make(p)
        #expect(doc.fixtures.count == 24)
        checkAllSheets(doc, label: "dense", paper: p.paper, scale: p.scale)
    }

    // MARK: 剖面图随规模变化

    @Test("Sections hold up across the same three scales")
    func sections() throws {
        let projects = [
            Project(name: "TINY", stageW: 6000, stageD: 4500, trim: 4000,
                    bars: 1, perBar: 3, paper: .a3, scale: 50),
            Project(name: "MEDIUM", stageW: 12000, stageD: 8000, trim: 6000,
                    bars: 3, perBar: 4, paper: .a3, scale: 50),
            Project(name: "LARGE", stageW: 20000, stageD: 14000, trim: 9000,
                    bars: 5, perBar: 8, paper: .a1, scale: 50),
        ]
        for p in projects {
            let doc = make(p)
            let sheet = SectionSheet(fitting: doc, paper: p.paper, scale: p.scale,
                                     lightingState: nil)
            #expect(sheet.contentFitsSheet,
                    "\(p.name): section does not fit \(p.paper.name) at 1:\(Int(p.scale))")

            var boxes: [(String, Rect)] = []
            for op in sheet.ops {
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
                    Comment(rawValue: "\(p.name) section: "
                            + hits.prefix(4).joined(separator: " | ")))
        }
    }
}
