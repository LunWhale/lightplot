import Testing
import Foundation
@testable import LightPlotCore

/// 剖面图的文字重叠检查。
///
/// 平面图一直有"零重叠"断言（旧管线的 `verify.py` 按真实 bbox 两两求交），
/// 但剖面图从来没查过。结果剖切标记 "A" 压在观众席图形上、字叠在一起 ——
/// 人眼扫一遍很容易漏，因为它藏在左下角。
///
/// 这里的做法与平面图一致：**按真实字宽算 bbox，两两求交**。
/// 不估算、不按字号乘系数。
@Suite("Text layout")
struct SectionOverlapTests {

    /// 通用：按真实字宽算 bbox，两两求交。
    private func collisions(_ ops: [DrawOp]) -> [String] {
        var boxes: [(String, Rect)] = []
        for op in ops {
            guard case .text(let t) = op,
                  !t.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let b = t.family.measuring.textBox(t.string, at: t.origin, capMM: t.capMM,
                                               align: t.align,
                                               rotationDegrees: t.rotationDegrees)
            boxes.append((t.string, b))
        }
        var out: [String] = []
        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                guard boxes[i].0 != boxes[j].0 else { continue }
                if boxes[i].1.overlapsStrictly(boxes[j].1, pad: 0.15) {
                    out.append("'\(boxes[i].0)' x '\(boxes[j].0)'")
                }
            }
        }
        return out
    }

    /// 平面图同样必须零重叠。
    ///
    /// 这条以前只靠"看起来对"—— 实际有两处真实碰撞：
    /// 图例的灯具数量 "2" 压住图框分区号 "2"，竖直 BOOM 的名字压住分区字母。
    /// 都是藏在小角落、扫一眼看不出来的那种。
    @Test("The plan sheet has no overlapping labels")
    func planNoOverlap() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)
        let c = collisions(sheet.ops)
        #expect(c.isEmpty, Comment(rawValue: "\(c.count) overlaps: "
                                  + c.prefix(8).joined(separator: " | ")))
    }

    /// 溢出提示页只有几行大字，最容易因为行距不足而重叠 ——
    /// 实测第一版 22mm cap 却只隔 18mm，两行直接压在一起。
    @Test("The overflow notice page has no overlapping labels")
    func overflowNoticeNoOverlap() {
        var doc = TestData.validDocument()
        doc.stage.width = 60000
        doc.stage.depth = 40000

        let plan = PlanSheet(fitting: doc)
        #expect(!plan.contentFitsSheet)
        let pc = collisions(plan.ops)
        #expect(pc.isEmpty, Comment(rawValue: "plan notice: " + pc.joined(separator: " | ")))

        let section = SectionSheet(fitting: doc)
        #expect(!section.contentFitsSheet)
        let sc = collisions(section.ops)
        #expect(sc.isEmpty, Comment(rawValue: "section notice: " + sc.joined(separator: " | ")))
    }

    @Test("A minimal document also has no overlapping labels")
    func minimalNoOverlap() {
        let doc = TestData.validDocument()
        let c = collisions(PlanSheet(fitting: doc).ops)
        #expect(c.isEmpty, Comment(rawValue: "\(c.count) overlaps: "
                                  + c.prefix(8).joined(separator: " | ")))
    }

    /// 取出所有文字及其真实 bbox（图纸 mm）。
    private func textBoxes(_ sheet: SectionSheet) -> [(text: String, box: Rect, layer: String)] {
        sheet.ops.compactMap { op in
            guard case .text(let t) = op, !t.string.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            let box = t.family.measuring.textBox(t.string, at: t.origin,
                                                 capMM: t.capMM, align: t.align,
                                                 rotationDegrees: t.rotationDegrees)
            return (t.string, box, t.layer)
        }
    }

    @Test("No two labels overlap")
    func noOverlap() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc)
        let boxes = textBoxes(sheet)

        var collisions: [String] = []
        for i in 0..<boxes.count {
            for j in (i + 1)..<boxes.count {
                // 同一段文字被拆成多次绘制时允许接触（例如折行的说明）
                guard boxes[i].text != boxes[j].text else { continue }
                // 扣除 0.15mm 容差：两个字紧贴边界是允许的
                if boxes[i].box.overlapsStrictly(boxes[j].box, pad: 0.15) {
                    collisions.append("'\(boxes[i].text)' ✕ '\(boxes[j].text)'")
                }
            }
        }
        #expect(collisions.isEmpty,
                Comment(rawValue: "\(collisions.count) overlaps: "
                        + collisions.prefix(8).joined(separator: " | ")))
    }

    @Test("Every label stays on the paper")
    func insidePaper() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc)
        let paper = Rect(x0: 0, y0: 0,
                         x1: sheet.layout.paper.widthMM,
                         y1: sheet.layout.paper.heightMM)
        var outside: [String] = []
        for b in textBoxes(sheet) where !paper.contains(b.box.center) {
            outside.append("'\(b.text)' @ \(b.box.center)")
        }
        #expect(outside.isEmpty,
                Comment(rawValue: "off paper: " + outside.prefix(5).joined(separator: " | ")))
    }

    @Test("No label sits on top of the drawing frame")
    func clearOfFrame() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc)
        let inner = Rect(x0: Paper.frameInner, y0: Paper.frameInner,
                         x1: sheet.layout.paper.widthMM - Paper.frameInner,
                         y1: sheet.layout.paper.heightMM - Paper.frameInner)
        var offenders: [String] = []
        for b in textBoxes(sheet) {
            // 完全落在内框之外 = 压在框线上或框外
            if !inner.intersects(b.box) {
                offenders.append("'\(b.text)'")
            }
        }
        #expect(offenders.isEmpty,
                Comment(rawValue: "crossing the frame: " + offenders.prefix(5).joined(separator: " | ")))
    }
}
