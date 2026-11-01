import Testing
import Foundation
@testable import LightPlotCore

@Suite("Fixture mounting")
struct ResolverTests {

    @Test("A lantern on a horizontal position takes its y from the bar")
    func horizontalMount() {
        let doc = TestData.validDocument()
        let f = doc.fixture(unit: 101)!
        let mount = Resolver.mount(of: f, in: doc)

        guard case .onPosition(let id, let axis, let shape) = mount else {
            Issue.record("expected onPosition, got \(mount)")
            return
        }
        #expect(id == "LX 1")
        #expect(axis == -3500)
        #expect(shape.isHorizontal)

        // x 是绝对世界坐标，y 来自构件。这是最容易被误解的一处。
        let p = mount.worldPoint!
        #expect(p.x == -3500)
        #expect(p.y == 2400)
        // 距杆端偏移 = -3500 - (-7500) = 4000
        #expect(mount.offsetFromStart == 4000)
    }

    @Test("A lantern on a vertical boom takes its x from the boom")
    func verticalMount() {
        let doc = TestData.validDocument()
        let f = doc.fixture(unit: 501)!
        let mount = Resolver.mount(of: f, in: doc)
        let p = mount.worldPoint!
        #expect(p.x == -8100)
        #expect(p.y == 1800)
        // 距 BOOM 底端偏移 = 1800 - 900 = 900
        #expect(mount.offsetFromStart == 900)
    }

    @Test("A practical is placed in world coordinates")
    func practicalMount() {
        let doc = TestData.validDocument()
        let f = doc.fixture(unit: 901)!
        guard case .free(let p) = Resolver.mount(of: f, in: doc) else {
            Issue.record("expected free")
            return
        }
        #expect(p == Vec2(-1600, 4400))
    }

    @Test("Unknown position resolves to a typed error, never a crash")
    func unknownPosition() {
        var doc = TestData.validDocument()
        doc.fixtures[0].pos = "NOPE"
        #expect(Resolver.mount(of: doc.fixtures[0], in: doc) == .unresolved(.fixtureUnknownPosition))
        #expect(Resolver.worldPoint(of: doc.fixtures[0], in: doc) == nil)
    }

    @Test("Missing coordinate resolves to a typed error")
    func missingCoordinate() {
        var doc = TestData.validDocument()
        doc.fixtures[0].x = nil
        #expect(Resolver.mount(of: doc.fixtures[0], in: doc) == .unresolved(.fixtureMissingCoordinate))
    }

    @Test("A lantern beyond the end of its bar is detected, not clamped")
    func offPosition() {
        var doc = TestData.validDocument()
        doc.fixtures[0].x = 9000          // LX 1 只到 7500

        let mount = Resolver.mount(of: doc.fixtures[0], in: doc)
        // 关键：坐标必须原样保留。悄悄夹紧会让图和数据不一致。
        #expect(mount.worldPoint?.x == 9000)
        #expect(Resolver.isOnPosition(mount) == false)

        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.fixtureOffPosition))
    }

    @Test("Ambiguous x and y on a bar is reported")
    func ambiguousMount() {
        var doc = TestData.validDocument()
        doc.fixtures[0].y = 2400          // 与 x 同时存在

        #expect(doc.fixtures[0].isAmbiguousMount)
        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.fixtureAmbiguousMount))

        // 即便如此，灯也必须仍然解在杆上（按轴线坐标）
        let p = Resolver.worldPoint(of: doc.fixtures[0], in: doc)!
        #expect(p.y == 2400)
    }

    @Test("Fixtures on a bar sort by offset")
    func sortedAlongBar() {
        var doc = TestData.validDocument()
        doc.fixtures = [
            Fixture(unit: 3, pos: "LX 1", x: 3000, type: "profile", gel: "L201", ch: 3, purpose: "X", beam: 20),
            Fixture(unit: 1, pos: "LX 1", x: -3000, type: "profile", gel: "L201", ch: 1, purpose: "X", beam: 20),
            Fixture(unit: 2, pos: "LX 1", x: 0, type: "profile", gel: "L201", ch: 2, purpose: "X", beam: 20),
        ]
        let list = Resolver.fixtures(on: "LX 1", in: doc)
        #expect(list.map(\.fixture.unit) == [1, 2, 3])
        #expect(list.map(\.offset) == [4500, 7500, 10500])
    }

    @Test("Every lantern in the real document resolves")
    func realDocumentResolves() throws {
        let doc = try TestData.realDocument()
        for (fixture, mount) in Resolver.allMounts(in: doc) {
            if case .unresolved(let code) = mount {
                Issue.record("unit \(fixture.unit) unresolved: \(code.rawValue)")
            }
            #expect(Resolver.isOnPosition(mount), "unit \(fixture.unit) hangs off its bar")
            #expect(mount.worldPoint != nil)
        }
    }

    @Test("All mounts come back in unit order")
    func stableOrder() throws {
        let doc = try TestData.realDocument()
        let units = Resolver.allMounts(in: doc).map(\.fixture.unit)
        #expect(units == units.sorted())
    }
}
