import Testing
import Foundation
@testable import LightPlotCore

// MARK: - 几何基元

@Suite("Geometry")
struct GeometryTests {

    @Test("Rect normalises a negative drag")
    func rectNormalises() {
        let r = Rect(x0: 10, y0: 10, x1: 0, y1: 0)
        #expect(r.width == 10)
        #expect(r.height == 10)
        #expect(r.x0 == 0)
        #expect(r.y1 == 10)
    }

    @Test("Rect from a single point is degenerate, from none is nil")
    func rectFromPoints() {
        #expect(Rect(points: []) == nil)
        let r = Rect(points: [Vec2(1, 2)])
        #expect(r?.width == 0)
        #expect(r?.contains(Vec2(1, 2)) == true)
    }

    @Test("Strict overlap does not count a shared edge")
    func strictOverlap() {
        let a = Rect(x0: 0, y0: 0, x1: 10, y1: 10)
        let touching = Rect(x0: 10, y0: 0, x1: 20, y1: 10)
        let overlapping = Rect(x0: 9.9, y0: 0, x1: 20, y1: 10)
        #expect(a.overlapsStrictly(touching) == false)
        #expect(a.overlapsStrictly(overlapping))
        #expect(a.intersects(touching) == false)
    }

    @Test("Projection clamps outside the segment")
    func projectionClamps() {
        let a = Vec2(0, 0), b = Vec2(100, 0)
        #expect(Vec2(-50, 10).projected(onto: a, b).t == 0)
        #expect(Vec2(150, 10).projected(onto: a, b).t == 1)
        #expect(abs(Vec2(50, 10).projected(onto: a, b).t - 0.5) < 1e-12)
        // 零长度线段不得产生 NaN
        let t = Vec2(5, 5).projected(onto: a, a)
        #expect(t.t == 0)
        #expect(t.point == a)
    }

    @Test("Angle conventions match the aim field")
    func angles() {
        #expect(abs(Vec2(angleDegrees: 0).x - 1) < 1e-12)
        #expect(abs(Vec2(angleDegrees: 90).y - 1) < 1e-12)
        #expect(abs(Vec2(angleDegrees: 90).x) < 1e-12)
        #expect(abs(Vec2(angleDegrees: 180).x + 1) < 1e-12)
        #expect(abs(Vec2(angleDegrees: 270).y + 1) < 1e-12)
        #expect(abs(Vec2(1, 0).angleDegrees) < 1e-12)
        #expect(abs(Vec2(0, 1).angleDegrees - 90) < 1e-12)
    }
}

// MARK: - 坐标变换

@Suite("Transforms")
struct TransformTests {

    @Test("1:25 collapses a 15 m stage into 600 mm of paper")
    func scaleIsExact() {
        let layout = SheetLayout(paper: .a1, scaleDenominator: 25, originOnSheet: Vec2(355, 215))
        let a = layout.toSheet(Vec2(-7500, 0))
        let b = layout.toSheet(Vec2(7500, 0))
        #expect(abs((b.x - a.x) - 600) < 1e-9)
        #expect(abs(a.x - 55) < 1e-9)
        #expect(abs(b.x - 655) < 1e-9)
    }

    @Test("Round trip document -> sheet -> document")
    func roundTrip() {
        let layout = SheetLayout()
        for p in [Vec2(0, 0), Vec2(-7500, 2400), Vec2(7451.25, -3980.5)] {
            let back = layout.toDocument(layout.toSheet(p))
            #expect(abs(back.x - p.x) < 1e-9)
            #expect(abs(back.y - p.y) < 1e-9)
        }
    }

    @Test("Frame matches the measured reference geometry")
    func frame() {
        let layout = SheetLayout()
        #expect(layout.outerFrame == Rect(x0: 0, y0: 0, x1: 841, y1: 594))
        #expect(layout.innerFrame == Rect(x0: 20, y0: 20, x1: 821, y1: 574))
    }

    @Test("Invalid scale is detectable")
    func invalidScale() {
        #expect(SheetLayout(scaleDenominator: 25).isValid)
        #expect(SheetLayout(scaleDenominator: 0).isValid == false)
        #expect(SheetLayout(scaleDenominator: -5).isValid == false)
    }

    /// 这是"以光标为中心缩放"的核心不变量。
    /// 手感差最常见的根因就是这里差半格 —— 所以必须测。
    @Test("Zoom keeps the point under the cursor fixed")
    func cursorCentredZoom() {
        var vp = Viewport(zoom: 1.5, pan: Vec2(-120, 340), sizePoints: Vec2(1200, 800))
        for anchor in [Vec2(0, 0), Vec2(600, 400), Vec2(1199, 1), Vec2(37, 762)] {
            for factor in [1.1, 0.5, 4.0, 0.97] {
                let before = vp.toSheet(anchor)
                vp = vp.zoomed(by: factor, around: anchor)
                let after = vp.toSheet(anchor)
                #expect(abs(before.x - after.x) < 1e-9, "x drifted at \(anchor) factor \(factor)")
                #expect(abs(before.y - after.y) < 1e-9, "y drifted at \(anchor) factor \(factor)")
            }
        }
    }

    @Test("Zoom is clamped and never returns a zero or infinite zoom")
    func zoomClamp() {
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(800, 600))
        #expect(vp.zoomed(by: 1e9, around: .zero).zoom.isFinite)
        #expect(vp.zoomed(by: 1e-9, around: .zero).zoom > 0)
    }

    @Test("Fitting places the rect inside the viewport with padding")
    func fitted() {
        let vp = Viewport(zoom: 1, pan: .zero, sizePoints: Vec2(1000, 700))
        let target = Rect(x0: 100, y0: 50, x1: 500, y1: 350)
        let fitted = vp.fitted(to: target, padding: 40)
        let tl = fitted.toView(Vec2(target.x0, target.y1))   // 左上（图纸 y 向上）
        let br = fitted.toView(Vec2(target.x1, target.y0))   // 右下
        #expect(tl.x >= 39.9 && tl.y >= 39.9)
        #expect(br.x <= 960.1 && br.y <= 660.1)
        // 居中
        #expect(abs((tl.x + br.x) / 2 - 500) < 1e-6)
        #expect(abs((tl.y + br.y) / 2 - 350) < 1e-6)
    }

    @Test("View flips y exactly once")
    func yFlip() {
        let vp = Viewport(zoom: 2, pan: Vec2(10, 100), sizePoints: Vec2(500, 400))
        #expect(vp.toView(.zero) == Vec2(10, 100))
        // 图纸 y 增大 → 视图 y 减小
        #expect(vp.toView(Vec2(0, 10)).y == 80)
        #expect(vp.toSheet(Vec2(10, 100)) == .zero)
    }
}
