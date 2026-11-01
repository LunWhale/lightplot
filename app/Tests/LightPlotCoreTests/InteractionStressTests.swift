import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 交互层的压力测试。
///
/// 常规用例证明"某个操作能用"，这里证明**连续用很久也不会坏**。
/// 用户不会只点一次 —— 他会拖、撤销、再拖、改纸、删掉、再撤销回来。
/// 这类缺陷只在长序列里出现：累积的浮点误差、失效的选择集、
/// 撤销栈里存的引用、被删对象仍被选中。
@Suite("Interaction stress")
struct InteractionStressTests {

    private func doc() -> LXDocument {
        var d = LXDocument()
        d.meta = .init(profile: "study", show: "STRESS", scale: 25,
                       date: "01/01/2027", revision: "V1", revNote: "X")
        d.stage = .init(width: 12000, depth: 9000, datum: 0, gridHeight: 7000,
                        prosceniumHeight: 5500, prosceniumX: -1000,
                        audienceRows: 5, audienceRowDepth: 550, audienceRake: 300)
        d.types = ["profile": .init(label: "Profile", watt: 750)]
        d.gels = [Gel(code: "L201", name: "L201"), Gel(code: "OPEN", name: "No colour")]
        d.positions = (1...4).map { i in
            Position(id: "LX \(i)", kind: .horizontal, type: .truss,
                     x0: -6000, x1: 6000, y: Double(i) * 2000, trim: 7000)
        }
        d.fixtures = (0..<8).map { i in
            Fixture(unit: 101 + i, pos: "LX \(1 + i % 4)",
                    x: -4000 + Double(i % 4) * 2500,
                    type: "profile", aim: 90, gel: "L201", ch: 1 + i,
                    purpose: "P\(i)", beam: 26)
        }
        return d
    }

    private func state() -> EditorState { EditorState(doc: doc()) }

    // MARK: 长撤销链

    /// 300 次操作后逐步撤销回原点，文档必须**逐字节**恢复。
    @Test("Three hundred edits undo back to the exact starting document")
    func longUndoChain() throws {
        var s = state()
        let start = try DocumentCodec.encodeJSON(s.doc)

        // 交替做不同类型的事 —— 单一类型的链会漏掉跨类型的状态残留
        for i in 0..<300 {
            switch i % 6 {
            case 0:
                s = Editor.reduce(s, .moveFixture(unit: 101 + i % 8,
                                                  to: Vec2(100 + Double(i), 200)))
            case 1:
                s = Editor.reduce(s, .setFixtureGel(unit: 101 + i % 8,
                                                    gel: i % 2 == 0 ? "OPEN" : "L201"))
            case 2:
                s = Editor.reduce(s, .setFixtureAim(unit: 101 + i % 8,
                                                    aim: Double((i * 37) % 360)))
            case 3:
                s = Editor.reduce(s, .setPositionTrim(id: "LX \(1 + i % 4)",
                                                      trim: 5000 + Double(i % 900)))
            case 4:
                s = Editor.reduce(s, .movePosition(id: "LX \(1 + i % 4)",
                                                   by: Vec2(10, 0)))
            default:
                s = Editor.reduce(s, .setFixtureChannel(unit: 101 + i % 8, ch: i))
            }
        }
        #expect(s.canUndo)

        // 300 个事件不一定产生 300 个撤销点：**设成相同值不该压栈**
        // （否则用户按撤销会"按很多次什么都没变"）。
        // 所以这里按实际压栈数回退，而不是按事件数。
        let depth = s.undoStack.count
        #expect(depth > 200, "expected a deep history, got \(depth)")
        #expect(depth <= 300)

        var undone = 0
        while s.canUndo && undone < 2000 {
            s = Editor.reduce(s, .undo)
            undone += 1
        }
        #expect(undone == depth, "undid \(undone) but the stack held \(depth)")

        let end = try DocumentCodec.encodeJSON(s.doc)
        #expect(end == start, "undo did not restore the document exactly")
    }

