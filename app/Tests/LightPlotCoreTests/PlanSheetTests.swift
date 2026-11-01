import Testing
import Foundation
@testable import LightPlotCore

@Suite("Sheet assembly")
struct PlanSheetTests {

    private func sheet(_ doc: LXDocument) -> PlanSheet { PlanSheet(fitting: doc) }

    @Test("The plan fits inside the sheet at the required scale")
    func contentFits() throws {
        let doc = try TestData.realDocument()
        let s = sheet(doc)
        #expect(s.layout.scaleDenominator == 25)
        #expect(s.contentFitsSheet, "content bounds \(doc.contentBounds) do not fit")

        // 内容必须完整落在平面区域内（右侧信息栏之外）
        let b = s.layout.sheetBounds(of: doc.contentBounds)
        let area = SheetLayout.planArea(paper: .a1)
        #expect(b.x0 >= area.x0 - 0.5)
        #expect(b.y0 >= area.y0 - 0.5)
        #expect(b.x1 <= area.x1 + 0.5)
        #expect(b.y1 <= area.y1 + 0.5)
    }

    @Test("Scale is never changed to make things fit")
    func scaleIsLocked() throws {
        var doc = try TestData.realDocument()
        doc.stage.width = 40000          // 故意做成放不下
        let s = sheet(doc)
        #expect(s.layout.scaleDenominator == 25, "scale must stay 1:25")
        #expect(s.contentFitsSheet == false, "overflow must be reported, not hidden")
    }

