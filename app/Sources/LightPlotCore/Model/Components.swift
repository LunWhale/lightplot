import Foundation

// MARK: - 位置（吊挂构件）

public enum PositionKind: String, Codable, Sendable, CaseIterable {
    /// 水平吊杆（LX 1 / FOH LX）。
    case horizontal = "h"
    /// 竖直 BOOM（舞台两侧的立杆）。
    case vertical = "v"
}

/// 构件类型。三者的画法完全不同，**不要混用**。
public enum PositionType: String, Codable, Sendable, CaseIterable {
    /// 格构桁架：双弦 + 正 M 格构。
    case truss
    /// 空心长条管线（外观是"一根超级长方形"）。
    case pipe
    /// 单线。用于**非吊挂**构件（布景边缘、地面导轨）。
    ///
    /// 用桁架画布景边缘会让人误读成"第四根灯杆" ——
    /// 旧项目就是为此把 SET EDGE 改成 line 的。
    case line

    public var displayName: String {
        switch self {
        case .truss: return "Truss"
        case .pipe:  return "Pipe"
        case .line:  return "Line"
        }
    }
}

/// 位置在文档空间的解析形状。
public enum PositionShape: Equatable, Sendable {
    case horizontal(x0: Double, x1: Double, y: Double)
    case vertical(x: Double, y0: Double, y1: Double)

    public var isHorizontal: Bool {
        if case .horizontal = self { return true }
        return false
    }

    public var start: Vec2 {
        switch self {
        case .horizontal(let x0, _, let y): return Vec2(x0, y)
        case .vertical(let x, let y0, _):   return Vec2(x, y0)
        }
    }

    public var end: Vec2 {
        switch self {
        case .horizontal(_, let x1, let y): return Vec2(x1, y)
        case .vertical(let x, _, let y1):   return Vec2(x, y1)
        }
    }

    public var length: Double { start.distance(to: end) }

    /// 构件中心（灯具/名字的默认基准）。
    public var midpoint: Vec2 { (start + end) * 0.5 }

    /// 沿构件的单位方向。
    public var direction: Vec2 {
        (end - start).normalized ?? Vec2(1, 0)
    }

    public var angleDegrees: Double { direction.angleDegrees }

    /// 把沿构件的标量偏移转成世界点。偏移从 `start` 量起。
    public func point(atOffset offset: Double) -> Vec2 {
        start + direction * offset
    }

    /// 世界点投影回沿构件偏移（夹紧在构件范围内）。
    public func offset(of p: Vec2) -> Double {
        let (t, _) = p.projected(onto: start, end)
        return t * length
    }
}

/// 一根吊挂构件。
public struct Position: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: PositionKind
    public var type: PositionType
    /// 水平构件：端点 x。
    public var x0: Double?
    public var x1: Double?
    /// 水平构件的 y。
    public var y: Double?
    /// 竖直构件的 x。
    public var x: Double?
    /// 竖直构件的端点 y。
    public var y0: Double?
    public var y1: Double?
    /// 吊挂高度（距 ±0，mm）。
    public var trim: Double?

    public init(id: String, kind: PositionKind, type: PositionType,
                x0: Double? = nil, x1: Double? = nil, y: Double? = nil,
                x: Double? = nil, y0: Double? = nil, y1: Double? = nil,
                trim: Double? = nil) {
        self.id = id
        self.kind = kind
        self.type = type
        self.x0 = x0
        self.x1 = x1
        self.y = y
        self.x = x
        self.y0 = y0
        self.y1 = y1
        self.trim = trim
    }

    public var shape: PositionShape? {
        switch kind {
        case .horizontal:
            guard let x0, let x1, let y else { return nil }
            return .horizontal(x0: x0, x1: x1, y: y)
        case .vertical:
            guard let x, let y0, let y1 else { return nil }
            return .vertical(x: x, y0: y0, y1: y1)
        }
    }

    /// 构件在图纸上的半高（mm）。灯号标注的偏移量要用它，
    /// 不能用常量猜 —— 旧项目就是因为"偏移 3.8mm、符号半径 5–7mm"而压字。
    public func halfHeightOnSheet(scale: Double) -> Double {
        switch type {
        case .truss: return Paper.TrussSpec.heightOnSheet(scale: scale) / 2
        case .pipe:  return Paper.PipeSpec.heightOnSheet(scale: scale) / 2
        case .line:  return Paper.lineHalfHeight
        }
    }

    /// 长度（文档 mm）。
    public var length: Double { shape?.length ?? 0 }
}

// MARK: - 灯具