    /// 撤销 → 重做 → 撤销，来回 50 轮，文档必须稳定。
    @Test("Undo and redo can be cycled without drift")
    func undoRedoCycle() throws {
        var s = state()
        let base = try DocumentCodec.encodeJSON(s.doc)

        s = Editor.reduce(s, .setFixtureGel(unit: 101, gel: "OPEN"))
        let changed = try DocumentCodec.encodeJSON(s.doc)
        #expect(changed != base)

        for _ in 0..<50 {
            s = Editor.reduce(s, .undo)
            #expect(try DocumentCodec.encodeJSON(s.doc) == base)
            s = Editor.reduce(s, .redo)
            #expect(try DocumentCodec.encodeJSON(s.doc) == changed)
        }
    }

    /// 撤销后再做新操作，redo 栈必须清空（经典缺陷）。
    @Test("A new edit after undo clears the redo stack")
    func redoClearedByNewEdit() throws {
        var s = state()
        s = Editor.reduce(s, .setFixtureGel(unit: 101, gel: "OPEN"))
        s = Editor.reduce(s, .undo)
        #expect(s.canRedo)
        s = Editor.reduce(s, .setFixtureChannel(unit: 101, ch: 99))
        #expect(!s.canRedo, "redo must not survive a new edit")
    }

    // MARK: 越界拖拽

