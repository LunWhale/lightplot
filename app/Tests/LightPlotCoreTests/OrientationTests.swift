import Testing
import Foundation
@testable import LightPlotCore

@Suite("Fixture orientation")
struct OrientationTests {

    @Test("Every fixture type has a declared forward direction")
    func everyTypeDeclared() {
        for key in SymbolLibrary.all.keys {
            #expect(FixtureOrientation.forward[key] != nil,
                    "\(key) has no forward direction; drawing would be a guess")
        }
        // practical 用 USITT 三角，也必须声明
        #expect(FixtureOrientation.forward["practical"] != nil)
    }

    @Test("Rotation puts the declared forward on the aim", arguments: [
        "profile", "fresnel", "par", "follow", "led", "mover", "practical",
    ])
    func aimIsCorrect(type: String) {
        for aim in [0.0, 45, 90, 135, 180, 225, 270, 315] {
            #expect(FixtureOrientation.isAimCorrect(for: type, aim: aim),
                    "\(type) at aim \(aim) is wrong")
        }
    }

    /// 这条守的是那个真实事故：所有灯整体反 180°、对着观众。
    @Test("The old aim + 90 rule is 180° out for profiles")
    func regressionForTheReversalBug() {
        // 旧代码 rotation = aim + 90 等价于认定前方是 -Y。
        // profile 的真实前方是 +Y，所以两者相差 180°。
        let oldForward = Vec2(0, -1)
        let newForward = FixtureOrientation.forwardDirection(for: "profile")
        #expect(newForward.dot(oldForward) < -0.99,
                "profile forward should be opposite to the old assumption")
    }

    /// 剖面法是朝向判断的依据，必须复现出实测的不对称性。
    @Test("Measured cross-section asymmetry matches the declared forward",
          arguments: [
            ("fresnel", true), ("par", true), ("follow", false),
          ])
    func profileAsymmetry(type: String, wideTail: Bool) {
        let shape = SymbolLibrary.top(for: type)!
        let p = FixtureOrientation.crossSectionProfile(polygons: shape.polygons)
        #expect(p.count == 20)
        let head = p.prefix(4).reduce(0, +) / 4
        let tail = p.suffix(4).reduce(0, +) / 4

        // 前方是 +Y ⇒ 镜片在尾部 ⇒ tail 更宽
        if wideTail {
            #expect(tail > head * 2,
                    "\(type): expected a wide lens end, head=\(head) tail=\(tail)")
            #expect(FixtureOrientation.forwardDirection(for: type).y > 0)
        } else {
            #expect(head > tail * 1.1,
                    "\(type): expected a wide lens end at the head, head=\(head) tail=\(tail)")
            #expect(FixtureOrientation.forwardDirection(for: type).y < 0)
        }
    }

    @Test("Symmetric symbols are not guessed from geometry")
    func symmetricSymbolsDeclared() {
        // led / mover 是左右镜像，靠几何无法判定前后 —— 必须声明。
        for type in ["led", "mover"] {
            let shape = SymbolLibrary.top(for: type)!
            let p = FixtureOrientation.crossSectionProfile(polygons: shape.polygons)
            let head = p.prefix(4).reduce(0, +) / 4
            let tail = p.suffix(4).reduce(0, +) / 4
            #expect(abs(head - tail) / max(head, tail) < 0.1,
                    "\(type) unexpectedly asymmetric — revisit the declaration")
            #expect(FixtureOrientation.forward[type] != nil)
        }
    }

    /// 图上画的符号必须**精确等于**"源符号按声明旋转后的形状"。
    ///
    /// 这条替换了早先的"宽端朝上"断言。那个断言基于一个错误的假设：
    /// 它假定符号的宽端就是镜片端。实际量过（并把符号画出来看过）之后，
    /// profile / fresnel / par 的**宽端是后部的喇叭形底座**，
    /// 镜片（灯罩）反而是较窄的那一端 —— 所以"比宽度"得出的结论
    /// 与图面相反，测试会冤枉正确的代码。
    ///
    /// 真正的不变量是：绘制管线必须忠实套用 `FixtureOrientation.rotation`。
    /// 配合 `isAimCorrect`（声明的 forward 旋转后正好指向 aim），
    /// 这一条链就闭合了：源符号 → 声明前向 → 旋转 → 落图。
    @Test("The drawn symbol is the source symbol under the declared rotation",
          arguments: ["profile", "fresnel", "par", "led", "mover", "follow"])
    func drawnSymbolIsRotatedSource(type: String) throws {
        let src = SymbolLibrary.top(for: type)!
        let srcBox = Rect(points: src.polygons.flatMap { $0 })!
        let srcLong = max(srcBox.width, srcBox.height)

        for aim in [0.0, 45, 90, 135, 180, 225, 270, 315] {
            var doc = TestData.validDocument()
            doc.fixtures = [Fixture(unit: 1, pos: "LX 1", x: 0, type: type,
                                    aim: aim, gel: "L201", ch: 1, purpose: "X",
                                    beam: 26)]
            let sheet = PlanSheet(fitting: doc)
            let at = sheet.layout.toSheet(Vec2(0, 2400))

            // 图上实际画出来的多边形
            var drawn: [[Vec2]] = []
            for op in sheet.ops {
                if case .stroke(let pts, _, let layer, _, _) = op, layer == "FIXTURE" {
                    drawn.append(pts)
                }
            }
            #expect(drawn.count == src.polygons.count,
                    "\(type)@\(aim): expected \(src.polygons.count) polygons, got \(drawn.count)")

            // 按 drawSymbol 的算法重算，逐点比对
            let rotation = FixtureOrientation.rotation(for: type, aim: aim)
            let targetLong: Double = 11.2   // 与 PlanBuilder 的符号长轴一致
            let sc = targetLong / srcLong
            for (pi, poly) in src.polygons.enumerated() where pi < drawn.count {
                let want = poly.map { at + Vec2($0.x * sc, $0.y * sc)
                    .rotated(byDegrees: rotation) }
                #expect(want.count == drawn[pi].count)
                for (k, w) in want.enumerated() where k < drawn[pi].count {
                    let got = drawn[pi][k]
                    #expect(abs(w.x - got.x) < 1e-6 && abs(w.y - got.y) < 1e-6,
                            "\(type)@\(aim) p\(pi)[\(k)]: want \(w), got \(got)")
                }
            }
        }
    }

    /// 反向 aim 必须是镜像 —— 否则"朝向"只是画了个固定符号。
    @Test("Opposite aims produce mirrored symbols")
    func oppositeAimsMirror() {
        func points(_ aim: Double) -> [Vec2] {
            var doc = TestData.validDocument()
            doc.fixtures = [Fixture(unit: 1, pos: "LX 1", x: 0, type: "fresnel",
                                    aim: aim, gel: "L201", ch: 1, purpose: "X",
                                    beam: 26)]
            let sheet = PlanSheet(fitting: doc)
            var out: [Vec2] = []
            for op in sheet.ops {
                if case .stroke(let pts, _, let layer, _, _) = op, layer == "FIXTURE" {
                    out.append(contentsOf: pts)
                }
            }
            return out
        }
        let up = points(90), down = points(270)
        #expect(up.count == down.count)
        let upBox = Rect(points: up)!, downBox = Rect(points: down)!
        let upC = Vec2((upBox.x0 + upBox.x1) / 2, (upBox.y0 + upBox.y1) / 2)
        let downC = Vec2((downBox.x0 + downBox.x1) / 2, (downBox.y0 + downBox.y1) / 2)
        // 关于自身中心做 180° 旋转后应当重合
        var maxErr = 0.0
        for i in 0..<min(up.count, down.count) {
            let a = up[i] - upC
            let b = down[i] - downC
            maxErr = max(maxErr, abs(-a.x - b.x), abs(-a.y - b.y))
        }
        #expect(maxErr < 1e-6, "aim 90 and aim 270 should be 180-degrees apart, err=\(maxErr)")
    }

    @Test("Unknown types fall back without crashing")
    func unknownType() {
        #expect(FixtureOrientation.forwardDirection(for: "unknown").y == -1)
        #expect(FixtureOrientation.isAimCorrect(for: "unknown", aim: 90))
        #expect(FixtureOrientation.crossSectionProfile(polygons: []).isEmpty)
    }
}
