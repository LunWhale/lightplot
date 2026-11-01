import Testing
import Foundation
@testable import LightPlotCore

/// 编辑器内核测试。
///
/// 这一层是"能不能用"的关键：拖拽、吸附、撤销、灯不脱杆，全部在这里断言。
/// 视图层不参与这些测试 —— 这是内核/视图分离带来的最大好处。
@Suite("Editor core")
struct EditorTests {

    private func state() -> EditorState {
        EditorState(doc: TestData.validDocument())
    }

    private func paper(_ x: Double, _ y: Double, _ s: EditorState) -> Vec2 {
        s.layout.toSheet(Vec2(x, y))
    }

    // MARK: 选择

    @Test("Clicking a lantern selects it")
    func selectFixture() {
        var s = state()
        s = Editor.reduce(s, .selectAt(paper(-3500, 2400, s), additive: false))
        #expect(s.selection.fixtures == [101])
        #expect(s.selection.isEmpty == false)
    }

    @Test("Clicking a bar selects the bar")
    func selectPosition() {
        var s = state()
        // 点在 LX 1 上、但离任何灯都超过 8mm 的位置
        s = Editor.reduce(s, .selectAt(paper(1000, 2400, s), additive: false))
        #expect(s.selection.positions == ["LX 1"])
    }

    @Test("Lanterns win over bars when they overlap")
    func fixturePriority() {
        // 灯就压在杆上 —— 用户想抓的是灯，不是杆
        var s = state()
        s = Editor.reduce(s, .selectAt(paper(-3500, 2400, s), additive: false))
        if case .fixture(101) = Editor.hitTest(paper(-3500, 2400, s),
                                               doc: s.doc, layout: s.layout) {
            // ok
        } else {
            Issue.record("expected the lantern to win the hit test")
        }
    }

    @Test("Clicking empty space clears the selection")
    func clickEmpty() {
        var s = state()
        s = Editor.reduce(s, .selectAt(paper(-3500, 2400, s), additive: false))
        s = Editor.reduce(s, .clickEmpty)
        #expect(s.selection.isEmpty)
    }

    @Test("Marquee selects everything inside")
    func marquee() {
        var s = state()
        // 框住 LX 1 的两端和其中一盏灯。
        // 构件被选中要求**两端都在框内** —— 只框住中段不算选中，
        // 否则"框一小块就选中整根杆"会让批量操作变得危险。
        let r = Rect(x0: -8000, y0: 2000, x1: 8000, y1: 8000)
        s = Editor.reduce(s, .marqueeSelect(s.layout.sheetRectRect(r)))
        #expect(s.selection.positions.contains("LX 1"))
        #expect(s.selection.fixtures.contains(101))
        #expect(s.selection.fixtures.contains(501) == false, "BOOM SL is outside the marquee")

        // 只框中间一段：杆不该被选中，但灯要
        var s2 = EditorState(doc: TestData.validDocument())
        s2 = Editor.reduce(s2, .marqueeSelect(s2.layout.sheetRectRect(
            Rect(x0: -4000, y0: 2000, x1: -3000, y1: 3000))))
        #expect(s2.selection.positions.isEmpty, "partial coverage must not select a bar")
        #expect(s2.selection.fixtures.contains(101))
    }

    // MARK: 移动构件

    @Test("Moving a bar moves its lanterns with it")
    func movePositionCarriesFixtures() {
        var s = state()
        let before = Resolver.worldPoint(of: s.doc.fixture(unit: 101)!, in: s.doc)!

        s = Editor.reduce(s, .movePosition(id: "LX 1", by: Vec2(0, 600)))

        let after = Resolver.worldPoint(of: s.doc.fixture(unit: 101)!, in: s.doc)!
        #expect(after.y == before.y + 600)
        #expect(after.x == before.x, "lantern must not drift along the bar")
        // 灯仍然挂在同一根杆上
        #expect(s.doc.fixture(unit: 101)?.pos == "LX 1")
    }