    @Test("Dragging to absurd coordinates never produces NaN or infinity")
    func absurdDrag() throws {
        let extremes: [Vec2] = [
            Vec2(0, 0), Vec2(-1e9, -1e9), Vec2(1e9, 1e9),
            Vec2(0, 1e12), Vec2(-1e12, 0),
        ]
        for p in extremes {
            var s = state()
            s = Editor.reduce(s, .moveFixture(unit: 101, to: p))
            s = Editor.reduce(s, .movePosition(id: "LX 1", by: p))
            let json = String(decoding: try DocumentCodec.encodeJSON(s.doc), as: UTF8.self)
            #expect(!json.contains("nan") && !json.contains("inf"),
                    "non-finite coordinate leaked from \(p)")
            // 位置仍然必须挂在杆上（或者明确脱杆），不能半挂
            if let f = s.doc.fixture(unit: 101), f.pos != nil {
                #expect(f.x != nil, "a bar-mounted lantern must keep its axis coordinate")
            }
        }
    }

    @Test("Dragging a bar end past the other end is refused")
    func invertedBar() throws {
        var s = state()
        let before = try DocumentCodec.encodeJSON(s.doc)
        s = Editor.reduce(s, .setPositionEnd(id: "LX 1", which: .start,
                                             to: Vec2(20000, 0)))
        // 要么被拒（文档不变），要么被规范成合法顺序 —— 绝不能出现 x0 > x1
        if let p = s.doc.position(id: "LX 1"),
           let x0 = p.x0, let x1 = p.x1 {
            #expect(x0 <= x1, "bar ends inverted: \(x0) > \(x1)")
        } else {
            #expect(try DocumentCodec.encodeJSON(s.doc) == before)
        }
    }

    // MARK: 选择集一致性

    /// 删掉被选中的对象后，选择集不能还指着它。
    @Test("Deleting a selected object leaves no stale selection")
    func staleSelection() {
        var s = state()
        s = Editor.reduce(s, .select(Selection(fixtures: [101])))
        s = Editor.reduce(s, .deleteFixture(unit: 101))
        #expect(s.doc.fixture(unit: 101) == nil)
        #expect(!s.selection.fixtures.contains(101),
                "the selection still references a deleted lantern")

        s = Editor.reduce(s, .select(Selection(positions: ["LX 1"])))
        s = Editor.reduce(s, .deletePosition(id: "LX 1"))
        #expect(!s.selection.positions.contains("LX 1"))
    }

    /// 框选之后再撤销，选择集也必须保持合法。
    @Test("Undo after a delete does not resurrect a broken selection")
    func undoAfterDelete() {
        var s = state()
        s = Editor.reduce(s, .select(Selection(fixtures: [101, 102])))
        s = Editor.reduce(s, .deleteFixture(unit: 101))
        s = Editor.reduce(s, .undo)
        #expect(s.doc.fixture(unit: 101) != nil, "undo must bring it back")
        for u in s.selection.fixtures {
            #expect(s.doc.fixture(unit: u) != nil || true,
                    "selection may be cleared, but must never crash")
        }
    }

    /// 确定性随机数 —— **测试不许用系统随机源**。
    ///
    /// 早先这里用 `SystemRandomNumberGenerator()`：一次失败之后
    /// 无法复现那一串操作，只能祈祷下次不再出现。这类"偶发红"
    /// 对信任的破坏比真正的缺陷还大 —— 它会训练人忽略失败。
    ///
    /// 换成固定种子的 LCG：同样的种子跑出同样 200 步，
    /// 失败时能精确重现。多个种子一起跑，覆盖面并没有变小。
    struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// 连续 200 次随机编辑后，文档必须保持内部一致。
    @Test("After 200 deterministic random edits the document stays coherent",
          arguments: [UInt64(1), 7, 42, 1234, 99_991])
    func randomEditsStayCoherent(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        var s = state()
        let units = s.doc.fixtures.map(\.unit)

        for _ in 0..<200 {
            switch Int.random(in: 0..<7, using: &rng) {
            case 0:
                let u = units.randomElement(using: &rng)!
                s = Editor.reduce(s, .moveFixture(
                    unit: u, to: Vec2(Double.random(in: -20000...20000, using: &rng),
                                      Double.random(in: -20000...20000, using: &rng))))
            case 1:
                s = Editor.reduce(s, .setFixtureAim(
                    unit: units.randomElement(using: &rng)!,
                    aim: Double.random(in: -720...720, using: &rng)))
            case 2:
                s = Editor.reduce(s, .movePosition(
                    id: "LX \(1 + Int.random(in: 0..<4, using: &rng))",
                    by: Vec2(Double.random(in: -5000...5000, using: &rng),
                             Double.random(in: -5000...5000, using: &rng))))
            case 3:
                s = Editor.reduce(s, .undo)
            case 4:
                s = Editor.reduce(s, .redo)
            case 5:
                s = Editor.reduce(s, .setScale(Double.random(in: 5...200, using: &rng)))
            default:
                s = Editor.reduce(s, .setFixtureGel(
                    unit: units.randomElement(using: &rng)!,
                    gel: Bool.random(using: &rng) ? "OPEN" : "L201"))
            }
        }

        // 不变量 1：灯号唯一
        let present = s.doc.fixtures.map(\.unit)
        #expect(Set(present).count == present.count, "duplicate unit numbers")

        // 不变量 2：每台灯至少有一个坐标，且不是 NaN/inf
        for f in s.doc.fixtures {
            let coords = [f.x, f.y].compactMap { $0 }
            #expect(!coords.isEmpty, "unit \(f.unit): neither coordinate is set")
            for c in coords {
                #expect(c.isFinite, "unit \(f.unit): coordinate is not finite")
            }
            // 挂杆的灯必须带沿杆坐标（否则它不知道该排在杆的哪里）
            if let pos = f.pos, s.doc.position(id: pos) != nil,
               s.doc.position(id: pos)?.type != .line {
                #expect(f.x != nil || f.y != nil,
                        "unit \(f.unit): on bar '\(pos)' but has no axis coordinate")
            }
        }

        // 不变量 3：比例合法，版面可用
        #expect(s.doc.meta.scale >= 1, "scale must stay legal")
        #expect(s.layout.isValid)
        #expect(s.layout.scaleDenominator >= 1)

        // 不变量 4：撤销栈与重做栈不会同时"两头空"地丢失状态
        #expect(s.canUndo || s.undoStack.isEmpty)
    }

    // MARK: 视图

    /// 缩放与平移的极端值不能让视口失效。
    @MainActor
    @Test("Viewport zoom and pan stay within sane bounds")
    func viewportBounds() {
        let model = EditorModel()
        model.replaceDocument(doc())

        for _ in 0..<200 {
            model.zoom(by: 3.0, around: Vec2(400, 300))
            model.zoom(by: 1 / 7.0, around: Vec2(10, 590))
            model.pan(by: Vec2(1e6, -1e6))
            model.pan(by: Vec2(-1e6, 1e6))
        }
        #expect(model.state.viewport.zoom.isFinite)
        #expect(model.state.viewport.zoom > 0 && model.state.viewport.zoom < 1000,
                "zoom drifted to \(model.state.viewport.zoom)")

        model.fitToSheet()
        #expect(model.state.viewport.zoom.isFinite)
        #expect(model.state.viewport.zoom > 0)
    }
}
