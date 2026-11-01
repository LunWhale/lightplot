import Testing
import Foundation
@testable import LightPlotCore

/// 吸附优先级。
///
/// 这是编辑器最核心的交互契约：**离手最近的点不一定是最想要的点**。
/// 实测踩过的坑：更近的网格点会击败稍远的构件端点，
/// 于是"把两根桁架接起来"这个最基本的操作永远吸不上。
@Suite("Snap priority")
struct SnapPriorityTests {

    private func state() -> EditorState {
        EditorState(doc: TestData.validDocument())
    }

    /// 端点必须击败网格，即使网格更近。
    @Test("An endpoint beats a closer grid point")
    func endpointBeatsGrid() {
        let s = state()
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1200, 800))
        let endpoint = s.layout.toSheet(Vec2(-7500, 2400))   // LX 1 左端

        // 故意取一个"离端点稍远、离最近网格点更近"的位置。
        // 注意不要排除 LX 1 —— 要吸的就是它的端点。
        let near = endpoint + Vec2(2.6, 2.6)                 // 距端点 ≈3.7mm
        let r = Snapper.snap(near, doc: s.doc, layout: s.layout,
                             viewport: vp, options: SnapOptions(radius: 6))
        #expect(r.kind == .endpoint,
                "expected endpoint, got \(String(describing: r.kind)) at \(r.point)")
        #expect(r.point.distance(to: endpoint) < 0.01)
    }

    @Test("A lantern position beats an axis")
    func fixtureSlotBeatsAxis() {
        let s = state()
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1200, 800))
        // 灯 201 在 LX 1 的 x=-3500
        let slot = s.layout.toSheet(Vec2(-3500, 2400))
        let near = slot + Vec2(1.2, 1.2)
        let r = Snapper.snap(near, doc: s.doc, layout: s.layout,
                             viewport: vp, options: SnapOptions(radius: 6),
                             excludingFixture: 201)
        #expect(r.kind == .fixtureSlot,
                "expected fixtureSlot, got \(String(describing: r.kind))")
    }

    @Test("The axis beats collinear and grid")
    func axisBeatsGrid() {
        let s = state()
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1200, 800))
        // 点在 LX 1 中段（y = 2400），x 刻意偏离 250 网格
        let onBar = s.layout.toSheet(Vec2(1234, 2400)) + Vec2(0.3, 0.3)
        let r = Snapper.snap(onBar, doc: s.doc, layout: s.layout,
                             viewport: vp, options: SnapOptions(radius: 6))
        #expect(r.kind != .grid,
                "grid must not win over an axis, got \(String(describing: r.kind))")
        // 轴线吸附应落在杆中心线上
        let onAxis = s.layout.toSheet(Vec2(0, 2400))
        #expect(abs(r.point.y - onAxis.y) < 0.01,
                "should snap onto the bar centreline, got y=\(r.point.y)")
    }

    @Test("Outside the radius nothing snaps")
    func outsideRadius() {
        let s = state()
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1200, 800))
        // 坐标刻意取非 250 的倍数，避免恰好落在网格点上
        let far = s.layout.toSheet(Vec2(4113, 6387))
        let r = Snapper.snap(far, doc: s.doc, layout: s.layout,
                             viewport: vp, options: SnapOptions(radius: 1))
        #expect(r.kind == nil)
        #expect(r.point == far)
    }

    @Test("Among candidates of the same kind, the nearest wins")
    func nearestWithinKind() {
        var doc = TestData.validDocument()
        // 两根杆端点相距 4mm（图纸），取中间偏一方的点
        doc.positions = [
            Position(id: "A", kind: .horizontal, type: .truss, x0: -7500, x1: -100, y: 2400, trim: 6500),
            Position(id: "B", kind: .horizontal, type: .truss, x0: 0, x1: 7500, y: 2400, trim: 6500),
        ]
        let s = EditorState(doc: doc)
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1200, 800))
        let aEnd = s.layout.toSheet(Vec2(-100, 2400))
        let bEnd = s.layout.toSheet(Vec2(0, 2400))
        // 偏向 A 端
        let p = aEnd + (bEnd - aEnd) * 0.25
        let r = Snapper.snap(p, doc: doc, layout: s.layout,
                             viewport: vp, options: SnapOptions(radius: 8))
        #expect(r.kind == .endpoint)
        #expect(r.point.distance(to: aEnd) < 0.01, "nearest endpoint should win")
    }

    @Test("Snapping is symmetric around a candidate")
    func symmetric() {
        let s = state()
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1200, 800))
        let end = s.layout.toSheet(Vec2(-7500, 2400))
        let left = Snapper.snap(end + Vec2(-1.5, 0), doc: s.doc, layout: s.layout,
                                viewport: vp, options: SnapOptions(radius: 5),
                                excludingPosition: "LX 1")
        let right = Snapper.snap(end + Vec2(1.5, 0), doc: s.doc, layout: s.layout,
                                 viewport: vp, options: SnapOptions(radius: 5),
                                 excludingPosition: "LX 1")
        #expect(left.point == right.point)
        #expect(left.kind == right.kind)
    }

    @Test("Disabled snapping passes the point through untouched")
    func disabled() {
        let s = state()
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1200, 800))
        let end = s.layout.toSheet(Vec2(-7500, 2400)) + Vec2(0.5, 0.5)
        let r = Snapper.snap(end, doc: s.doc, layout: s.layout, viewport: vp,
                             options: SnapOptions(enabled: false))
        #expect(r.kind == nil)
        #expect(r.point == end)
    }

    /// 缩放不该改变"吸不吸得上"，只改变屏幕上多远算近。
    @Test("Snap radius is constant in screen points, not paper millimetres")
    func screenSpaceRadius() {
        let s = state()
        let end = s.layout.toSheet(Vec2(-7500, 2400))
        let offsetPaper = Vec2(3.0, 0)   // 图纸 3mm，且不在网格节奏上

        // 放大 2 倍时，同样的图纸偏移在屏幕上是 6pt；
        // 半径以"屏幕点"定义，所以 zoom 越大，可吸附的图纸范围越小。
        // 注意：**不能排除 LX 1** —— 要吸的就是它的端点。
        let zoomedIn = Viewport(zoom: 4, pan: .zero, sizePoints: Vec2(1200, 800))
        let r = Snapper.snap(end + offsetPaper, doc: s.doc, layout: s.layout,
                             viewport: zoomedIn, options: SnapOptions(radius: 8))
        // 8pt / zoom 4 = 图纸 2mm < 3mm 偏移 → 吸不上端点（也不会被网格抢走）
        #expect(r.kind != .endpoint,
                "at 4x zoom an 8pt radius covers only 2mm of paper")

        let zoomedOut = Viewport(zoom: 0.5, pan: .zero, sizePoints: Vec2(1200, 800))
        let r2 = Snapper.snap(end + offsetPaper, doc: s.doc, layout: s.layout,
                              viewport: zoomedOut, options: SnapOptions(radius: 8))
        // 8pt / 0.5 = 图纸 16mm > 3mm → 吸得上
        #expect(r2.kind == .endpoint,
                "at 0.5x zoom the same 8pt radius covers 16mm, so it must snap")
    }
}
