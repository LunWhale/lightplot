import Testing
import Foundation
@testable import LightPlotCore

@Suite("Gel library")
struct GelLibraryTests {

    @Test("Every documented gel number from the real project exists in the library")
    func coversRealProjectGels() throws {
        let doc = try TestData.realDocument()
        for gel in doc.gels where gel.code != "OPEN" {
            #expect(GelLibrary.entry(for: gel.code) != nil,
                    "\(gel.code) (\(gel.name)) is missing from the library")
        }
    }

    @Test("Colour codes are unique across Lee and Rosco")
    func uniqueCodes() {
        let codes = GelLibrary.all.map(\.code)
        #expect(Set(codes).count == codes.count,
                "duplicate codes: \(Dictionary(grouping: codes, by: { $0 }).filter { $1.count > 1 }.keys)")
    }

    @Test("Colour values are real, not placeholders")
    func coloursAreMeaningful() {
        for e in GelLibrary.all {
            #expect(e.rgb <= 0xFFFFFF)
            // OPEN 是白色，必须真的是白
            if e.code == "OPEN" { #expect(e.rgb == 0xFFFFFF) }
        }
        // 抽样检查色相：L119 是深蓝，L106 是红，L124 是绿
        let darkBlue = GelLibrary.entry(for: "L119")!.rgb
        #expect(((darkBlue >> 16) & 0xFF) < ((darkBlue) & 0xFF) * 4,
                "L119 should be blue-dominant")
        let red = GelLibrary.entry(for: "L106")!.rgb
        #expect(((red >> 16) & 0xFF) > ((red) & 0xFF) * 2, "L106 should be red-dominant")
        let green = GelLibrary.entry(for: "L124")!.rgb
        #expect(((green >> 8) & 0xFF) > ((green >> 16) & 0xFF), "L124 should be green-dominant")
    }

    @Test("Lookup accepts bare numbers")
    func flexibleLookup() {
        #expect(GelLibrary.entry(for: "201")?.code == "L201")
        #expect(GelLibrary.entry(for: "l201")?.code == "L201")
        #expect(GelLibrary.entry(for: " L201 ")?.code == "L201")
        #expect(GelLibrary.entry(for: "R02")?.code == "R02")
        #expect(GelLibrary.entry(for: "999") == nil)
    }

    /// **只填空缺，不覆盖** —— 用户可能按自己学校的滤镜实测改过。
    @Test("Filling colours never overwrites an existing value")
    func fillRespectsExisting() throws {
        var doc = try TestData.realDocument()
        for i in doc.gels.indices { doc.gels[i].rgb = nil }
        // 手动设一个"用户自定义"的值
        let index = doc.gels.firstIndex { $0.code == "L201" }!
        doc.gels[index].rgb = 0x123456

        let filled = GelLibrary.fillMissingColours(in: &doc)
        #expect(filled > 0)
        #expect(doc.gels.first { $0.code == "L201" }?.rgb == 0x123456,
                "the user's value must survive")
        // 其余都被补上了
        let stillMissing = doc.gels.filter { $0.rgb == nil }
        #expect(stillMissing.isEmpty, "still missing: \(stillMissing.map(\.code))")
    }

    @Test("After filling, the real document has no colour warnings")
    func noColourWarningsAfterFill() throws {
        var doc = try TestData.realDocument()
        #expect(Lint.check(doc).contains { $0.code == .gelMissingColor })
        _ = GelLibrary.fillMissingColours(in: &doc)
        let remaining = Lint.check(doc).filter { $0.code == .gelMissingColor }
        #expect(remaining.isEmpty, "still warning: \(remaining.map(\.subject))")
    }

    @Test("Colour swatches actually reach the legend")
    func legendShowsColour() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)

        // 图例里每个非黑非白的填充都应该是一块色片
        var colourFills = 0
        for op in sheet.ops {
            if case .fill(_, let rgb) = op, rgb != Paper.whiteRGB, rgb != Paper.blackRGB {
                colourFills += 1
            }
        }
        // 色块数必须等于**图上用到的**非 OPEN 色片数。
        // 早先断言"≥ 色片表里的非 OPEN 项"（8），那是旧行为（列全表）。
        // 现在图例只列在用的色片，所以这个数字由 fixtures 决定，不是色片表决定。
        let usedNonOpen = Set(doc.fixtures.compactMap(\.gel)).subtracting(["OPEN"]).count
        #expect(colourFills == usedNonOpen,
                "expected \(usedNonOpen) colour swatches, got \(colourFills)")
    }

    @Test("CSV import parses real rows and skips junk")
    func csvImport() {
        let csv = """
        code,name,rgb,purpose
        L999,Custom Blue,#2E4E8F,MY WASH
        L998,Another,123456,OTHER
        bad-line
        L997,No Colour,badhex,X
        """
        let gels = GelLibrary.importRows(csv)
        #expect(gels.count == 2)
        #expect(gels[0].code == "L999")
        #expect(gels[0].rgb == 0x2E4E8F)
        #expect(gels[1].rgb == 0x123456)
    }

    @Test("Library entries convert into document gels")
    func entryToGel() {
        let e = GelLibrary.entry(for: "L132")!
        let gel = GelLibrary.gel(from: e)
        #expect(gel.code == "L132")
        #expect(gel.rgb == e.rgb)
        #expect(gel.purpose.isEmpty == false)
    }
}
