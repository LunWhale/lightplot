import Testing
import Foundation
@testable import LightPlotCore

/// 选中与删除。
///
/// 守的是一个真实缺口：**能添加却不能选中**的物件等于不存在。
/// 布景与光区曾经只能加、不能选、不能删 —— 用户加了就再也去不掉。
@Suite("Selection")
struct SelectionTests {

    private func docWithExtras() -> LXDocument {
        var doc = TestData.validDocument()
        doc.setPieces = [
            SetPiece(kind: .rect, x0: -1000, y0: 4000, x1: 1000, y1: 5000,
                     label: "PLATFORM", height: 1200),
            SetPiece(kind: .line, x0: 3000, y0: 3000, x1: 3000, y1: 6000,
                     label: "WALL", height: 2400),
        ]
        doc.zones = [Zone(id: "Z1", x0: -4000, y0: 2000, x1: 4000, y1: 8000)]
        return doc
    }

    private func paper(_ x: Double, _ y: Double, _ s: EditorState) -> Vec2 {
        s.layout.toSheet(Vec2(x, y))
    }

    // MARK: 命中

    @Test("A set piece is hit inside its footprint")
    func hitSetPiece() {
        let s = EditorState(doc: docWithExtras())
        let hit = Editor.hitTest(paper(0, 4500, s), doc: s.doc, layout: s.layout)
        guard case .setPiece(let id)? = hit else {
            Issue.record("expected a set piece hit, got \(String(describing: hit))")
            return
        }
        #expect(id.contains("rect"))
    }

    @Test("A line set piece is hit near the line, not across the whole stage")
    func hitLine() {
        let s = EditorState(doc: docWithExtras())
        // 线上
        if case .setPiece? = Editor.hitTest(paper(3000, 4500, s),
                                            doc: s.doc, layout: s.layout) {
            // ok
        } else {
            Issue.record("expected a hit on the wall line")
        }
        // 在光区内、但远离墙线与平台：应当命中光区
        // （平台占 x -1000...1000 / y 4000...5000，所以取 x=3000,y=7000）
        let far = Editor.hitTest(paper(3000, 7000, s), doc: s.doc, layout: s.layout)
        if case .zone? = far { } else {
            Issue.record("empty area of the zone should hit the zone, got \(String(describing: far))")
        }
    }

    /// 布景必须优先于光区 —— 光区框通常很大，否则会把里面所有东西都盖住。
    @Test("A set piece wins over an enclosing zone")
    func setPieceBeatsZone() {
        let s = EditorState(doc: docWithExtras())
        // 这个点在平台内部，同时也在 Z1 内部
        let hit = Editor.hitTest(paper(0, 4500, s), doc: s.doc, layout: s.layout)
        if case .setPiece? = hit { } else {
            Issue.record("the set piece must win over the zone")
        }
    }

    @Test("Lanterns still win over everything")
    func fixtureBeatsAll() {
        let s = EditorState(doc: docWithExtras())
        // 灯 101 在 LX 1 上 (-3500, 2400)
        let hit = Editor.hitTest(paper(-3500, 2400, s), doc: s.doc, layout: s.layout)
        if case .fixture(101)? = hit { } else {
            Issue.record("the lantern must win, got \(String(describing: hit))")
        }
    }

    @Test("Tapping selects a set piece")
    func selectSetPiece() {
        var s = EditorState(doc: docWithExtras())
        s = Editor.reduce(s, .selectAt(paper(0, 4500, s), additive: false))
        #expect(s.selection.setPieces.count == 1)
        #expect(s.selection.isEmpty == false)
    }

    @Test("Marquee selects set pieces and zones")
    func marqueeExtras() {
        var s = EditorState(doc: docWithExtras())
        let r = Rect(x0: -5000, y0: 1900, x1: 5000, y1: 8100)
        s = Editor.reduce(s, .marqueeSelect(s.layout.sheetRectRect(r)))
        #expect(s.selection.setPieces.count == 2)
        #expect(s.selection.zones.contains("Z1"))
    }

    // MARK: 移动

    @Test("Moving a set piece keeps the selection valid")
    func moveSetPiece() {
        var s = EditorState(doc: docWithExtras())
        let original = s.doc.setPieces[0]
        s = Editor.reduce(s, .select(.init(setPieces: [original.id])))
        s = Editor.reduce(s, .moveSetPiece(id: original.id, by: Vec2(500, 300)))

        let moved = s.doc.setPieces[0]
        #expect(moved.x0 == original.x0 + 500)
        #expect(moved.y0 == original.y0 + 300)
        // id 由坐标派生 → 必须跟着变
        #expect(moved.id != original.id)
        // 选择集必须指向新的 id，否则用户拖一次就"失去选中"
        #expect(s.selection.setPieces == [moved.id])
    }

