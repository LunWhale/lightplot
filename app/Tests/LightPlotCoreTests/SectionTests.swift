import Testing
import Foundation
@testable import LightPlotCore

/// 剖面图。
///
/// 剖面图比平面图多三类**物理**信息，这三类都必须可断言：
///   · 光束包络的几何（焦点处的光斑宽度要算得出来）
///   · 遮挡判定（光被布景挡住要能报出来）
///   · 视线检查（起坡够不够）
@Suite("Section layout")
struct SectionLayoutTests {

    @Test("Depth and height map onto paper axes")
    func axes() {
        let l = SectionLayout(paper: .a3, scaleDenominator: 50,
                              originOnSheet: Vec2(24, 96))
        // 纵深增加 → 向右
        #expect(l.toSheet(depth: 1000, height: 0).x == 24 + 20)
        // 高度增加 → 向上
        #expect(l.toSheet(depth: 0, height: 1000).y == 96 + 20)
        // 往返
        let back = l.toDocument(Vec2(60, 120))
        #expect(back.x == 1800 && back.y == 1200)
    }

    @Test("A3 section stays at 1:50 even when content overflows")
    func scaleIsLocked() {
        var doc = try? TestData.realDocument()
        doc?.stage.depth = 40000
        let sheet = SectionSheet(fitting: doc ?? LXDocument())
        #expect(sheet.layout.scaleDenominator == 50)
        #expect(sheet.layout.paper == .a3)
    }

    @Test("The real document's section fits A3")
    func realFits() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc)
        #expect(sheet.contentFitsSheet)
        #expect(sheet.ops.count > 200)
        #expect(sheet.textCount > 60)
    }

    @Test("Section cut lands on a set piece when one crosses the middle")
    func cutDepth() throws {
        var doc = try TestData.realDocument()
        doc.setPieces = [SetPiece(kind: .rect, x0: -1000, y0: 4000, x1: 1000, y1: 5600,
                                  label: "PLATFORM", height: 1200)]
        // 中点 4500 落在 4000...5600 内，切线应取该布景中点 4800
        #expect(doc.sectionCutDepth == 4800)

        doc.setPieces = [SetPiece(kind: .rect, x0: -1000, y0: 500, x1: 1000, y1: 900)]
        // 没有布景跨中点 → 回退到中点
        #expect(doc.sectionCutDepth == doc.stage.depth * 0.5)
    }

    @Test("Set height defaults are conservative and type-aware")
    func setHeights() throws {
        let doc = try TestData.realDocument()
        #expect(doc.sectionHeight(of: SetPiece(kind: .stair, x0: 0, y0: 0, x1: 1, y1: 1)) == 2400)
        #expect(doc.sectionHeight(of: SetPiece(kind: .rect, x0: 0, y0: 0, x1: 1, y1: 1)) == 750)
        // 显式给定的高度优先
        #expect(doc.sectionHeight(of: SetPiece(kind: .rect, x0: 0, y0: 0, x1: 1, y1: 1,
                                               height: 1500)) == 1500)
    }
}

@Suite("Beam geometry")
struct BeamGeometryTests {

    /// 光束沿**自身轴**张开，而不是沿纵深轴。
    ///
    /// 早先的实现用"同一纵深处两条边界的高度差"当宽度 —— 那是错的：
    /// 光轴斜着时，两条边界在同一纵深处的采样点并不对称，
    /// 算出来的宽度会随斜度变化，甚至出现"越远越窄"的假象。
    /// 正确的是：宽度 = 2 · tan(半角) · 沿轴距离。
    @Test("A beam widens along its own axis at the stated angle")
    func widening() {
        let apex = Vec2(2400, 6500)
        let focus = Vec2(5000, 0)
        let env = SectionGeometry.envelope(apex: apex, focusDepth: focus.x,
                                           focusHeight: focus.y,
                                           beamAngle: 26, reach: 6000)
        let distance = (focus - apex).length
        let halfAngle = 13.0 * .pi / 180

        for fraction in [0.3, 0.6, 1.0] {
            let expected = 2 * tan(halfAngle) * distance * fraction
            let actual = env.widthAlongAxis(atDistance: distance * fraction)
            #expect(actual > 0)
            #expect(abs(actual - expected) / expected < 0.01,
                    "at \(fraction) distance: \(actual) vs expected \(expected)")
        }

