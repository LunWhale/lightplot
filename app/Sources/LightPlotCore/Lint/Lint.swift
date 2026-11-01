import Foundation

// MARK: - 严重度

public enum LintSeverity: String, Sendable, Codable, CaseIterable, Comparable {
    case info, warning, error

    public var rank: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    public static func < (a: LintSeverity, b: LintSeverity) -> Bool { a.rank < b.rank }
}

// MARK: - 错误码

/// 所有可机检的问题都必须是**稳定错误码**，不是字符串。
///
/// 理由：故障注入测试要断言"注入了 10 号故障，必须出现 `fixtureReversed`"。
/// 如果只有人类可读的消息，测试只能做子串匹配，改一个字就全崩。
public enum LintCode: String, Sendable, Codable, CaseIterable {
    // 灯具
    case fixtureMissingField          // 必填字段（unit/pos/type/gel/ch）缺失
    case fixtureUnknownPosition       // pos 指向不存在的构件
    case fixtureDuplicateUnit         // 灯号重复
    case fixtureDuplicateChannel      // 通道冲突
    case fixtureUnknownType           // 未定义的灯具类型
    case fixtureMissingCoordinate     // 缺坐标
    case fixtureUnknownGel            // 未定义的色片
    case fixtureMissingBeam           // 缺光束角（剖面图无法画）
    case fixtureMissingPurpose        // 缺 purpose —— 每盏灯都应说明照哪里
    case fixtureAmbiguousMount        // 构件上的灯同时有 x 与 y（会被误读为自由摆放）
    case fixtureOffPosition            // 灯落在构件长度之外
    case fixtureOutsideStage          // 灯具落在舞台范围外
    // 构件
    case positionMissingShape         // 缺端点坐标
    case positionMissingTrim          // 缺吊挂高度
    case positionTrimHigh             // trim 高于栅顶，请确认
    case positionTrimLow              // trim 过低，请确认
    case positionOutsideStage         // 构件在台深之外
    case positionDuplicateID          // 构件 id 重复
    case positionCollinearGap         // 两根共线构件之间有缝，可以合并
    // 色片
    case gelDuplicateCode             // 色号重复
    case gelMissingColor              // 缺真实颜色（只影响显示，不影响出图）
    // 文档
    case documentInvalidScale         // 比例非法
    case documentNonASCII             // 图上文字含非 ASCII 字符
    case documentEmptyStage           // 舞台尺寸为零
    case documentNoFixtures           // 一盏灯都没有

    /// 默认严重度。
    public var defaultSeverity: LintSeverity {
        switch self {
        case .fixtureMissingBeam, .fixtureMissingPurpose, .fixtureOutsideStage,
             .positionTrimHigh, .positionTrimLow, .gelMissingColor,
             .positionCollinearGap, .documentNoFixtures:
            return .warning
        case .gelDuplicateCode:
            return .error
        default:
            return .error
        }
    }

    /// 一句话说明（英文，会出现在导出报告里）。
    public var title: String {
        switch self {
        case .fixtureMissingField:      return "Fixture is missing a required field"
        case .fixtureUnknownPosition:   return "Fixture is attached to an unknown position"
        case .fixtureDuplicateUnit:     return "Duplicate unit number"
        case .fixtureDuplicateChannel:  return "Channel is already used"
        case .fixtureUnknownType:       return "Unknown fixture type"
        case .fixtureMissingCoordinate: return "Fixture has no coordinate"
        case .fixtureUnknownGel:        return "Unknown gel"
        case .fixtureMissingBeam:       return "Fixture has no beam angle"
        case .fixtureMissingPurpose:    return "Fixture has no purpose"
        case .fixtureAmbiguousMount:    return "Fixture on a position has both x and y"
        case .fixtureOffPosition:       return "Fixture hangs beyond the end of its position"
        case .fixtureOutsideStage:      return "Fixture is outside the stage"
        case .positionMissingShape:     return "Position has no end points"
        case .positionMissingTrim:      return "Position has no trim height"
        case .positionTrimHigh:         return "Trim is unusually high"
        case .positionTrimLow:          return "Trim is unusually low"
        case .positionOutsideStage:     return "Position is beyond the stage depth"
        case .positionDuplicateID:      return "Duplicate position id"
        case .positionCollinearGap:     return "Collinear positions could be joined"
        case .gelDuplicateCode:         return "Duplicate gel code"
        case .gelMissingColor:          return "Gel has no colour value"
        case .documentInvalidScale:     return "Invalid scale"
        case .documentNonASCII:         return "Non-ASCII character on a drawing"
        case .documentEmptyStage:       return "Stage has no size"
        case .documentNoFixtures:       return "Document has no fixtures"
        }
    }
}