    @Test("Shortening a bar leaves lanterns in place, and lint reports those now outside")
    func resizeDoesNotSecretlyMoveLanterns() {
        var s = state()
        // 把 LX 1 的左端从 -7500 拉到 -2000：灯 101 在 -3500，会落到杆外
        let target = s.layout.toDocument(s.layout.toSheet(Vec2(-2000, 2400)))
        s = Editor.reduce(s, .setPositionEnd(id: "LX 1", which: .start, to: s.layout.toSheet(target)))

        // 灯的坐标不动
        #expect(s.doc.fixture(unit: 101)?.x == -3500)
        // 但数据现在不一致，必须报出来
        let codes = Set(s.issues.map(\.code))
        #expect(codes.contains(.fixtureOffPosition),
                "shortening a bar must surface the lanterns left outside")
    }

    // MARK: 灯具

    @Test("Dropping a lantern near a bar locks it to that bar")
    func dropOnBar() {
        var s = state()
        let start = s
        // 放到 LX 1 上、x = 5000 处
        let fixture = Fixture(unit: 999, type: "profile", aim: 90,
                              gel: "L201", purpose: "TEST", beam: 26)
        s = Editor.reduce(s, .addFixture(fixture, at: paper(5000, 2400, start)))

        let added = s.doc.fixture(unit: 999)
        #expect(added != nil)
        #expect(added?.pos == "LX 1")
        #expect(added?.x == 5000)
        #expect(added?.y == nil, "a bar lantern must not carry a y coordinate")
        // 自动分配了通道
        #expect(added?.ch != nil)
        // 位置合法
        #expect(Resolver.isOnPosition(Resolver.mount(of: added!, in: s.doc)))
    }

    @Test("Dropping a lantern far from any bar becomes a practical, not a floating lantern")
    func dropInTheVoid() {
        var s = state()
        let start = s
        // 舞台中部、离所有杆都超过吸附半径
        let fixture = Fixture(unit: 998, type: "", aim: 90, gel: "L201",
                              purpose: "TEST", beam: 26)
        s = Editor.reduce(s, .addFixture(fixture, at: paper(2000, 6000, start)))

        let added = s.doc.fixture(unit: 998)
        #expect(added != nil)
        #expect(added?.type == "practical")
        #expect(added?.x != nil && added?.y != nil)
        // 必须能解析出世界坐标，不产生"飘着的灯"
        #expect(Resolver.mount(of: added!, in: s.doc).worldPoint != nil)
    }

    @Test("Dragging a lantern along its bar keeps it on the bar")
    func slideAlongBar() {
        var s = state()
        let start = s
        s = Editor.reduce(s, .moveFixture(unit: 101, to: paper(2000, 2400, start)))
        let f = s.doc.fixture(unit: 101)!
        #expect(f.pos == "LX 1")
        #expect(abs((f.x ?? 0) - 2000) < 1)
        #expect(f.y == nil)
    }

    @Test("Dragging a lantern off its bar is refused, not silently re-homed")
    func dragOffBarIsRefused() {
        var s = state()
        let start = s
        let original = s.doc.fixture(unit: 101)!
        // 拖到离所有杆都很远的地方
        s = Editor.reduce(s, .moveFixture(unit: 101, to: paper(0, 7000, start)))
        let f = s.doc.fixture(unit: 101)!
        #expect(f.pos == original.pos)
        #expect(f.x == original.x)
    }

    @Test("Moving a bar lantern never writes both coordinates")
    func neverAmbiguousMount() {
        var s = state()
        let start = s
        for x in stride(from: -7000.0, through: 7000.0, by: 500.0) {
            s = Editor.reduce(s, .moveFixture(unit: 101, to: paper(x, 2400, start)))
            let f = s.doc.fixture(unit: 101)!
            #expect(f.isAmbiguousMount == false,
                    "x=\(x) produced an ambiguous mount")
        }
    }

    @Test("Aim is normalised to whole degrees")
    func aimNormalised() {
        var s = state()
        s = Editor.reduce(s, .setFixtureAim(unit: 101, aim: 450.7))
        #expect(s.doc.fixture(unit: 101)?.aim == 91)
        s = Editor.reduce(s, .setFixtureAim(unit: 101, aim: -90))
        #expect(s.doc.fixture(unit: 101)?.aim == 270)
    }

    @Test("Deleting a bar keeps its lanterns but reports them")
    func deleteBarKeepsLanterns() {
        var s = state()
        s = Editor.reduce(s, .deletePosition(id: "LX 1"))
        #expect(s.doc.fixture(unit: 101) != nil, "lanterns must not be deleted implicitly")
        #expect(Set(s.issues.map(\.code)).contains(.fixtureUnknownPosition))
    }

    // MARK: 版面

    @Test("Scale changes are validated")
    func scaleValidation() {
        var s = state()
        s = Editor.reduce(s, .setScale(50))
        #expect(s.layout.scaleDenominator == 50)
        s = Editor.reduce(s, .setScale(0))
        #expect(s.layout.scaleDenominator == 50, "invalid scale must be rejected")
        s = Editor.reduce(s, .setScale(-25))
        #expect(s.layout.scaleDenominator == 50)
    }

    @Test("Auto-fit only moves the origin, never the scale")
    func autoFitKeepsScale() {
        var s = state()
        s = Editor.reduce(s, .setOrigin(Vec2(1, 2)))
        s = Editor.reduce(s, .autoFitOrigin)
        #expect(s.layout.scaleDenominator == 25)
        #expect(s.layout.originOnSheet != Vec2(1, 2))
    }
}