        // 单调变宽
        let near = env.widthAlongAxis(atDistance: distance * 0.3)
        let far = env.widthAlongAxis(atDistance: distance)
        #expect(far > near)
    }

    @Test("No slice outside the beam's reach")
    func outOfRange() {
        let env = SectionGeometry.envelope(apex: .zero, focusDepth: 1000, focusHeight: 0,
                                          beamAngle: 20, reach: 2000)
        #expect(env.slice(atDepth: -100) == nil)
        #expect(env.slice(atDepth: 5000) == nil)
    }

    /// 灯正对下方打是最常见的灯位。这里曾经除零崩溃 —— 必须守住。
    @Test("A beam aimed straight down does not divide by zero")
    func vertical() {
        let env = SectionGeometry.envelope(apex: Vec2(0, 5000),
                                           focusDepth: 0, focusHeight: 0,
                                           beamAngle: 30, reach: 5000)
        #expect(abs(env.axis.x) < 1e-9)
        #expect(env.axis.y < 0)

        // 只有 apex 那一层取得到截面（垂直光束不"沿纵深延伸"）
        let s = env.slice(atDepth: 0)
        #expect(s != nil, "a straight-down beam must still produce a slice at its own depth")
        #expect(s!.high > s!.low, "slice must have positive extent")
        #expect(env.slice(atDepth: 500) == nil,
                "off-axis depth is outside a perpendicular beam")
    }
}

@Suite("Blockage")
struct BlockageTests {

    @Test("A tall set piece blocks the beam")
    func blocked() {
        let env = SectionGeometry.envelope(apex: Vec2(0, 6000),
                                           focusDepth: 4000, focusHeight: 0,
                                           beamAngle: 20, reach: 5000)
        let wall = SectionGeometry.Blocker(Rect(x0: 1800, y0: 0, x1: 1900, y1: 5000), "WALL")
        let hit = SectionGeometry.blockage(env, by: [wall])
        #expect(hit != nil)
        #expect(hit?.label == "WALL")
        #expect((hit?.depth ?? 0) > 1500)
    }

    @Test("A short set piece does not block")
    func notBlocked() {
        let env = SectionGeometry.envelope(apex: Vec2(0, 6000),
                                           focusDepth: 4000, focusHeight: 0,
                                           beamAngle: 20, reach: 5000)
        let lowBench = SectionGeometry.Blocker(Rect(x0: 1800, y0: 0, x1: 1900, y1: 400), "BENCH")
        #expect(SectionGeometry.blockage(env, by: [lowBench]) == nil)
    }

    @Test("No blockers means no blockage")
    func empty() {
        let env = SectionGeometry.envelope(apex: .zero, focusDepth: 1000, focusHeight: 0,
                                           beamAngle: 20, reach: 2000)
        #expect(SectionGeometry.blockage(env, by: []) == nil)
    }
}

@Suite("Sightlines")
struct SightlineTests {

    @Test("A flat floor blocks the back rows")
    func flatFloorIsBlocked() {
        let lines = SectionGeometry.sightLines(
            rowCount: 6, rowDepth: 560, rake: 0,
            firstRowDepth: -3360, plasterDepth: -1200)
        #expect(lines.count == 6)
        // 平地上除了第一排，后面全部被挡
        #expect(lines[0].seesStageFloor)
        #expect(lines.dropFirst().allSatisfy { !$0.seesStageFloor })
    }

    @Test("Enough rake clears the sightlines")
    func sufficientRake() {
        // 实测：6 排 × 560mm 排距、切点在 -1200 时，
        // 每排需要约 400mm 才能让全部座位看到台面。
        // 这个数字本身就是剖面图的价值 —— 它在设计阶段就把"起坡够不够"算出来了。
        let lines = SectionGeometry.sightLines(
            rowCount: 6, rowDepth: 560, rake: 400,
            firstRowDepth: -3360, plasterDepth: -1200)
        #expect(lines.allSatisfy { $0.seesStageFloor },
                "margins: \(lines.map { Int($0.margin) })")

        // 350mm 不够：后排仍差 15mm
        let tight = SectionGeometry.sightLines(
            rowCount: 6, rowDepth: 560, rake: 350,
            firstRowDepth: -3360, plasterDepth: -1200)
        #expect(tight.last!.seesStageFloor == false)
    }

    @Test("The real document reports blocked rows")
    func realDocument() throws {
        let doc = try TestData.realDocument()
        let sheet = SectionSheet(fitting: doc)
        let blocked = sheet.sightLines.filter { !$0.seesStageFloor }
        // 现有数据的起坡是 160mm/排，不足以让后排看到台面。
        // 这个断言把"已知缺陷"固定下来：等数据改了，它会失败并提醒更新。
        #expect(!blocked.isEmpty, "if this passes the data has been fixed — update the test")
        let worst = blocked.min { $0.margin < $1.margin }!
        #expect(worst.margin < 0)
    }

    @Test("Elevation increases monotonically with rake")
    func monotonic() {
        let lines = SectionGeometry.sightLines(
            rowCount: 5, rowDepth: 500, rake: 150,
            firstRowDepth: -2500, plasterDepth: -1000)
        let eyes = lines.map(\.eyeHeight)
        #expect(eyes == eyes.sorted())
        #expect(eyes.first == SectionGeometry.seatedEyeHeight)
    }

    @Test("Zero rows produces no lines and does not crash")
    func emptyAudience() {
        #expect(SectionGeometry.sightLines(rowCount: 0, rowDepth: 560, rake: 160,
                                           firstRowDepth: 0, plasterDepth: 0).isEmpty)
    }
}