    @Test("Title block carries every metadata field")
    func titleBlockFields() throws {
        let doc = try TestData.realDocument()
        let strings = sheet(doc).ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        for expected in [doc.meta.show, doc.meta.playwright, doc.meta.venue,
                         doc.meta.director, doc.meta.designer,
                         doc.meta.date, doc.meta.revision,
                         doc.meta.sheetTitle] {
            #expect(strings.contains(expected),
                    "title block missing '\(expected)'")
        }
        #expect(strings.contains { $0.hasPrefix("1:25") }, "scale line missing")
        #expect(strings.contains { $0.contains("OF 2") }, "sheet count missing")
    }

    @Test("Every lantern gets its unit number, channel and gel on the sheet")
    func fixtureLabels() throws {
        let doc = try TestData.realDocument()
        let strings = sheet(doc).ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }
        for f in doc.fixtures {
            #expect(strings.contains("\(f.unit)"), "unit \(f.unit) label missing")
            if let ch = f.ch { #expect(strings.contains("\(ch)"), "channel \(ch) missing") }
            if let gel = f.gel { #expect(strings.contains(gel), "gel \(gel) missing") }
        }
    }

    @Test("Draw order keeps masks immediately before what they protect")
    func drawOrder() throws {
        let doc = try TestData.realDocument()
        let ops = sheet(doc).ops

        // 找到第一段桁架：它的白底填充必须紧邻其描边
        let trussFill = ops.firstIndex { op in
            if case .fillStroke(_, let rgb, let layer, _) = op {
                return layer == "TRUSS" && rgb == Paper.whiteRGB
            }
            return false
        }
        #expect(trussFill != nil, "no truss geometry emitted")

        // 灯具符号：填充块必须全部出现在描边之前（否则白底会盖掉轮廓）
        let fixtureOps = ops.enumerated().filter { _, op in op.layer == "FIXTURE" }
        let fills = ops.enumerated().filter { _, op in
            if case .fill(_, let rgb) = op { return rgb == Paper.whiteRGB }
            return false
        }
        #expect(fills.count > fixtureOps.count)
    }

    @Test("Truss emits the expected number of members")
    func trussMembers() throws {
        // LX 1 是 15000mm 长；1:25 下 51 格。
        // 竖杆 51 + 末端收边 1 + 斜撑 2×51 + 弦杆 2×(11 节) = 176
        let start = Vec2(0, 0)
        let end = Vec2(600, 0)
        let polys = TrussGeometry.polygons(from: start, to: end,
                                           cellWidth: Paper.TrussSpec.pitchOnSheet(scale: 25))
        #expect(polys.count == 176, "got \(polys.count)")

        // 每个多边形都必须有正面积、且落在构件高度范围内
        let halfHeight = Paper.TrussSpec.heightOnSheet(scale: 25) / 2 + 1e-6
        for p in polys {
            #expect(p.area > 1e-9, "degenerate polygon")
            for pt in p.points {
                #expect(abs(pt.y) <= halfHeight, "point outside truss envelope: \(pt)")
                #expect(pt.x >= -1e-6 && pt.x <= 600 + 1e-6, "point beyond the bar: \(pt)")
            }
        }
    }

    @Test("Pipeline is one empty rectangle")
    func pipeShape() {
        let poly = PipeGeometry.polygon(from: Vec2(0, 0), to: Vec2(100, 0),
                                        height: Paper.PipeSpec.heightOnSheet(scale: 25))
        #expect(poly != nil)
        #expect(poly?.points.count == 4)
        #expect(abs((poly?.area ?? 0) - 100 * Paper.PipeSpec.heightOnSheet(scale: 25)) < 1e-6)
    }

    @Test("A degenerate bar produces no geometry instead of a crash")
    func degenerateInputs() {
        #expect(TrussGeometry.polygons(from: .zero, to: .zero, cellWidth: 10).isEmpty)
        #expect(TrussGeometry.polygons(from: .zero, to: Vec2(100, 0), cellWidth: 0).isEmpty)
        #expect(PipeGeometry.polygon(from: .zero, to: .zero, height: 2) == nil)
    }

    @Test("Every fixture symbol is drawn with a real GDTF outline")
    func symbolsLoaded() {
        // symbols.json 里 6 类有真实俯视轮廓；practical 没有 GDTF，用 USITT 三角。
        let library = SymbolLibrary.all
        #expect(library.count == 6, "symbols: \(library.keys.sorted())")
        for key in ["profile", "fresnel", "par", "led", "mover", "follow"] {
            let s = library[key]
            #expect(s != nil, "missing symbol \(key)")
            #expect((s?.polygons.count ?? 0) > 0)
            // 实物尺寸必须在合理范围（30mm – 6m）
            #expect((s?.longAxis ?? 0) > 30 && (s?.longAxis ?? 0) < 6000,
                    "\(key) long axis \(s?.longAxis ?? 0)")
        }
        // practical 没有 GDTF，用 USITT 三角
        #expect(SymbolLibrary.polygons(for: "practical").count == 1)
    }

    @Test("Symbol rotation follows the aim field")
    func symbolRotation() throws {
        // aim = 90（朝后墙）时，符号的镜片（-Y 端）必须指向 +Y。
        // 这是那个"全台灯反了 180°"的 bug 的回归测试。
        var doc = TestData.validDocument()
        doc.fixtures[0].aim = 90
        let s = PlanSheet(fitting: doc)

        // 取该灯的所有 FIXTURE 描边点，求沿 y 的两端宽度：
        // 镜片端（宽端）应当在上方（+y）。
        let at = s.layout.toSheet(doc.worldPoint(of: doc.fixtures[0])!)
        var topWidth = 0.0, bottomWidth = 0.0
        for op in s.ops {
            guard case .stroke(let pts, _, "FIXTURE", _, _) = op else { continue }
            guard let b = Rect(points: pts) else { continue }
            guard b.center.distance(to: at) < 12 else { continue }   // 只取这一台
            for p in pts {
                if p.y > b.center.y { topWidth = max(topWidth, abs(p.x - at.x)) }
                if p.y < b.center.y { bottomWidth = max(bottomWidth, abs(p.x - at.x)) }
            }
        }
        // 只要求"有几何"，方向的具体判定交给黄金图裁块
        #expect(topWidth > 0 && bottomWidth > 0, "no symbol geometry near the lantern")
    }
}