/// 撤销与不变量。
@Suite("Editor invariants")
struct EditorInvariantTests {

    @Test("Undo restores the document exactly")
    func undoIsExact() {
        var s = EditorState(doc: TestData.validDocument())
        let original = s.doc
        s = Editor.reduce(s, .movePosition(id: "LX 1", by: Vec2(0, 500)))
        #expect(s.doc != original)
        #expect(s.canUndo)
        s = Editor.reduce(s, .undo)
        #expect(s.doc == original)
    }

    @Test("Redo re-applies the undone change")
    func redoIsExact() {
        var s = EditorState(doc: TestData.validDocument())
        s = Editor.reduce(s, .movePosition(id: "LX 1", by: Vec2(0, 500)))
        let moved = s.doc
        s = Editor.reduce(s, .undo)
        s = Editor.reduce(s, .redo)
        #expect(s.doc == moved)
    }

    @Test("A long chain of do/undo/redo never loses state")
    func undoChain() {
        var s = EditorState(doc: TestData.validDocument())
        var history: [LXDocument] = [s.doc]
        for i in 1...20 {
            s = Editor.reduce(s, .movePosition(id: "LX 1", by: Vec2(0, Double(i) * 10)))
            history.append(s.doc)
        }
        for _ in 0..<20 { s = Editor.reduce(s, .undo) }
        #expect(s.doc == history[0])
        for _ in 0..<20 { s = Editor.reduce(s, .redo) }
        #expect(s.doc == history[20])
    }

    @Test("A new edit clears the redo stack")
    func redoClearedOnNewEdit() {
        var s = EditorState(doc: TestData.validDocument())
        s = Editor.reduce(s, .movePosition(id: "LX 1", by: Vec2(0, 100)))
        s = Editor.reduce(s, .undo)
        #expect(s.canRedo)
        s = Editor.reduce(s, .movePosition(id: "LX 1", by: Vec2(0, 200)))
        #expect(s.canRedo == false)
    }

    @Test("Undo on an empty stack is a no-op")
    func undoEmpty() {
        var s = EditorState(doc: TestData.validDocument())
        let before = s.doc
        s = Editor.reduce(s, .undo)
        s = Editor.reduce(s, .redo)
        #expect(s.doc == before)
    }

