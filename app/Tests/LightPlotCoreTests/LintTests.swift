import Testing
import Foundation
@testable import LightPlotCore

@Suite("Lint")
struct LintTests {

    @Test("A valid document produces no issues at all")
    func validIsSilent() {
        #expect(Lint.check(TestData.validDocument()).isEmpty)
        #expect(Lint.hasErrors(TestData.validDocument()) == false)
    }

    /// 这条守的是一个真实的历史 bug：
    /// 旧版 `qc.py` 不区分构件类型，于是"地面布景线 trim=0"
    /// 每次运行都报一条假警告。
    /// 假警告比漏报更危险 —— 它会训练人忽略所有警告。
    @Test("A ground line with trim 0 is not a low-trim warning")
    func groundLineTrimIsNotAWarning() {
        let doc = TestData.validDocument()
        let line = doc.positions.first { $0.type == .line }!
        #expect(line.trim == 0)

        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.positionTrimLow) == false,
                "trim=0 on a non-rigging line must not warn")

        // 但真正的吊挂构件 trim=0 必须报警
        var bad = doc
        bad.positions[0].trim = 0
        let badCodes = Set(Lint.check(bad).map(\.code))
        #expect(badCodes.contains(.positionTrimLow),
                "a truss trimmed to the floor must warn")
    }

    @Test("Missing trim on a line is tolerated; on a truss it is an error")
    func trimRequiredOnlyForRigging() {
        var doc = TestData.validDocument()
        doc.positions[0].trim = nil          // truss
        doc.positions[2].trim = nil          // line

        let issues = Lint.check(doc)
        let missing = issues.filter { $0.code == .positionMissingTrim }
        #expect(missing.count == 1)
        #expect(missing.first?.subject == "position LX 1")
    }

    @Test("The real document has only the expected gel-colour warnings")
    func realDocumentWarnings() throws {
        let doc = try TestData.realDocument()
        let issues = Lint.check(doc)

        let errors = issues.filter { $0.severity == .error }
        #expect(errors.isEmpty, "errors: \(errors.map { "\($0.code.rawValue) \($0.subject)" })")

        // 旧数据没有色片的真实 RGB —— 这是**故意可见的缺口**，
        // 不是 bug。补全色库后这个数字会变成 0。
        let nonOpenGels = doc.gels.filter { $0.code != "OPEN" }.count
        let colorWarnings = issues.filter { $0.code == .gelMissingColor }
        #expect(colorWarnings.count == nonOpenGels)

        // 除了缺颜色，不该有别的警告
        let otherCodes = Set(issues.map(\.code)).subtracting([.gelMissingColor])
        #expect(otherCodes.isEmpty, "unexpected warning codes: \(otherCodes.map(\.rawValue))")
    }

    @Test("Issues are ordered deterministically: errors first")
    func ordering() {
        var doc = TestData.validDocument()
        doc.gels[0].rgb = nil                      // warning
        doc.fixtures[0].ch = nil                   // error
        let issues = Lint.check(doc)
        #expect(issues.first?.severity == .error)
        #expect(issues.last?.severity == .warning)

        // 同一份数据跑两次，顺序与内容完全一致
        #expect(Lint.check(doc) == issues)
    }

    @Test("Non-ASCII is caught and named precisely")
    func nonASCII() {
        var doc = TestData.validDocument()
        doc.fixtures[0].purpose = "面光"
        let issue = Lint.check(doc).first { $0.code == .documentNonASCII }
        #expect(issue != nil)
        #expect(issue?.subject == "fixture 101")
        #expect(issue?.message.contains("U+") == true)
    }

    @Test("ASCII-only text with punctuation is allowed")
    func asciiPunctuationAllowed() {
        var doc = TestData.validDocument()
        doc.fixtures[0].purpose = "FRONT LIGHT / COOL (60%) - HERO"
        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.documentNonASCII) == false)
    }

    @Test("Collinear bars with a small gap are flagged as mergeable")
    func collinearGap() {
        var doc = TestData.validDocument()
        doc.positions[0].x1 = 0
        doc.positions.append(Position(id: "LX 1B", kind: .horizontal, type: .truss,
                                      x0: 60, x1: 7500, y: 2400, trim: 6500))
        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.positionCollinearGap))

        // 间隙太大就不是"该合并"，而是两根独立的杆
        var far = doc
        far.positions[3].x0 = 3000
        let farCodes = Set(Lint.check(far).map(\.code))
        #expect(farCodes.contains(.positionCollinearGap) == false)
    }

    @Test("Two parallel but offset bars are not collinear")
    func notCollinear() {
        var doc = TestData.validDocument()
        doc.positions[0].x1 = 0
        doc.positions.append(Position(id: "LX 2", kind: .horizontal, type: .truss,
                                      x0: 60, x1: 7500, y: 2600, trim: 6500))
        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(.positionCollinearGap) == false)
    }

    @Test("Severity mapping is stable for every code")
    func severities() {
        for code in LintCode.allCases {
            // 每个错误码都必须给出一个确定的严重度，不允许"看情况"
            _ = code.defaultSeverity
            #expect(code.title.isEmpty == false, "\(code.rawValue) has no title")
        }
    }
}
