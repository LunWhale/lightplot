import Testing
import Foundation
@testable import LightPlotCore

/// 桁架合并。
///
/// 这是用户点名要的功能，也是最容易做出"看起来合了、数据断了"的操作。
/// 所以测试覆盖的重点不是"能不能合"，而是**什么时候必须拒绝**。
@Suite("Bar merging")
struct MergerTests {

    /// 两根共线、端点相接的桁架。
    private func twoBars(gap: Double = 0) -> LXDocument {
        var doc = LXDocument()
        doc.stage = .init(width: 20000, depth: 9000)
        doc.positions = [
            Position(id: "LX 1A", kind: .horizontal, type: .truss,
                     x0: -5000, x1: 0, y: 2400, trim: 6500),
            Position(id: "LX 1B", kind: .horizontal, type: .truss,
                     x0: gap, x1: 5000, y: 2400, trim: 6500),
            Position(id: "BOOM", kind: .vertical, type: .pipe,
                     x: -8100, y0: 900, y1: 7200, trim: 3600),
        ]
        doc.types = ["profile": .init(label: "Profile"), "par": .init(label: "PAR")]
        doc.gels = [Gel(code: "L201", name: "Lee 201", rgb: 0x2E4E8F),
                    Gel(code: "OPEN", name: "No colour")]
        doc.fixtures = [
            Fixture(unit: 1, pos: "LX 1A", x: -4000, type: "profile",
                    gel: "L201", ch: 1, purpose: "A", beam: 26),
            Fixture(unit: 2, pos: "LX 1B", x: 2500, type: "profile",
                    gel: "L201", ch: 2, purpose: "B", beam: 26),
        ]
        return doc
    }

    @Test("Two touching bars merge into one")
    func mergeTouching() {
        let doc = twoBars()
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        guard case .merge(let c) = Merger.evaluate(a, b, in: doc) else {
            Issue.record("expected a merge")
            return
        }
        #expect(c.merged.id == "LX 1A")
        guard case .horizontal(let x0, let x1, let y) = c.merged.shape! else {
            Issue.record("wrong shape")
            return
        }
        #expect(x0 == -5000 && x1 == 5000 && y == 2400)
        #expect(c.gap == 0)
    }

    @Test("A small gap still merges")
    func mergeSmallGap() {
        let doc = twoBars(gap: 20)
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        guard case .merge = Merger.evaluate(a, b, in: doc) else {
            Issue.record("20mm gap should merge")
            return
        }
    }

    @Test("A large gap is refused")
    func refuseLargeGap() {
        let doc = twoBars(gap: 400)
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        #expect(Merger.evaluate(a, b, in: doc) == .refuse(.tooFar))
    }

    @Test("Bars on different axes are refused")
    func refuseNotCollinear() {
        var doc = twoBars()
        doc.positions[1].y = 3000
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        #expect(Merger.evaluate(a, b, in: doc) == .refuse(.notCollinear))
    }

    @Test("A truss and a pipe cannot merge")
    func refuseDifferentType() {
        var doc = twoBars()
        doc.positions[1].type = .pipe
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        #expect(Merger.evaluate(a, b, in: doc) == .refuse(.differentType))
    }

