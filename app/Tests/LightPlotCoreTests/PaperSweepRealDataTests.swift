import Testing
import Foundation
@testable import LightPlotCore

/// 真实数据 × 每一种纸张 × 每一个常用比例。
///
/// 容量算术（`PaperCapacityTests`）只证明"算得对"，
/// 不证明"画出来是干净的"。小纸上文字会挤、图例会爆、说明会压住图签 ——
/// 这些只有把指令真正生成出来才能发现。
///
/// 这条测试的判据是硬的：
///   · 装得下 → 零文字重叠、纯 ASCII、所有绘制都落在纸内、比例行说真话
///   · 装不下 → 必须出**提示页**，且提示页要点名是哪张纸
/// 绝不允许"装不下却不说话"（那会出一张空白或残缺的图）。
@Suite("Paper sweep on real data")
struct PaperSweepRealDataTests {

    private func realDoc() throws -> LXDocument {
        var doc = try DocumentCodec.decodeYAML(Data(contentsOf: TestData.rigYAML))
        _ = GelLibrary.fillMissingColours(in: &doc)
        return doc
    }

    private func texts(_ ops: [DrawOp]) -> [String] {
        ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
    }

    /// 逐对检查文字框重叠（真实 bbox，不是估算）。
    private func overlaps(_ ops: [DrawOp]) -> [String] {
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
        return hits
    }

    @Test("Every paper and scale either draws cleanly or says it does not fit")
    func sweep() throws {
        let doc = try realDoc()
        var fitting = 0
        var overflow = 0

        for paper in PaperSize.all {
            for scale in [100.0, 50, 25, 20, 10] {
                let label = "\(paper.name)@1:\(Int(scale))"
                let sheet = PlanSheet(fitting: doc, paper: paper, scale: scale,
                                      lightingState: nil)
                let all = texts(sheet.ops)

                if sheet.contentFitsSheet {
                    fitting += 1

                    let hits = overlaps(sheet.ops)
                    #expect(hits.isEmpty,
                            Comment(rawValue: "\(label): "
                                    + hits.prefix(3).joined(separator: " | ")))

                    for t in all {
                        #expect(EventSanitizer.isASCII(t),
                                "\(label): non-ASCII '\(t)'")
                    }

                    // 比例行必须说真话
                    let scaleLine = all.first { $0.hasPrefix("SCALE 1:") } ?? ""
                    #expect(scaleLine.contains("1:\(Int(scale))"),
                            "\(label): claims '\(scaleLine)'")
                    #expect(scaleLine.contains(paper.name),
                            "\(label): claims '\(scaleLine)'")

                    // 每一笔都要在纸内（0.5mm 容差给线宽）
                    let paperRect = Rect(x0: 0, y0: 0,
                                         x1: paper.widthMM, y1: paper.heightMM)
                    for op in sheet.ops {
                        let r = planBounds(of: op)
                        guard let r else { continue }
                        #expect(r.x0 > -0.5 && r.y0 > -0.5
                                && r.x1 < paper.widthMM + 0.5
                                && r.y1 < paper.heightMM + 0.5,
                                "\(label): \(describe(op)) falls outside the sheet")
                    }
                } else {
                    overflow += 1
                    // 装不下必须出提示页，而且要说清是哪张纸
                    #expect(all.contains { $0.contains("DOES NOT FIT") },
                            "\(label): overflowed silently — no notice page")
                    #expect(all.contains { $0.contains(paper.name) },
                            "\(label): the notice must name the sheet")
                    #expect(all.contains { $0.contains("Content is") },
                            "\(label): the notice must state the content size")
                }
            }
        }

        // 两种情形都要真的出现过，否则这条测试等于没跑
        #expect(fitting > 0, "no paper/scale combination fitted — sweep is vacuous")
        #expect(overflow > 0, "nothing overflowed — the notice path is untested")

        // 固定下来：A1@1:25 是项目默认，必须装得下
        let def = PlanSheet(fitting: doc, paper: .a1, scale: 25, lightingState: nil)
        #expect(def.contentFitsSheet, "the default A1 @ 1:25 must fit the real data")
    }

    @Test("Every paper draws a clean section too, or says it does not fit")
    func sectionSweep() throws {
        let doc = try realDoc()
        var fitting = 0, overflow = 0
        for paper in PaperSize.all {
            for scale in [100.0, 50, 25] {
                let label = "\(paper.name)@1:\(Int(scale))"
                let sheet = SectionSheet(fitting: doc, paper: paper, scale: scale,
                                         lightingState: nil)
                let all = texts(sheet.ops)
                if sheet.contentFitsSheet {
                    fitting += 1
                    let hits = overlaps(sheet.ops)
                    #expect(hits.isEmpty,
                            Comment(rawValue: "\(label) section: "
                                    + hits.prefix(3).joined(separator: " | ")))
                } else {
                    overflow += 1
                    #expect(all.contains { $0.contains("DOES NOT FIT") },
                            "\(label): section overflowed silently")
                }
            }
        }
        #expect(fitting > 0)
        // A3@1:50 是默认，必须装得下
        let def = SectionSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        #expect(def.contentFitsSheet, "the default A3 @ 1:50 must fit the real data")
        _ = overflow
    }

    /// 场景图也要在每种纸上成立（色片被替换后图例变短，容量判断可能变）。
    @Test("Scene sheets hold up across the paper range")
    func sceneSweep() throws {
        let doc = try realDoc()
        let scenes = try LightingStateCodec.decodeYAML(
            Data(contentsOf: TestData.workspaceRoot.appendingPathComponent("data/scenes.yaml")))
        for paper in [PaperSize.a1, PaperSize.a2, PaperSize.a0] {
            for st in scenes.states {
                let sheet = PlanSheet(fitting: doc, paper: paper, scale: 25,
                                      lightingState: st)
                guard sheet.contentFitsSheet else { continue }
                let hits = overlaps(sheet.ops)
                #expect(hits.isEmpty,
                        Comment(rawValue: "\(paper.name)/\(st.id): "
                                + hits.prefix(3).joined(separator: " | ")))
                // 场景名必须印在图上，否则两张图分不清
                #expect(texts(sheet.ops).contains { $0.contains(st.name) },
                        "\(paper.name)/\(st.id): the scene name is not printed")
            }
        }
    }

    // MARK: 辅助

    private func planBounds(of op: DrawOp) -> Rect? {
        switch op {
        case .text(let t):
            return t.family.measuring.textBox(t.string, at: t.origin, capMM: t.capMM,
                                              align: t.align,
                                              rotationDegrees: t.rotationDegrees)
        case .fill(let pts, _),
             .fillStroke(let pts, _, _, _),
             .stroke(let pts, _, _, _, _):
            return Rect(points: pts)
        case .circle(let c, let r, _, _), .fillCircle(let c, let r, _):
            return Rect(x0: c.x - r, y0: c.y - r, x1: c.x + r, y1: c.y + r)
        default:
            return nil
        }
    }

    private func describe(_ op: DrawOp) -> String {
        switch op {
        case .text(let t): return "text '\(t.string.prefix(16))'"
        case .fill: return "fill"
        case .fillStroke: return "fillStroke"
        case .stroke: return "stroke"
        case .circle: return "circle"
        case .fillCircle: return "fillCircle"
        default: return "unknown"
        }
    }
}