    @Test("Moving a stair keeps its depth")
    func moveStair() {
        var doc = docWithExtras()
        doc.setPieces = [SetPiece(kind: .stair, x0: 0, y0: 0, x1: 1000, y1: 3360,
                                  steps: 12, height: 2400)]
        var s = EditorState(doc: doc)
        let before = s.doc.setPieces[0].rect
        let id = s.doc.setPieces[0].id
        s = Editor.reduce(s, .moveSetPiece(id: id, by: Vec2(200, 400)))
        let after = s.doc.setPieces[0].rect
        #expect(abs(after.height - before.height) < 1e-9, "stair depth must not change")
        #expect(after.x0 == before.x0 + 200)
        #expect(after.y0 == before.y0 + 400)
    }

    @Test("Moving a set piece is undoable in one step")
    func moveUndo() {
        var s = EditorState(doc: docWithExtras())
        let original = s.doc.setPieces[0]
        s = Editor.reduce(s, .moveSetPiece(id: original.id, by: Vec2(300, 0)))
        s = Editor.reduce(s, .undo)
        #expect(s.doc.setPieces[0].x0 == original.x0)
    }

    // MARK: 删除

    @Test("Deleting a set piece clears it from the selection")
    func deleteSetPiece() {
        var s = EditorState(doc: docWithExtras())
        let id = s.doc.setPieces[0].id
        s = Editor.reduce(s, .select(.init(setPieces: [id])))
        s = Editor.reduce(s, .deleteSetPiece(id: id))
        #expect(s.doc.setPieces.count == 1)
        #expect(s.selection.setPieces.isEmpty, "deleted item must leave the selection")
    }

    @Test("Deleting a zone clears it from the selection")
    func deleteZone() {
        var s = EditorState(doc: docWithExtras())
        s = Editor.reduce(s, .select(.init(zones: ["Z1"])))
        s = Editor.reduce(s, .deleteZone(id: "Z1"))
        #expect(s.doc.zone(id: "Z1") == nil)
        #expect(s.selection.zones.isEmpty)
    }

    /// 一次删除多项只压一个撤销点。
    @Test("Deleting several extras undoes in one step")
    func batchDelete() {
        var s = EditorState(doc: docWithExtras())
        s = Editor.reduce(s, .select(.init(zones: ["Z1"],
                                           setPieces: Set(s.doc.setPieces.map(\.id)))))
        s = Editor.reduce(s, batch: s.doc.setPieces.map { .deleteSetPiece(id: $0.id) }
                          + [.deleteZone(id: "Z1")])
        #expect(s.doc.setPieces.isEmpty)
        #expect(s.doc.zones.isEmpty)
        s = Editor.reduce(s, .undo)
        #expect(s.doc.setPieces.count == 2)
    }

    /// 真实的"加了就删得掉"闭环。
    @Test("Anything you can add, you can select and delete")
    func addThenRemove() {
        var s = EditorState(doc: TestData.validDocument())
        let before = (s.doc.setPieces.count, s.doc.zones.count)

        let centre = s.layout.toSheet(Vec2(0, 4500))
        // 加布景
        s = Editor.reduce(s, .addSetPiece(SetPiece(kind: .rect, x0: -1000, y0: 4000,
                                                   x1: 1000, y1: 5000, label: "X",
                                                   height: 900)))
        // 加光区
        s = Editor.reduce(s, .addZone(Zone(id: "NEW", x0: -3000, y0: 3000,
                                           x1: 3000, y1: 7000)))
        #expect(s.doc.setPieces.count == before.0 + 1)
        #expect(s.doc.zones.count == before.1 + 1)

        // 选中刚加的布景
        s = Editor.reduce(s, .selectAt(centre, additive: false))
        #expect(!s.selection.setPieces.isEmpty, "the new set piece must be selectable")

        // 选中光区（点在布景外、光区内）
        s = Editor.reduce(s, .selectAt(s.layout.toSheet(Vec2(2500, 6500)), additive: false))
        #expect(s.selection.zones.contains("NEW"), "the new zone must be selectable")

        // 全部删掉
        s = Editor.reduce(s, .select(.init(zones: ["NEW"],
                                           setPieces: Set(s.doc.setPieces.map(\.id)))))
        for id in s.doc.setPieces.map(\.id) { s = Editor.reduce(s, .deleteSetPiece(id: id)) }
        s = Editor.reduce(s, .deleteZone(id: "NEW"))
        #expect(s.doc.setPieces.count == before.0)
        #expect(s.doc.zones.count == before.1)
    }
}