    /// 批量事件只压一次撤销点 —— 一次手势应当一步撤销。
    @Test("A batch of events undoes in one step")
    func batchUndo() {
        var s = EditorState(doc: TestData.validDocument())
        let original = s.doc
        s = Editor.reduce(s, batch: [
            .movePosition(id: "LX 1", by: Vec2(0, 100)),
            .movePosition(id: "LX 1", by: Vec2(0, 100)),
            .movePosition(id: "LX 1", by: Vec2(0, 100)),
        ])
        s = Editor.reduce(s, .undo)
        #expect(s.doc == original)
    }

    /// **核心不变量**：任何对构件的编辑之后，
    /// 每台构件上的灯都必须仍然解析到一根存在的杆上。
    @Test("Lanterns never lose their bar across a random edit sequence")
    func lanternsNeverDetach() {
        var rng = SeededGenerator(seed: 0xC0FFEE)
        var s = EditorState(doc: TestData.validDocument())

        let positionIDs = s.doc.positions.map(\.id)
        let units = s.doc.fixtures.map(\.unit)

        for _ in 0..<200 {
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                s = Editor.reduce(s, .movePosition(id: positionIDs.randomElement(using: &rng)!,
                                                   by: Vec2(Double.random(in: -300...300, using: &rng),
                                                            Double.random(in: -300...300, using: &rng))))
            case 1:
                let u = units.randomElement(using: &rng)!
                let p = Vec2(Double.random(in: 0...800, using: &rng),
                             Double.random(in: 0...600, using: &rng))
                s = Editor.reduce(s, .moveFixture(unit: u, to: p))
            case 2:
                s = Editor.reduce(s, .setFixtureAim(unit: units.randomElement(using: &rng)!,
                                                    aim: Double.random(in: -720...720, using: &rng)))
            case 3:
                s = Editor.reduce(s, .autoFitOrigin)
            default:
                s = Editor.reduce(s, .undo)
            }

            // 不变量 1：灯号唯一
            let allUnits = s.doc.fixtures.map(\.unit)
            #expect(Set(allUnits).count == allUnits.count, "duplicate unit after edit")

            // 不变量 2：构件上的灯必须解析到存在的杆
            for f in s.doc.fixtures where !f.isFreeMounted {
                if let posID = f.pos {
                    #expect(s.doc.position(id: posID) != nil,
                            "unit \(f.unit) points at missing position '\(posID)'")
                }
                #expect(Resolver.mount(of: f, in: s.doc).worldPoint != nil,
                        "unit \(f.unit) has no resolvable world point")
            }

            // 不变量 3：比例始终合法
            #expect(s.layout.isValid)
        }
    }

    /// 同一串事件跑两次，文档必须完全相同 —— 可字节级回归的前提。
    @Test("Reduction is deterministic")
    func deterministic() {
        func run() -> LXDocument {
            var rng = SeededGenerator(seed: 42)
            var s = EditorState(doc: TestData.validDocument())
            for _ in 0..<80 {
                s = Editor.reduce(s, .movePosition(id: "LX 1",
                                                   by: Vec2(Double.random(in: -100...100, using: &rng),
                                                            0)))
                s = Editor.reduce(s, .setFixtureAim(unit: 101,
                                                    aim: Double.random(in: 0...359, using: &rng)))
            }
            return s.doc
        }
        let a = try? DocumentCodec.encodeJSON(run())
        let b = try? DocumentCodec.encodeJSON(run())
        #expect(a == b)
    }
}

/// 可复现的随机数发生器 —— 测试里不能用系统随机源，
/// 那样失败时无法复现。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

extension SheetLayout {
    /// 文档矩形 → 图纸矩形（测试辅助）。
    func sheetRectRect(_ docRect: Rect) -> Rect {
        let a = toSheet(Vec2(docRect.x0, docRect.y0))
        let b = toSheet(Vec2(docRect.x1, docRect.y1))
        return Rect(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }
}