/// 一台灯具。
///
/// **坐标的不对称性是这份数据格式里最容易踩的坑**：
///   · 水平构件上的灯，`x` 是**沿构件的标量偏移**，y 由构件给
///   · 竖直 BOOM 上的灯，`y` 是沿构件的偏移，x 由构件给
///   · 台上实物（practical）与自由摆放的灯，`x`/`y` 都是**世界坐标**
///
/// 这套设计保证了"灯永远不脱杆"，是优点，必须保留。
/// 但编辑器绝不能把桁架上的灯写成同时有 x 和 y —— 那会被解释成自由摆放，
/// 灯就脱离桁架了。见 `Resolver` 与 `Lint` 的 `fixture.ambiguousMount`。
public struct Fixture: Codable, Equatable, Sendable, Identifiable {
    /// 灯号。必须唯一。
    public var unit: Int
    /// 挂在哪根构件上。自由摆放的实物也保留这个字段用于分组。
    public var pos: String?
    /// 沿水平构件的偏移（或自由摆放的 x）。
    public var x: Double?
    /// 沿竖直构件的偏移（或自由摆放的 y）。
    public var y: Double?
    /// 灯具类型键（`types` 的 key）。
    public var type: String
    /// 出光方向（度）。0 = +X，90 = +Y（朝后墙），180 = -X，270 = -Y。
    public var aim: Double?
    /// 色片号。必须存在于 `gels`，或为 `OPEN`。
    public var gel: String?
    /// 调光通道。
    public var ch: Int?
    /// 照哪里。每盏灯都应有。
    public var purpose: String?
    /// 光束角（度）。剖面图与光束锥要用。
    public var beam: Double?
    /// 仅台上实物：安装高度（距 ±0）。
    public var trim: Double?
    /// **剖面图专用**：这盏灯在纵深方向上的焦点位置（mm）。
    ///
    /// 缺省时按它的位置推断（FOH 打近区、LX1 打近中、LX2 打中区、LX3 打后区）。
    /// 提供这个字段，是因为"一排 6 盏灯全部打舞台中区"会让剖面图上的
    /// 光束叠成一团黑 —— 而真实设计中每盏灯的焦点本来就不同。
    public var focusDepth: Double?

    public var id: Int { unit }

    public init(unit: Int, pos: String? = nil, x: Double? = nil, y: Double? = nil,
                type: String, aim: Double? = 90, gel: String? = nil, ch: Int? = nil,
                purpose: String? = nil, beam: Double? = nil, trim: Double? = nil,
                focusDepth: Double? = nil) {
        self.unit = unit
        self.pos = pos
        self.x = x
        self.y = y
        self.type = type
        self.aim = aim
        self.gel = gel
        self.ch = ch
        self.purpose = purpose
        self.beam = beam
        self.trim = trim
    }

    /// 出光方向向量。缺 `aim` 时默认朝后墙（90°），与 FOH 面光的实际意图一致。
    public var aimVector: Vec2 { Vec2(angleDegrees: aim ?? 90) }

    /// 是否自由摆放（不锁在构件轴线上）。
    ///
    /// **只有实物灯是自由摆放的。** 这条规则必须严格，不能"同时给了 x 和 y 就算自由" ——
    /// 那样一个手滑就会把桁架上的灯变成自由摆放，它立刻脱杆，
    /// 而图上只差几毫米，肉眼看不出来。
    ///
    /// 旧数据里 SET EDGE 上的两盏台灯都是 `type: practical`，所以不需要兼容分支。
    /// 如果将来出现"非实物灯却两个坐标都给"的数据，`Lint` 会报
    /// `fixture.ambiguousMount`，让用户明确修正，而不是静默猜。
    /// 图上/表上要显示的色片号。
    ///
    /// **`nil` 与 `"OPEN"` 是同一件事：没装色片。**
    /// 早先各处各自处理默认值 —— 平面图上画成 `-`、CSV 里是空串、
    /// 图例却列 `OPEN`。同一份数据在三个地方说三种话，
    /// 读图的人只能猜。这里统一成一个入口。
    public var gelCode: String {
        guard let g = gel?.trimmingCharacters(in: .whitespaces), !g.isEmpty else {
            return "OPEN"
        }
        return g
    }

    public var isFreeMounted: Bool { type == "practical" }

    /// 是否歧义摆放：挂在构件上，却同时给了 x 与 y。
    ///
    /// 这是编辑器必须拦截的状态 —— 一旦写进文件，读回来时
    /// "到底听 x 还是听 y" 就变成隐含约定，两份代码各自猜一次就漂移了。
    public var isAmbiguousMount: Bool {
        type != "practical" && x != nil && y != nil
    }
}

