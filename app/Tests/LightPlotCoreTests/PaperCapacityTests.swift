import Testing
import Foundation
@testable import LightPlotCore

/// 纸幅容量。
///
/// 一个"装不下"的错误必须配一条**可执行建议**，否则用户只能猜。
/// 这一组把容量公式钉死，UI 才能放心地把它显示出来。
@Suite("Paper capacity")
struct PaperCapacityTests {

    @Test("Capacity is the plan area scaled back to document millimetres")
    func formula() {
        let area = SheetLayout.planArea(paper: .a1)
        let cap = SheetLayout.capacity(paper: .a1, scale: 25)
        #expect(abs(cap.x - area.width * 25) < 1e-9)
        #expect(abs(cap.y - area.height * 25) < 1e-9)
        // A1 @ 1:25 能装 16.6 × 13.7 米量级
        #expect(cap.x > 16_000 && cap.x < 17_500)
        #expect(cap.y > 13_000 && cap.y < 14_500)
    }

    /// 这条守的是一个真实 bug：信息栏曾是写死的绝对坐标（A1 专用），
    /// 换成 A0 后平面可用宽度一点没变 —— 用户会以为"换纸没用"。
    @Test("A bigger sheet really does give more usable width")
    func biggerSheetIsWider() {
        let a3 = SheetLayout.planArea(paper: .a3).width
        let a1 = SheetLayout.planArea(paper: .a1).width
        let a0 = SheetLayout.planArea(paper: .a0).width
        #expect(a1 > a3 + 300, "A1 must be much wider than A3")
        #expect(a0 > a1 + 300, "A0 must be much wider than A1")
    }

    @Test("Doubling the scale doubles the capacity")
    func scaleScales() {
        let a = SheetLayout.capacity(paper: .a1, scale: 25)
        let b = SheetLayout.capacity(paper: .a1, scale: 50)
        #expect(abs(b.x - a.x * 2) < 1e-9)
    }

    @Test("Bigger paper holds more")
    func paperOrdering() {
        // 用横向的标准幅面比较（A0 > A1 > A2 > A3）
        let widths = PaperSize.theatreSet.map {
            ($0, SheetLayout.capacity(paper: $0, scale: 25).x)
        }
        #expect(widths[0].1 > widths[1].1, "A0 must hold more than A1")
        #expect(widths[1].1 > widths[2].1, "A1 must hold more than A2")
        #expect(widths[2].1 > widths[3].1, "A2 must hold more than A3")
    }

    @Test("Portrait swaps width and height")
    func portrait() {
        let land = PaperSize(standard: .a1, orientation: .landscape)
        let port = PaperSize(standard: .a1, orientation: .portrait)
        #expect(land.widthMM == 841 && land.heightMM == 594)
        #expect(port.widthMM == 594 && port.heightMM == 841)
        #expect(port.rotated() == land)
        #expect(land.name == "A1" && port.name == "A1")
        #expect(PaperLayoutOrientation(of: land) == .landscape)
        #expect(PaperLayoutOrientation(of: port) == .portrait)
    }

    private func PaperLayoutOrientation(of p: PaperSize) -> PaperOrientation { p.orientation }

    @Test("Small paper keeps a usable drawing area")
    func smallPaperStillUsable() {
        // A4 上信息栏若是固定 130mm，绘图区只剩几十毫米 —— 图就废了。
        for paper in PaperSize.all {
            let area = SheetLayout.planArea(paper: paper)
            #expect(area.width > 60, "\(paper.displayName): plan area only \(area.width)mm wide")
            #expect(area.height > 40, "\(paper.displayName): plan area only \(area.height)mm tall")
        }
    }

    @Test("Every standard size is recognised back from its dimensions")
    func standardRoundTrip() {
        for std in PaperSize.PaperStandard.allCases {
            for orient in PaperOrientation.allCases {
                let p = PaperSize(standard: std, orientation: orient)
                #expect(p.standard == std)
                #expect(p.orientation == orient)
            }
        }
    }

    @Test("The real stage needs more than A1 can hold at 1:25 if widened")
    func realStageBoundary() throws {
        var doc = try TestData.realDocument()
        // 15m 舞台在 A1 @1:25 下恰好放得下
        #expect(PlanSheet(fitting: doc).contentFitsSheet)

        // 18m 就放不下了 —— 这正是 UI 必须给出"换 A0 或 1:50"的原因
        doc.stage.width = 18000
        doc.positions = doc.positions.map { p in
            var q = p
            q.x0 = q.x0.map { $0 * 1.2 }
            q.x1 = q.x1.map { $0 * 1.2 }
            q.x = q.x.map { $0 * 1.2 }
            return q
        }
        doc.fixtures = doc.fixtures.map { f in
            var g = f
            g.x = g.x.map { $0 * 1.2 }
            return g
        }
        var wide = PlanSheet(fitting: doc)
        #expect(wide.contentFitsSheet == false, "A1 must not silently accept an 18 m stage")

        // 换成 A0 就放得下，且比例保持不变
        wide = PlanSheet(doc: doc,
                         layout: SheetLayout.fitted(to: doc.contentBounds,
                                                    paper: .a0,
                                                    scaleDenominator: 25))
        #expect(wide.layout.scaleDenominator == 25)
        #expect(wide.contentFitsSheet, "A0 should hold an 18 m stage at 1:25")
    }

    @Test("Changing paper keeps the scale and re-centres")
    func paperSwitch() throws {
        var s = EditorState(doc: try TestData.realDocument())
        let scale = s.layout.scaleDenominator
        s = Editor.reduce(s, .setPaper(.a2))
        #expect(s.layout.paper == .a2)
        #expect(s.layout.scaleDenominator == scale, "changing paper must not change scale")

        s = Editor.reduce(s, .setPaper(.a1))
        #expect(s.layout.paper == .a1)
        s = Editor.reduce(s, .undo)
        #expect(s.layout.paper == .a2)
    }

    @Test("Paper names are the standard ISO ones")
    func names() {
        #expect(PaperSize.a0.name == "A0")
        #expect(PaperSize.a1.name == "A1")
        #expect(PaperSize.a2.name == "A2")
        #expect(PaperSize.a3.name == "A3")
        // 7 种幅面 × 2 朝向
        #expect(PaperSize.all.count == PaperStandard_count * 2)
    }

    private var PaperStandard_count: Int { 7 }

    @Test("Every paper keeps the 20 mm inner frame")
    func frames() {
        for p in PaperSize.all {
            let layout = SheetLayout(paper: p)
            #expect(layout.innerFrame.x0 == 20)
            #expect(layout.innerFrame.x1 == p.widthMM - 20)
            #expect(layout.innerFrame.y1 == p.heightMM - 20)
        }
    }
}
