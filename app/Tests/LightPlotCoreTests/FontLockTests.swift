import Testing
import Foundation
@testable import LightPlotCore

/// 字体锁定。
///
/// 图纸上每一个字宽都依赖这一个字体。如果它悄悄变了，
/// 所有按字宽算的版式（图签列宽、标签避让、图例折行）会静默错位 ——
/// 而画面上"看起来还在"，只是挤在一起。这类问题最难排查。
///
/// 所以字体必须是**内置**的，而且一旦变了测试要立刻失败。
@Suite("Font lock")
struct FontLockTests {

    @Test("The bundled font files are present and registered")
    func bundled() {
        _ = FontLibrary.regular   // 触发注册
        let names = FontLibrary.registeredURLs.map { $0.lastPathComponent }.sorted()
        #expect(names.contains("LiberationSans-Regular.ttf"),
                "regular font is missing from the bundle: \(names)")
        #expect(names.contains("LiberationSans-Bold.ttf"),
                "bold font is missing from the bundle: \(names)")
    }

    /// **这条是全套排版的基石。**
    /// 如果哪天有人删了字体文件，它会失败，而不是让 iPad 静默退回 Helvetica。
    @Test("The app really uses the bundled font, not a system fallback")
    func notFallingBack() {
        let regular = FontLibrary.regular
        let bold = FontLibrary.bold
        #expect(regular.fontIdentifier == "LiberationSans",
                "regular resolved to '\(regular.fontIdentifier)' — bundled font did not load")
        #expect(bold.fontIdentifier == "LiberationSans-Bold",
                "bold resolved to '\(bold.fontIdentifier)'")
        // Arial / Helvetica 出现即说明回退了
        for bad in ["Arial", "Helvetica"] {
            #expect(!regular.fontIdentifier.lowercased().contains(bad.lowercased()))
            #expect(!bold.fontIdentifier.lowercased().contains(bad.lowercased()))
        }
    }

    @Test("cap/em matches the font file, not a hardcoded Arial constant")
    func capRatio() {
        // Liberation Sans 实测 cap/em = 0.6880；Arial 是 0.7163。
        // 若这里返回 0.7163，说明代码里还有硬编码的 Arial 常量在生效。
        #expect(abs(FontLibrary.regular.capToEm - 0.6880) < 0.002,
                "capToEm = \(FontLibrary.regular.capToEm)")
        #expect(abs(Paper.emToCapFallback - 0.7163) < 1e-9,
                "the fallback constant should still record Arial's value for reference")
    }

    /// Liberation Sans 与 Arial 的 advance width **逐字符一致** ——
    /// 这正是选它的理由：换字体不会让版式全部重排。
    @Test("Glyph advances are stable across the common ASCII range")
    func advancesAreStable() {
        let m = FontLibrary.regular
        // 固定一组参考值（em 单位）。这些数字变了，说明字体换了，必须重新 bless。
        let expected: [(String, Double)] = [
            ("A", 667.0 / 1000), ("M", 833.0 / 1000), ("W", 944.0 / 1000),
            ("i", 222.0 / 1000), (" ", 278.0 / 1000),
        ]
        for (ch, em) in expected {
            let actual = m.advanceEM(ch)
            #expect(abs(actual - em) < 0.001,
                    "'\(ch)' advance = \(actual), expected \(em)")
        }
    }

    @Test("A 100 mm string measures the same regardless of where it is asked")
    func measurementIsDeterministic() {
        let a = FontLibrary.regular.widthMM("DEATH OF A SALESMAN", capMM: 8.19)
        let b = FontLibrary.regular.widthMM("DEATH OF A SALESMAN", capMM: 8.19)
        #expect(a == b)
        #expect(a > 100 && a < 200, "sanity: 19 characters at 8.19 mm cap ≈ 130 mm, got \(a)")
    }

    /// 字体换了 → 版面会动 → 摘要里的 `face=` 与所有文字位置都会变。
    /// 这条把"字体标识进摘要"这个机制本身固定住。
    @Test("The digest records which font was used")
    func digestRecordsFont() throws {
        let doc = TestData.validDocument()
        let layout = SheetLayout.fitted(to: doc.contentBounds,
                                        paper: .a1, scaleDenominator: 25)
        let digest = SheetDigest.render(doc, layout: layout)
        #expect(digest.contains("face=LiberationSans"),
                "digest must name the actual font so regressions are visible")
    }
}
