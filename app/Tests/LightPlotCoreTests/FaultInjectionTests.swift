import Testing
import Foundation
@testable import LightPlotCore

/// 故障注入：**验证验证器本身**。
///
/// 这套项目的历史上出现过 5 次"全绿但是错的"。每一次的根本原因都一样：
/// 断言存在，但它对应的失败路径从未被执行过。
///
/// 所以这里对每一条校验规则都注入一个已知的错，断言：
///   1. 校验器确实会报出来
///   2. 报的是**正确的错误码**，不是碰巧别的规则兜住了
///
/// 并且有一条元测试要求"每个 LintCode 都有对应的注入用例"。
/// 新增规则却不加用例，测试会直接失败 —— 这就是规则覆盖率 1:1 的强制机制。
enum Fault: String, CaseIterable {
    case fixtureMissingField
    case fixtureUnknownPosition
    case fixtureDuplicateUnit
    case fixtureDuplicateChannel
    case fixtureUnknownType
    case fixtureMissingCoordinate
    case fixtureUnknownGel
    case fixtureMissingBeam
    case fixtureMissingPurpose
    case fixtureAmbiguousMount
    case fixtureOffPosition
    case fixtureOutsideStage
    case positionMissingShape
    case positionMissingTrim
    case positionTrimHigh
    case positionTrimLow
    case positionOutsideStage
    case positionDuplicateID
    case positionCollinearGap
    case gelDuplicateCode
    case gelMissingColor
    case documentInvalidScale
    case documentNonASCII
    case documentEmptyStage
    case documentNoFixtures

    var expected: LintCode {
        guard let code = LintCode(rawValue: rawValue) else {
            fatalError("Fault '\(rawValue)' has no matching LintCode — the two lists drifted apart")
        }
        return code
    }

    var summary: String {
        switch self {
        case .fixtureMissingField:     return "lantern without a channel"
        case .fixtureUnknownPosition:  return "lantern on a non-existent bar"
        case .fixtureDuplicateUnit:    return "two lanterns with the same unit number"
        case .fixtureDuplicateChannel: return "two lanterns on the same channel"
        case .fixtureUnknownType:      return "lantern of an undefined type"
        case .fixtureMissingCoordinate: return "lantern with no coordinate"
        case .fixtureUnknownGel:       return "lantern with an undefined gel"
        case .fixtureMissingBeam:      return "lantern without a beam angle"
        case .fixtureMissingPurpose:   return "lantern without a purpose"
        case .fixtureAmbiguousMount:   return "lantern with both x and y on a bar"
        case .fixtureOffPosition:      return "lantern hanging past the end of its bar"
        case .fixtureOutsideStage:     return "practical outside the stage"
        case .positionMissingShape:    return "bar with a missing end point"
        case .positionMissingTrim:     return "bar without a trim height"
        case .positionTrimHigh:        return "bar trimmed above 12 m"
        case .positionTrimLow:         return "bar trimmed below 1.5 m"
        case .positionOutsideStage:    return "bar beyond the stage depth"
        case .positionDuplicateID:     return "two bars with the same id"
        case .positionCollinearGap:    return "two collinear bars with a gap"
        case .gelDuplicateCode:        return "duplicate gel code"
        case .gelMissingColor:         return "gel without a colour value"
        case .documentInvalidScale:    return "scale of zero"
        case .documentNonASCII:        return "Chinese text on a drawing"
        case .documentEmptyStage:      return "stage with zero width"
        case .documentNoFixtures:      return "document with no lanterns"
        }
    }

