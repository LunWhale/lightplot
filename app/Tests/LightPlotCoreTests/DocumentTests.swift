import Testing
import Foundation
@testable import LightPlotCore

@Suite("Document model")
struct DocumentTests {

    @Test("Reads the real rig.yaml from the old pipeline")
    func readsRealDocument() throws {
        let doc = try TestData.realDocument()

        #expect(doc.meta.show == "DEATH OF A SALESMAN")
        #expect(doc.meta.playwright == "ARTHUR MILLER")
        #expect(doc.meta.profile == "hsc")   // 旧数据里的值，必须原样读进来
        #expect(doc.meta.scale == 25)
        #expect(doc.meta.director == "I DON'T KNOW")
        #expect(doc.meta.designer == "Brooks Li")

        #expect(doc.stage.width == 15000)
        #expect(doc.stage.depth == 9000)
        #expect(doc.stage.gridHeight == 8000)

        #expect(doc.positions.count == 7, "positions: \(doc.positions.map(\.id))")
        #expect(doc.fixtures.count == 32)
        #expect(doc.zones.count == 2)
        #expect(doc.gels.count == 9)
        #expect(doc.types.count == 7)

        // 三种构件类型都要出现，否则"画法不同"这件事就没被覆盖
        let types = Set(doc.positions.map(\.type))
        #expect(types.contains(.truss))
        #expect(types.contains(.pipe))
        #expect(types.contains(.line))

        // 竖直 BOOM 存在
        #expect(doc.position(id: "BOOM SL")?.kind == .vertical)
        #expect(doc.position(id: "LX 1")?.kind == .horizontal)

        // 灯号唯一且递增可排序
        let units = doc.fixtures.map(\.unit).sorted()
        #expect(Set(units).count == units.count)
    }

    @Test("The real document has zero errors — the app must open it clean")
    func realDocumentIsClean() throws {
        let doc = try TestData.realDocument()
        let issues = Lint.check(doc)
        let errors = issues.filter { $0.severity == .error }
        #expect(errors.isEmpty, "unexpected errors: \(errors.map { "\($0.code.rawValue) \($0.subject)" })")
    }

    @Test("Missing required fields do not crash decoding")
    func lenientDecoding() throws {
        let yaml = """
        meta:
          show: TINY
        stage:
          width: 10000
          depth: 8000
        positions:
        - id: LX 1
          kind: h
          type: truss
          x0: 0
          x1: 1000
          y: 500
        fixtures:
        - unit: 1
          pos: LX 1
          x: 500
          type: profile
        """
        let doc = try DocumentCodec.decodeYAML(yaml)
        #expect(doc.fixtures.count == 1)
        #expect(doc.fixtures[0].gel == nil)
        #expect(doc.fixtures[0].beam == nil)
        // 半成品文档必须能加载，缺的东西由 lint 报出来
        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.fixtureMissingField))
        #expect(codes.contains(.fixtureUnknownGel) == false, "nil gel is 'missing', not 'unknown'")
        #expect(codes.contains(.fixtureMissingBeam))
        #expect(codes.contains(.fixtureMissingPurpose))
    }

    @Test("YAML survives a write/read round trip")
    func yamlRoundTrip() throws {
        let original = TestData.validDocument()
        let text = try DocumentCodec.encodeYAML(original)
        let back = try DocumentCodec.decodeYAML(text)
        #expect(back == original)
    }

    @Test("The real document survives a YAML round trip")
    func realRoundTrip() throws {
        let original = try TestData.realDocument()
        let text = try DocumentCodec.encodeYAML(original)
        let back = try DocumentCodec.decodeYAML(text)
        #expect(back == original)
        // 关键字段逐个复核，避免"整体相等"掩盖某个字段被静默丢弃
        #expect(back.fixtures.count == original.fixtures.count)
        #expect(back.positions.map(\.id) == original.positions.map(\.id))
        #expect(back.gels.map(\.code) == original.gels.map(\.code))
    }

    @Test("JSON output is byte-identical across runs")
    func jsonDeterminism() throws {
        let doc = try TestData.realDocument()
        let a = try DocumentCodec.encodeJSON(doc)
        let b = try DocumentCodec.encodeJSON(doc)
        #expect(a == b)

        // 解回来必须完全相等
        let back = try DocumentCodec.decodeJSON(a)
        #expect(back == doc)
    }

    @Test("Empty input is rejected with a clear error")
    func emptyInput() {
        #expect(throws: DocumentCodec.CodecError.self) {
            _ = try DocumentCodec.decodeYAML(Data())
        }
    }

    @Test("Stage bounds include the audience")
    func stageBounds() {
        let doc = TestData.validDocument()
        let b = doc.stageBounds
        #expect(b.x0 == -7500 && b.x1 == 7500)
        #expect(b.y1 == 9000)
        // 7 排 × 560mm = 3920mm 观众席贴住台口，另留 500mm 走道/标注余量
        #expect(abs(b.y0 + 3920 + 500) < 1e-9)
    }

    @Test("Gel lookup and fixture lookup work by identity")
    func lookups() {
        let doc = TestData.validDocument()
        #expect(doc.gel(code: "L201")?.name == "Lee 201 Full CT Blue")
        #expect(doc.gel(code: "NOPE") == nil)
        #expect(doc.fixture(unit: 101)?.ch == 1)
        #expect(doc.fixture(unit: 999) == nil)
    }
}