// MARK: - 色片

public struct Gel: Codable, Equatable, Sendable, Identifiable {
    /// LEE / Rosco 色号，或 `OPEN`。
    public var code: String
    public var name: String
    public var purpose: String
    /// 真实颜色（sRGB，24 位）。0 = 未知（`OPEN` 与未收录的色号）。
    ///
    /// 旧数据里没有这个字段，所以是 optional —— 加载旧文档时色片只能显示为空心，
    /// 这是**故意可见的缺口**，不是 bug。补全色库后会自动填上。
    public var rgb: UInt32?

    public var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code = "gel"
        case name, purpose, rgb
    }

    public init(code: String, name: String, purpose: String = "", rgb: UInt32? = nil) {
        self.code = code
        self.name = name
        self.purpose = purpose
        self.rgb = rgb
    }

    /// 容错解码：只有色号是必需的。
    ///
    /// 合成的解码器要求 `name` 与 `purpose` 都存在 —— 但它们只是
    /// **描述**，不影响出图。手写 YAML 的人（尤其是初学者）不该因为
    /// 少写一句 `purpose` 就得到 `keyNotFound`。
    ///
    /// ## 边界：只容忍缺失，**不发明数据**
    ///
    /// 早先这里顺手从内建色库补了 `rgb`，结果解码会**改动文档**，
    /// 破坏了"读进来再写出去必须一模一样"这条不变量
    /// （三条往返测试立刻抓到）。
    /// 补颜色是**独立的、显式的一步**（`GelLibrary.fillMissingColours`），
    /// 不属于解码。
    ///
    /// 缺 `name` 时退回色号本身：这是中性占位，不是猜测。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let code = try c.decode(String.self, forKey: .code)
        self.code = code
        if let n = try c.decodeIfPresent(String.self, forKey: .name),
           !n.trimmingCharacters(in: .whitespaces).isEmpty {
            self.name = n
        } else {
            self.name = code
        }
        self.purpose = (try c.decodeIfPresent(String.self, forKey: .purpose)) ?? ""
        self.rgb = try c.decodeIfPresent(UInt32.self, forKey: .rgb)
    }
}

// MARK: - 灯具类型

public struct FixtureType: Codable, Equatable, Sendable {
    public var label: String
    public var watt: Double?
    public var role: String?

    public init(label: String, watt: Double? = nil, role: String? = nil) {
        self.label = label
        self.watt = watt
        self.role = role
    }
}

// MARK: - 光区

public struct Zone: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(id: String, x0: Double, y0: Double, x1: Double, y1: Double) {
        self.id = id
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    public var rect: Rect { Rect(x0: x0, y0: y0, x1: x1, y1: y1) }
    public var center: Vec2 { rect.center }
}

// MARK: - 布景构件

public enum SetPieceKind: String, Codable, Sendable, CaseIterable {
    case line, rect, stair
}

/// 布景构件。
///
/// 坐标是**擦净的**：矩形用对角两点，楼梯用外接矩形 + 级数。
/// 楼梯的几何必须真实 —— 旧项目曾把 12 级楼梯画成 900mm 进深
/// （每级 75mm），那不是楼梯是梯子。
public struct SetPiece: Codable, Equatable, Sendable, Identifiable {
    public var kind: SetPieceKind
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double
    public var label: String?
    public var dashed: Bool?
    public var steps: Int?
    /// 构件高度（mm）。**剖面图必需** —— 平面图不需要，所以是可选的。
    /// 缺省时由 `LXDocument.sectionHeight(of:)` 按类型给保守值。
    public var height: Double?

    public var id: String { "\(kind.rawValue)-\(x0)-\(y0)-\(x1)-\(y1)-\(label ?? "")" }

    public init(kind: SetPieceKind, x0: Double, y0: Double, x1: Double, y1: Double,
                label: String? = nil, dashed: Bool? = nil, steps: Int? = nil,
                height: Double? = nil) {
        self.kind = kind
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
        self.label = label
        self.dashed = dashed
        self.steps = steps
        self.height = height
    }

    public var rect: Rect { Rect(x0: x0, y0: y0, x1: x1, y1: y1) }

    /// 踏步进深（文档 mm）。楼梯是竖向剖面里的东西，平面图只画踏步线。
    public var treadDepth: Double {
        guard kind == .stair, let steps, steps > 0 else { return 0 }
        return rect.height / Double(steps)
    }
}