    func apply(to doc: inout LXDocument) {
        switch self {
        case .fixtureMissingField:
            doc.fixtures[0].ch = nil

        case .fixtureUnknownPosition:
            doc.fixtures[0].pos = "NOPE"

        case .fixtureDuplicateUnit:
            doc.fixtures[1].unit = doc.fixtures[0].unit

        case .fixtureDuplicateChannel:
            doc.fixtures[1].ch = doc.fixtures[0].ch

        case .fixtureUnknownType:
            doc.fixtures[0].type = "ledbar"

        case .fixtureMissingCoordinate:
            doc.fixtures[0].x = nil

        case .fixtureUnknownGel:
            doc.fixtures[0].gel = "L999"

        case .fixtureMissingBeam:
            doc.fixtures[0].beam = nil

        case .fixtureMissingPurpose:
            doc.fixtures[0].purpose = nil

        case .fixtureAmbiguousMount:
            doc.fixtures[0].y = 2400

        case .fixtureOffPosition:
            doc.fixtures[0].x = 9000            // LX 1 只到 7500

        case .fixtureOutsideStage:
            doc.fixtures[2].x = 60000           // 实物灯摆到台外六十米

        case .positionMissingShape:
            doc.positions[0].x1 = nil

        case .positionMissingTrim:
            doc.positions[0].trim = nil

        case .positionTrimHigh:
            doc.positions[0].trim = 13000

        case .positionTrimLow:
            doc.positions[0].trim = 900

        case .positionOutsideStage:
            doc.positions[0].y = 10000          // 台深 9000

        case .positionDuplicateID:
            doc.positions[1].id = doc.positions[0].id

        case .positionCollinearGap:
            doc.positions[0].x1 = 0
            doc.positions.append(Position(id: "LX 1B", kind: .horizontal, type: .truss,
                                          x0: 100, x1: 7500, y: 2400, trim: 6500))

        case .gelDuplicateCode:
            doc.gels.append(Gel(code: "L201", name: "Lee 201 again", rgb: 0x2E4E8F))

        case .gelMissingColor:
            doc.gels[0].rgb = nil

        case .documentInvalidScale:
            doc.meta.scale = 0

        case .documentNonASCII:
            doc.meta.show = "推销员之死"

        case .documentEmptyStage:
            doc.stage.width = 0

        case .documentNoFixtures:
            doc.fixtures = []
        }
    }
}

@Suite("Fault injection")
struct FaultInjectionTests {

    @Test("The baseline document is clean", arguments: [0])
    func baselineIsClean(_: Int) {
        let doc = TestData.validDocument()
        let issues = Lint.check(doc)
        #expect(issues.isEmpty, "baseline is not clean: \(issues.map { "\($0.code.rawValue) \($0.message)" })")
    }

    @Test("Every injected fault is caught with the right code",
          arguments: Fault.allCases)
    func faultIsCaught(fault: Fault) {
        var doc = TestData.validDocument()
        fault.apply(to: &doc)

        let codes = Set(Lint.check(doc).map(\.code))
        #expect(codes.contains(fault.expected),
                "\(fault.rawValue) (\(fault.summary)) was not caught; got \(codes.map(\.rawValue).sorted())")
    }

    @Test("The baseline stays clean while the fault is applied")
    func faultIsTheOnlyChange() {
        // 每个故障只允许改动它声称要改的东西：
        // 如果注入后连"正常"字段也开始报错，说明规则之间有串扰。
        for fault in Fault.allCases {
            var doc = TestData.validDocument()
            fault.apply(to: &doc)
            let codes = Set(Lint.check(doc).map(\.code))
            for unexpected in codes where unexpected != fault.expected {
                // 允许的伴生问题（同一个故障必然带出的连锁错误）
                #expect(allowedCompanions[fault]?.contains(unexpected) ?? false,
                        "\(fault.rawValue) produced unrelated \(unexpected.rawValue)")
            }
        }
    }

    /// 同一个故障可能必然带出别的错误。这里显式列出，避免"串扰"被悄悄放过。
    private var allowedCompanions: [Fault: Set<LintCode>] {
        [
            // 改 id 后，挂在原 id 上的灯自然找不到构件
            .positionDuplicateID: [.fixtureUnknownPosition],
        ]
    }

    /// **规则覆盖率 = 1:1** —— 这不是代码行覆盖率，而是"每条规则都被证明会响"。
    @Test("Every lint rule has at least one fault that triggers it")
    func everyRuleHasAFault() {
        let covered = Set(Fault.allCases.map(\.expected))
        let uncovered = LintCode.allCases.filter { !covered.contains($0) }
        #expect(uncovered.isEmpty,
                "rules with no fault case: \(uncovered.map(\.rawValue).sorted())")
    }

    @Test("No two faults claim the same rule")
    func faultsAreDistinct() {
        let expected = Fault.allCases.map(\.expected)
        #expect(Set(expected).count == expected.count,
                "duplicate expected codes: \(expected.map(\.rawValue))")
    }

    @Test("Fault codes are all real codes that name their own case")
    func faultNamesMatchCodes() {
        // Fault 的 case 名必须与 LintCode 的 case 名完全一致。
        // 不一致会导致 expected 指向别的规则，覆盖率就是假的。
        for f in Fault.allCases {
            #expect(f.expected.rawValue == f.rawValue,
                    "\(f.rawValue) maps to \(f.expected.rawValue)")
        }
    }
}