    @Test("Horizontal and vertical bars cannot merge")
    func refuseMixedOrientation() {
        let doc = twoBars()
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "BOOM")!
        #expect(Merger.evaluate(a, b, in: doc) == .refuse(.notCollinear))
    }

    @Test("A bar cannot merge with itself")
    func refuseSelf() {
        let doc = twoBars()
        let a = doc.position(id: "LX 1A")!
        #expect(Merger.evaluate(a, a, in: doc) == .refuse(.sameBar))
    }

    @Test("Vertical bars merge too")
    func mergeVertical() {
        var doc = twoBars()
        doc.positions = [
            Position(id: "B1", kind: .vertical, type: .pipe, x: -8100, y0: 0, y1: 3000, trim: 3600),
            Position(id: "B2", kind: .vertical, type: .pipe, x: -8100, y0: 3000, y1: 7200, trim: 3600),
        ]
        doc.fixtures = []
        guard case .merge(let c) = Merger.evaluate(doc.positions[0], doc.positions[1], in: doc) else {
            Issue.record("expected a merge")
            return
        }
        guard case .vertical(let x, let y0, let y1) = c.merged.shape! else {
            Issue.record("wrong shape")
            return
        }
        #expect(x == -8100 && y0 == 0 && y1 == 7200)
    }

    /// **最重要的一条**：合并后灯具必须无损。
    @Test("Applying a merge moves every lantern onto the surviving bar")
    func applyKeepsLanterns() {
        var doc = twoBars()
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        guard case .merge(let c) = Merger.evaluate(a, b, in: doc) else {
            Issue.record("expected a merge"); return
        }

        let before = Resolver.allMounts(in: doc).map { ($0.fixture.unit, $0.mount.worldPoint!) }
        Merger.apply(c, to: &doc)
        let after = Resolver.allMounts(in: doc).map { ($0.fixture.unit, $0.mount.worldPoint!) }

        #expect(doc.positions.count == 2, "the absorbed bar must be gone")
        #expect(doc.position(id: "LX 1B") == nil)

        // 每盏灯的世界坐标一点都不能变
        for (unit, p) in before {
            let found = after.first { $0.0 == unit }
            #expect(found != nil, "unit \(unit) disappeared")
            #expect(found?.1 == p, "unit \(unit) moved from \(p) to \(String(describing: found?.1))")
        }

        // 全部挂在保留的那根杆上，且仍然在杆内
        for f in doc.fixtures {
            #expect(f.pos == "LX 1A")
            #expect(Resolver.isOnPosition(Resolver.mount(of: f, in: doc)))
        }
    }

    @Test("Merging reports how many lanterns it affected")
    func reportsLanternCount() {
        let doc = twoBars()
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        guard case .merge(let c) = Merger.evaluate(a, b, in: doc) else {
            Issue.record("expected a merge"); return
        }
        #expect(c.fixturesMoved == 2)
    }

    @Test("Trim keeps the higher value")
    func trimKeepsHigher() {
        var doc = twoBars()
        doc.positions[0].trim = 6000
        doc.positions[1].trim = 7000
        let a = doc.position(id: "LX 1A")!, b = doc.position(id: "LX 1B")!
        guard case .merge(let c) = Merger.evaluate(a, b, in: doc) else {
            Issue.record("expected a merge"); return
        }
        #expect(c.merged.trim == 7000)
    }

    @Test("Candidate discovery is deterministic")
    func candidatesDeterministic() {
        var doc = twoBars()
        doc.positions.append(Position(id: "LX 1C", kind: .horizontal, type: .truss,
                                      x0: 5000, x1: 8000, y: 2400, trim: 6500))
        let first = Merger.candidates(in: doc)
        let second = Merger.candidates(in: doc)
        #expect(first == second)
        #expect(first.count >= 2)
        // 按 id 排序
        #expect(first.map(\.a) == first.map(\.a).sorted())
    }

    @Test("The editor event is a no-op when the merge is refused")
    func eventRefusesSilently() {
        var s = EditorState(doc: twoBars(gap: 400))
        let before = try? DocumentCodec.encodeJSON(s.doc)
        s = Editor.reduce(s, .mergePositions(keep: "LX 1A", absorb: "LX 1B"))
        let after = try? DocumentCodec.encodeJSON(s.doc)
        #expect(before == after, "a refused merge must not change the document")
        #expect(s.canUndo == false, "a refused merge must not push an undo point")
    }

    @Test("The editor event merges and is undoable in one step")
    func eventMergesAndUndoes() {
        var s = EditorState(doc: twoBars())
        let original = s.doc
        s = Editor.reduce(s, .mergePositions(keep: "LX 1A", absorb: "LX 1B"))
        #expect(s.doc.positions.count == original.positions.count - 1)
        #expect(s.selection.positions == ["LX 1A"])
        s = Editor.reduce(s, .undo)
        #expect(s.doc == original)
    }

    @Test("The real document has no mergeable pairs — its bars are already whole")
    func realDocumentIsAlreadyMerged() throws {
        let doc = try TestData.realDocument()
        let candidates = Merger.candidates(in: doc)
        #expect(candidates.isEmpty,
                "unexpected merge candidates: \(candidates.map(\.description))")
    }
}
