import Testing
import Foundation
@testable import LightPlotCore

@Suite("Sheet digest")
struct DigestTests {

    private func digest(_ doc: LXDocument) -> String {
        SheetDigest.render(doc, layout: SheetLayout(paper: .a1,
                                                    scaleDenominator: doc.meta.scale))
    }

    @Test("Digest is byte-identical across runs")
    func deterministic() throws {
        let doc = try TestData.realDocument()
        #expect(digest(doc) == digest(doc))
    }

    @Test("Digest contains no placeholder values")
    func noPlaceholders() throws {
        let text = digest(try TestData.realDocument())
        for bad in ["nan", "UNRESOLVED", "INVALID SHAPE", "nil"] {
            #expect(text.contains(bad) == false, "digest contains '\(bad)'")
        }
    }

    @Test("Digest records the counts and the paper geometry")
    func keyLines() throws {
        let doc = try TestData.realDocument()
        let text = digest(doc)
        #expect(text.contains("positions=7"))
        #expect(text.contains("fixtures=32"))
        #expect(text.contains("zones=2"))
        #expect(text.contains("gels=9"))
        #expect(text.contains("types=7"))
        #expect(text.contains("841.000 x 594.000"))
        #expect(text.contains("scale 1:25"))
        #expect(text.contains("frame.inner"))
        #expect(text.contains("DEATH OF A SALESMAN"))
    }

    @Test("Changing one field changes exactly one line")
    func singleLineDiff() throws {
        let before = try TestData.realDocument()
        var after = before
        // 只改一盏灯的出光方向
        let idx = after.fixtures.firstIndex { $0.unit == 101 }!
        after.fixtures[idx].aim = 45

        let changed = TestData.changedLines(digest(before), digest(after))
        #expect(changed.count == 1, "expected 1 changed line, got \(changed.count): \(changed)")
        let first = changed.first ?? ""
        #expect(first.hasPrefix("fixture"), "changed line: \(first)")
        #expect(first.contains("101"))
    }

    @Test("Moving a bar is visible in the digest")
    func barMove() throws {
        let before = TestData.validDocument()
        var after = before
        after.positions[0].y = 3000
        let changed = TestData.changedLines(digest(before), digest(after))
        #expect(changed.contains { $0.hasPrefix("position") && $0.contains("LX 1") })
    }

    @Test("A broken document still produces a digest, with the fault visible")
    func faultVisable() {
        var doc = TestData.validDocument()
        doc.fixtures[0].pos = "NOPE"
        let text = digest(doc)
        #expect(text.contains("UNRESOLVED"))
        #expect(text.contains("fixtureUnknownPosition"))
        #expect(text.contains("lint") && text.contains("error=1"))
    }

    @Test("Truss cell count matches span / pitch")
    func trussCells() {
        // validDocument 的 LX 1 是 15000mm 长。
        // 15000 / 294.22 = 50.98 → 应铺 51 格。
        let text = digest(TestData.validDocument())
        #expect(text.contains("cells=51"))
        #expect(text.contains("expect=51"))
    }

    @Test("Digest is stable through a YAML round trip")
    func roundTripStable() throws {
        let doc = TestData.validDocument()
        let back = try DocumentCodec.decodeYAML(DocumentCodec.encodeYAML(doc))
        #expect(digest(back) == digest(doc))
    }

    @Test("Number formatting never emits exponent notation")
    func formatting() {
        for v in [0.0, 1e-9, 1e6, -1e-9, 1234.56789, 0.0004] {
            let s = SheetDigest.f(v, 3)
            #expect(s.contains("e") == false || s == "nan", "\(v) formatted as \(s)")
            #expect(s.contains("E") == false, "\(v) formatted as \(s)")
        }
        #expect(SheetDigest.f(-1e-9, 3) == "0.000")
        #expect(SheetDigest.f(1234.56789, 2) == "1234.57")
    }
}
