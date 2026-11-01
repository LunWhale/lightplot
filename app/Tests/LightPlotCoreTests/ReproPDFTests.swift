import Testing
import Foundation
@testable import LightPlotCore

/// 可复现输出：同一份数据两次出图必须**逐字节**相同。
///
/// 这不是洁癖。绘图工具的用户会反复出图对比，如果字节每次都变
/// （只是时间戳变了），就分不清"图改了"和"又生成了一次"。
@Suite("Reproducible PDF")
struct ReproPDFTests {

    private func tmp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("repro-\(UUID().uuidString).pdf")
    }

    @Test("Two writes of the same document normalise to identical bytes")
    func byteIdentical() throws {
        var doc = try DocumentCodec.decodeYAML(Data(contentsOf: TestData.rigYAML))
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = PlanSheet(fitting: doc)

        let a = tmp(), b = tmp()
        try SheetPDF.write(sheet, to: a)
        try SheetPDF.write(sheet, to: b)
        try PDFReproducible.normalise(fileAt: a)
        try PDFReproducible.normalise(fileAt: b)

        #expect(try Data(contentsOf: a) == Data(contentsOf: b),
                "normalised output must be byte-identical")
        try? FileManager.default.removeItem(at: a)
        try? FileManager.default.removeItem(at: b)
    }

    @Test("Normalising leaves the drawing content untouched")
    func contentPreserved() throws {
        var doc = try DocumentCodec.decodeYAML(Data(contentsOf: TestData.rigYAML))
        _ = GelLibrary.fillMissingColours(in: &doc)
        let url = tmp()
        try SheetPDF.write(PlanSheet(fitting: doc), to: url)

        let before = try Data(contentsOf: url)
        try PDFReproducible.normalise(fileAt: url)
        let after = try Data(contentsOf: url)

        // 只有日期与 ID 变，长度应基本不变（固定值长度不同会略差）
        let delta = abs(before.count - after.count)
        #expect(delta < 64, "normalising changed the file size by \(delta) bytes")

        // 正常化之后仍然是一份能被解析的 PDF
        #expect(String(data: after, encoding: .isoLatin1)?.hasPrefix("%PDF-") == true)
    }

    @Test("The normaliser replaces the date and the document id")
    func normaliserReplaces() {
        let input = """
        /CreationDate (D:20261029101517Z00'00')
        /ModDate (D:20261029101517Z00'00')
        /ID [ <95ab933eabf4f4e25991e38e4d3afa65> <95ab933eabf4f4e25991e38e4d3afa65> ]
        """
        let out = PDFReproducible.normalise(input)
        #expect(!out.contains("20261029101517"))
        #expect(out.contains(PDFReproducible.fixedDate))
        #expect(!out.contains("95ab933eabf4f4e25991e38e4d3afa65"))
        #expect(out.contains(String(repeating: "0", count: 32)))
    }

    /// CoreGraphics 的真实排版：`/ModDate` 与它的值被换行拆开，
    /// 而且 `(D:` 前缀只出现一次。这两点各自都能让正规化静默失效。
    @Test("A line-wrapped ModDate is still normalised")
    func wrappedModDate() {
        let input = """
        /Creator (LightPlot 1.0.0) /CreationDate (D:20261031233515Z00'00') /ModDate
        (D:20261031233516Z00'00') >>
        """
        let out = PDFReproducible.normalise(input)

        #expect(!out.contains("20261031233515"), "CreationDate survived")
        #expect(!out.contains("20261031233516"), "the wrapped ModDate survived")
        // 不能出现双重的 D: 前缀
        #expect(!out.contains("D:D:"), "produced a doubled D: prefix: \(out)")
        // 两个日期都必须变成同一个固定值（各出现一次）
        let stamp = "(" + PDFReproducible.fixedDate + ")"
        let occurrences = out.components(separatedBy: stamp).count - 1
        #expect(occurrences == 2,
                "expected both dates pinning to \(stamp), got \(occurrences)")
    }

    @Test("Normalising twice is the same as once")
    func idempotent() {
        let input = "/CreationDate (D:20260101120000Z)\n/ID [ <abc> <abc> ]"
        let once = PDFReproducible.normalise(input)
        let twice = PDFReproducible.normalise(once)
        #expect(once == twice)
    }

    @Test("A PDF with no date fields is left alone")
    func noFields() throws {
        let plain = "%PDF-1.3\n1 0 obj\n<< /Type /Catalog >>\nendobj\n"
        #expect(PDFReproducible.normalise(plain) == plain)
    }
}
