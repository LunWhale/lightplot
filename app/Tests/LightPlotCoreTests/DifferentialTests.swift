import Testing
import Foundation
@testable import LightPlotCore

/// 差分回归。
///
/// 这里的重点不是"我们的图和旧管线一样"（不可能，版面改进了），
/// 而是**比对机制本身可信**：
///   · 相同的摘要必须判为无差异
///   · 结构性差异必须被抓到
///   · 命中已声明差异时不能误报
@Suite("Differential oracle")
struct DifferentialTests {

    private let oracle = """
    #             LightPlot sheet digest v1
    paper         841.000 x 594.000  scale 1:25
    frame.outer   0.000,0.000 -> 841.000,594.000
    position      LX 1  type=truss  kind=h  at=-7500.000,2400.000->7500.000,2400.000  span=600.000  cells=51  expect=51  trim=6500  sect=12.023
    fixture       101  pos=FOH LX  type=profile  on=FOH LX  axis=-3500.000  offset=4000.000  world=-3500.000,-900.000  onbar=1  aim=90.0  dir=0.00,1.00  gel=L201  ch=1  beam=26.0
    counts        positions=7  fixtures=32  zones=2  set=12  gels=9  types=7
    """

    @Test("Identical digests produce no differences")
    func identical() {
        #expect(DifferentialOracle.undeclaredDifferences(oracle: oracle, candidate: oracle).isEmpty)
    }

    @Test("A changed fixture is caught")
    func changedFixture() {
        let candidate = oracle.replacingOccurrences(of: "aim=90.0", with: "aim=270.0")
        let diffs = DifferentialOracle.undeclaredDifferences(oracle: oracle, candidate: candidate)
        #expect(diffs.count == 1)
        #expect(diffs[0].contains("fixture"))
    }

    @Test("A changed paper size is caught")
    func changedPaper() {
        let candidate = oracle.replacingOccurrences(of: "841.000 x 594.000", with: "420.000 x 297.000")
        let diffs = DifferentialOracle.undeclaredDifferences(oracle: oracle, candidate: candidate)
        #expect(diffs.count == 1)
        #expect(diffs[0].contains("paper"))
    }

    @Test("A missing line is caught")
    func missingLine() {
        let candidate = oracle.lineSplit(removing: 4).joined(separator: "\n")
        let diffs = DifferentialOracle.undeclaredDifferences(oracle: oracle, candidate: candidate)
        #expect(!diffs.isEmpty)
    }

    @Test("A declared deviation does not raise a false alarm")
    func declaredDeviationAllowed() {
        let candidate = oracle.replacingOccurrences(
            of: "position      LX 1",
            with: "position      LX 1B")
        // "position" 类别已声明（构件名位置不同），所以这个差异被放过
        let diffs = DifferentialOracle.undeclaredDifferences(oracle: oracle, candidate: candidate)
        #expect(diffs.isEmpty)
    }

    @Test("Description-only lines are ignored")
    func descriptionsIgnored() {
        let candidate = oracle + "\nsome free text that is not a key\n"
        #expect(DifferentialOracle.undeclaredDifferences(oracle: oracle, candidate: candidate).isEmpty)
    }

    @Test("Every declared deviation states a reason")
    func deviationsHaveReasons() {
        for d in DifferentialOracle.known {
            #expect(d.item.isEmpty == false)
            #expect(d.reason.count > 10, "deviation '\(d.item)' has no real explanation")
        }
    }

    @Test("The report is readable and mentions the declared deviations")
    func report() {
        let text = DifferentialOracle.report(oracle: oracle, candidate: oracle)
        #expect(text.contains("declared deviations"))
        #expect(text.contains("no undeclared differences"))
        for d in DifferentialOracle.known {
            #expect(text.contains(d.item))
        }
    }

    /// 端到端：把自己的摘要和自己比，必须无差异 ——
    /// 说明摘要本身是确定的、可比对的。
    @Test("Self comparison of a real digest is clean")
    func selfComparison() throws {
        let doc = try TestData.realDocument()
        let layout = SheetLayout.fitted(to: doc.contentBounds,
                                        paper: .a1, scaleDenominator: doc.meta.scale)
        let a = SheetDigest.render(doc, layout: layout)
        let b = SheetDigest.render(doc, layout: layout)
        #expect(DifferentialOracle.undeclaredDifferences(oracle: a, candidate: b).isEmpty)
    }
}

private extension String {
    /// 去掉第 n 行（0 基），用于模拟"候选缺失了一行"。
    func lineSplit(removing index: Int) -> [String] {
        var lines = split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if index < lines.count { lines.remove(at: index) }
        return lines
    }
}