// MARK: - 问题

public struct LintIssue: Equatable, Sendable, Identifiable {
    public let code: LintCode
    public let severity: LintSeverity
    /// 人类可读的具体描述（含数值）。
    public let message: String
    /// 出问题的对象标识（"fixture 101" / "position LX 1" / "gel L201"）。
    public let subject: String

    public var id: String { "\(code.rawValue)|\(subject)|\(message)" }

    public init(code: LintCode, severity: LintSeverity? = nil,
                subject: String, message: String) {
        self.code = code
        self.severity = severity ?? code.defaultSeverity
        self.message = message
        self.subject = subject
    }
}

// MARK: - 校验

/// 数据校验 —— 旧 `qc.py` 的移植，加上编辑器需要的新规则。
///
/// **与旧版的区别**：不抛异常、不中断。返回带错误码的问题列表，
/// 由 UI 面板展示。这样"拖到一半"的文档也能实时提示，而不是拒绝服务。
///
/// 所有规则都必须有一条对应的故障注入用例
/// （`FaultInjectionTests`）。没有用例的规则等于装饰品。
public enum Lint {

    /// 必填字段（与旧 qc 一致）。
    static let requiredFixtureFields = ["pos", "type", "gel", "ch"]

    public static func check(_ doc: LXDocument) -> [LintIssue] {
        var issues: [LintIssue] = []
        issues += checkDocument(doc)
        issues += checkPositions(doc)
        issues += checkFixtures(doc)
        issues += checkGels(doc)
        issues += checkCollinearPositions(doc)

        // 稳定排序：严重度高的在前；同severity 按 code、subject、message 排。
        return issues.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if a.code.rawValue != b.code.rawValue { return a.code.rawValue < b.code.rawValue }
            if a.subject != b.subject { return a.subject < b.subject }
            return a.message < b.message
        }
    }

    public static func hasErrors(_ doc: LXDocument) -> Bool {
        check(doc).contains { $0.severity == .error }
    }

    // MARK: 文档

    static func checkDocument(_ doc: LXDocument) -> [LintIssue] {
        var out: [LintIssue] = []

        if !(doc.meta.scale.isFinite && doc.meta.scale >= 1) {
            out.append(.init(code: .documentInvalidScale, subject: "document",
                             message: "scale 1:\(doc.meta.scale) is not a positive number"))
        }
        if doc.stage.width <= 0 || doc.stage.depth <= 0 {
            out.append(.init(code: .documentEmptyStage, subject: "stage",
                             message: "stage \(doc.stage.width) x \(doc.stage.depth) mm"))
        }
        if doc.fixtures.isEmpty {
            out.append(.init(code: .documentNoFixtures, subject: "document",
                             message: "no fixtures in document"))
        }

        // 图上不许出现非 ASCII。这是硬约束：DXF 只能纯 ASCII，
        // 中文会触发 \U+ 转义，Vectorworks 不保证支持。
        // 在 iPad 上用户会自然输入中文，所以必须在编辑时就拦住。
        for text in allDrawingStrings(doc) {
            if let bad = firstNonASCII(text.value) {
                out.append(.init(code: .documentNonASCII, subject: text.owner,
                                 message: "'\(text.value)' contains U+\(hex(bad)) at \(text.field)"))
            }
        }
        return out
    }

    // MARK: 构件

    static func checkPositions(_ doc: LXDocument) -> [LintIssue] {
        var out: [LintIssue] = []
        var seen: [String: Int] = [:]

        for p in doc.positions {
            let subject = "position \(p.id)"
            seen[p.id, default: 0] += 1
            if seen[p.id]! > 1 {
                out.append(.init(code: .positionDuplicateID, subject: subject,
                                 message: "id '\(p.id)' used \(seen[p.id]!) times"))
            }
            if p.shape == nil {
                out.append(.init(code: .positionMissingShape, subject: subject,
                                 message: "kind=\(p.kind.rawValue) needs \(p.kind == .horizontal ? "x0/x1/y" : "x/y0/y1")"))
            }

            // trim 合理性只查吊挂构件。
            // line 是非吊挂的地面/布景线（SET EDGE 在 ±0 上），trim=0 是对的。
            // 旧项目不区分类型，每次运行都报一条假警告 ——
            // 假警告比漏报更危险，它会训练人忽略所有警告。
            if p.type != .line {
                if let trim = p.trim {
                    if trim > 12000 {
                        out.append(.init(code: .positionTrimHigh, subject: subject,
                                         message: "trim \(Int(trim))mm is above 12000mm"))
                    } else if trim < 1500 {
                        // 注意：trim == 0 必须报。
                        // 曾经这里写成 `trim < 1500 && trim > 0`，结果"桁架吊到地面"
                        // 这个最危险的错法反而被跳过了 —— 故障注入测试抓住了它。
                        out.append(.init(code: .positionTrimLow, subject: subject,
                                         message: "trim \(Int(trim))mm is below 1500mm"))
                    }
                } else {
                    out.append(.init(code: .positionMissingTrim, subject: subject,
                                     message: "no trim height"))
                }
            }

            if let shape = p.shape, case .horizontal(_, _, let y) = shape {
                if y > doc.stage.depth + 200 {
                    out.append(.init(code: .positionOutsideStage, subject: subject,
                                     message: "y=\(Int(y))mm beyond stage depth \(Int(doc.stage.depth))mm"))
                }
            }
        }
        return out
    }

    // MARK: 灯具

    static func checkFixtures(_ doc: LXDocument) -> [LintIssue] {
        var out: [LintIssue] = []
        var units: [Int: Int] = [:]
        var channels: [Int: Int] = [:]
        let gelCodes = Set(doc.gels.map(\.code))

        for f in doc.fixtures.sorted(by: { $0.unit < $1.unit }) {
            let subject = "fixture \(f.unit)"

            units[f.unit, default: 0] += 1
            if units[f.unit]! > 1 {
                out.append(.init(code: .fixtureDuplicateUnit, subject: subject,
                                 message: "unit \(f.unit) appears \(units[f.unit]!) times"))
            }

            // 必填字段。
            //
            // `pos` 对**自由摆放的实物灯**不是必填 —— 台灯就放在台上，
            // 不属于任何吊挂构件。早先把它当必填，导致新加的 every 实物灯
            // 都报一条假错。假错误比漏报更危险：它会训练人忽略所有错误。
            if !f.isFreeMounted {
                if f.pos?.isEmpty ?? true {
                    out.append(.init(code: .fixtureMissingField, subject: subject,
                                     message: "missing pos"))
                }
            }
            if f.type.isEmpty {
                out.append(.init(code: .fixtureMissingField, subject: subject, message: "missing type"))
            }
            if f.gel?.isEmpty ?? true {
                out.append(.init(code: .fixtureMissingField, subject: subject, message: "missing gel"))
            }
            if f.ch == nil {
                out.append(.init(code: .fixtureMissingField, subject: subject, message: "missing ch"))
            }

            // 类型
            if !f.type.isEmpty && doc.types[f.type] == nil {
                out.append(.init(code: .fixtureUnknownType, subject: subject,
                                 message: "type '\(f.type)' not in types"))
            }

            // 色片
            if let gel = f.gel, !gel.isEmpty, !gelCodes.contains(gel) {
                out.append(.init(code: .fixtureUnknownGel, subject: subject,
                                 message: "gel '\(gel)' not in gels"))
            }

            // 通道
            if let ch = f.ch {
                if let other = channels[ch] {
                    out.append(.init(code: .fixtureDuplicateChannel, subject: subject,
                                     message: "ch \(ch) already used by unit \(other)"))
                } else {
                    channels[ch] = f.unit
                }
            }

            // 光束角
            if f.beam == nil {
                out.append(.init(code: .fixtureMissingBeam, subject: subject,
                                 message: "no beam angle"))
            }

            // purpose —— 每盏灯都应说明照哪里（否则读图人无法判断设计意图）
            if f.purpose?.isEmpty ?? true {
                out.append(.init(code: .fixtureMissingPurpose, subject: subject,
                                 message: "no purpose (every lantern should state what it lights)"))
            }

            // 挂载解析
            switch Resolver.mount(of: f, in: doc) {
            case .unresolved(let code):
                out.append(.init(code: code, subject: subject,
                                 message: unresolvedDetail(code, f)))
            case .free(let p):
                if !doc.stageBounds.inset(by: -2000).contains(p) {
                    out.append(.init(code: .fixtureOutsideStage, subject: subject,
                                     message: String(format: "at %.0f,%.0f mm", p.x, p.y)))
                }
            case .onPosition:
                // 灯挂在杆外：图上会按实际坐标画出来，但数据是错的。
                // 刻意**不做夹紧** —— 悄悄夹紧会让图与数据不一致，比报错更危险。
                if !Resolver.isOnPosition(Resolver.mount(of: f, in: doc)) {
                    out.append(.init(code: .fixtureOffPosition, subject: subject,
                                     message: "axis value is outside the position length"))
                }
                // 构件上的灯必须只给沿轴的标量。
                // 同时给 x 和 y 会被解释成自由摆放 —— 灯就悄悄脱杆了。
                if f.isAmbiguousMount {
                    out.append(.init(code: .fixtureAmbiguousMount, subject: subject,
                                     message: "on '\(f.pos ?? "?")' but has both x and y"))
                }
            }
        }
        return out
    }

    static func unresolvedDetail(_ code: LintCode, _ f: Fixture) -> String {
        switch code {
        case .fixtureUnknownPosition:
            return "pos '\(f.pos ?? "")' not found"
        case .fixtureMissingCoordinate:
            return "needs \(f.isFreeMounted ? "x and y" : "a coordinate along its position")"
        case .positionMissingShape:
            return "position '\(f.pos ?? "")' has no end points"
        default:
            return code.title
        }
    }

    // MARK: 色片

    static func checkGels(_ doc: LXDocument) -> [LintIssue] {
        var out: [LintIssue] = []
        var seen: [String: Int] = [:]
        for g in doc.gels {
            seen[g.code, default: 0] += 1
            if seen[g.code]! > 1 {
                out.append(.init(code: .gelDuplicateCode, subject: "gel \(g.code)",
                                 message: "code '\(g.code)' used \(seen[g.code]!) times"))
            }
            if g.code != "OPEN" && g.rgb == nil {
                out.append(.init(code: .gelMissingColor, subject: "gel \(g.code)",
                                 message: "no colour value; swatch will render as an outline"))
            }
        }
        return out
    }

    // MARK: 共线可合并的构件

    /// 两根共线、端点相接或只差一点点的构件，应该合并成一根。
    ///
    /// 这是"拖拽合并"操作的校验对照：编辑器里用户手动合并，
    /// 这里负责发现**忘了合并**的情况。
    static func checkCollinearPositions(_ doc: LXDocument) -> [LintIssue] {
        var out: [LintIssue] = []
        let shapes = doc.positions.compactMap { p -> (Position, PositionShape)? in
            guard let s = p.shape else { return nil }
            return (p, s)
        }
        for i in 0..<shapes.count {
            for j in (i + 1)..<shapes.count {
                let (pa, sa) = shapes[i]
                let (pb, sb) = shapes[j]
                guard let gap = collinearGap(sa, sb) else { continue }
                let tol = 120.0    // 文档 mm：1.2cm 以内的缝视为"应该合并"
                if gap > 0 && gap <= tol {
                    out.append(.init(code: .positionCollinearGap,
                                     subject: "positions \(pa.id) / \(pb.id)",
                                     message: String(format: "%.0f mm gap on the same axis", gap)))
                }
            }
        }
        return out
    }

    /// 两根构件共线时返回它们之间的间隙（负值表示重叠）。
    /// 不共线返回 nil。
    static func collinearGap(_ a: PositionShape, _ b: PositionShape) -> Double? {
        if case .horizontal(let ax0, let ax1, let ay) = a,
           case .horizontal(let bx0, let bx1, let by) = b {
            guard abs(ay - by) < 1.0 else { return nil }
            let lo = max(min(ax0, ax1), min(bx0, bx1))
            let hi = min(max(ax0, ax1), max(bx0, bx1))
            return lo - hi
        }
        if case .vertical(let ax, let ay0, let ay1) = a,
           case .vertical(let bx, let by0, let by1) = b {
            guard abs(ax - bx) < 1.0 else { return nil }
            let lo = max(min(ay0, ay1), min(by0, by1))
            let hi = min(max(ay0, ay1), max(by0, by1))
            return lo - hi
        }
        return nil
    }

    // MARK: 辅助

    struct DrawingString {
        let value: String
        let owner: String
        let field: String
    }

    /// 所有会**画在图上**的文字。注释类不在此列（它们不进图）。
    static func allDrawingStrings(_ doc: LXDocument) -> [DrawingString] {
        var out: [DrawingString] = []
        out.append(.init(value: doc.meta.show, owner: "meta", field: "show"))
        out.append(.init(value: doc.meta.playwright, owner: "meta", field: "playwright"))
        out.append(.init(value: doc.meta.venue, owner: "meta", field: "venue"))
        out.append(.init(value: doc.meta.sheetTitle, owner: "meta", field: "sheet_title"))
        out.append(.init(value: doc.meta.director, owner: "meta", field: "director"))
        out.append(.init(value: doc.meta.designer, owner: "meta", field: "designer"))
        out.append(.init(value: doc.meta.revision, owner: "meta", field: "revision"))
        out.append(.init(value: doc.meta.revNote, owner: "meta", field: "rev_note"))
        for p in doc.positions { out.append(.init(value: p.id, owner: "position \(p.id)", field: "id")) }
        for z in doc.zones { out.append(.init(value: z.id, owner: "zone \(z.id)", field: "id")) }
        for s in doc.setPieces {
            if let label = s.label, !label.isEmpty {
                out.append(.init(value: label, owner: "set piece", field: "label"))
            }
        }
        for f in doc.fixtures {
            if let purpose = f.purpose, !purpose.isEmpty {
                out.append(.init(value: purpose, owner: "fixture \(f.unit)", field: "purpose"))
            }
        }
        for g in doc.gels { out.append(.init(value: g.name, owner: "gel \(g.code)", field: "name")) }
        for (key, t) in doc.types.sorted(by: { $0.key < $1.key }) {
            out.append(.init(value: t.label, owner: "type \(key)", field: "label"))
        }
        return out
    }

    static func firstNonASCII(_ s: String) -> UInt32? {
        for scalar in s.unicodeScalars where scalar.value > 0x7E || (scalar.value < 0x20 && scalar.value != 0x09) {
            return scalar.value
        }
        return nil
    }

    static func hex(_ v: UInt32) -> String { String(v, radix: 16, uppercase: true) }
}
