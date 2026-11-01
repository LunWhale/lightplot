import Foundation

/// 纸张朝向。
public enum PaperOrientation: String, Codable, Sendable, CaseIterable {
    case landscape
    case portrait

    public var title: String {
        switch self {
        case .landscape: return "Landscape"
        case .portrait:  return "Portrait"
        }
    }
}

/// 图纸尺寸（纸张毫米）。
///
/// 存的是**实际宽高**，所以横向与纵向只是把两者对调 ——
/// 这样渲染、比例尺、图框全都不用关心朝向，
/// 只有"选尺寸"这一层需要知道它是 A1 还是 A1 直放。
public struct PaperSize: Hashable, Sendable, Codable {
    public var widthMM: Double
    public var heightMM: Double

    public init(widthMM: Double, heightMM: Double) {
        self.widthMM = widthMM
        self.heightMM = heightMM
    }

    /// 由标准幅面 + 朝向构造。
    public init(standard: PaperStandard, orientation: PaperOrientation) {
        switch orientation {
        case .landscape:
            self.init(widthMM: standard.longMM, heightMM: standard.shortMM)
        case .portrait:
            self.init(widthMM: standard.shortMM, heightMM: standard.longMM)
        }
    }

    /// 标准幅面（横向宽高）。ISO 216 + 北美常用。
    public enum PaperStandard: String, Codable, Sendable, CaseIterable {
        case a0, a1, a2, a3, a4
        case letter, tabloid

        /// 横向：长边 × 短边。
        public var longMM: Double {
            switch self {
            case .a0: return 1189
            case .a1: return 841
            case .a2: return 594
            case .a3: return 420
            case .a4: return 297
            case .tabloid: return 431.8   // 17 in
            case .letter:  return 279.4   // 11 in
            }
        }
        public var shortMM: Double {
            switch self {
            case .a0: return 841
            case .a1: return 594
            case .a2: return 420
            case .a3: return 297
            case .a4: return 210
            case .tabloid: return 279.4   // 11 in
            case .letter:  return 215.9   // 8.5 in
            }
        }
        public var name: String {
            switch self {
            case .a0: return "A0"
            case .a1: return "A1"
            case .a2: return "A2"
            case .a3: return "A3"
            case .a4: return "A4"
            case .letter:  return "Letter"
            case .tabloid: return "Tabloid"
            }
        }
        /// 舞台图纸的常见程度（用于下拉排序）。
        public var isTheatreStandard: Bool {
            switch self {
            case .a0, .a1, .a2, .a3: return true
            default: return false
            }
        }
    }

    /// A0 横向 —— 大场地（25 m 以内 @1:25）。
    public static let a0 = PaperSize(widthMM: 1189, heightMM: 841)
    /// A1 横向 —— 平面图的标准图幅（16 m 以内 @1:25）。
    public static let a1 = PaperSize(widthMM: 841, heightMM: 594)
    /// A2 横向 —— 小场地或 1:50。
    public static let a2 = PaperSize(widthMM: 594, heightMM: 420)
    /// A3 横向 —— 剖面图 / 辅助图。
    public static let a3 = PaperSize(widthMM: 420, heightMM: 297)

    /// 幅面名（不含朝向）。自定义尺寸返回 "WxH"。
    public var name: String {
        if let std = standard { return std.name }
        return String(format: "%.0fx%.0f", widthMM, heightMM)
    }

    /// 反查标准幅面（无论横放竖放都能认出来）。
    public var standard: PaperStandard? {
        PaperStandard.allCases.first { s in
            (abs(widthMM - s.longMM) < 0.6 && abs(heightMM - s.shortMM) < 0.6)
                || (abs(widthMM - s.shortMM) < 0.6 && abs(heightMM - s.longMM) < 0.6)
        }
    }

    public var orientation: PaperOrientation {
        widthMM >= heightMM ? .landscape : .portrait
    }

    /// "A1 横向" 这样的完整描述。
    public var displayName: String {
        guard standard != nil else { return name }
        return "\(name)  \(orientation.title.lowercased())"
    }

    /// 同一幅面换朝向。
    public func rotated() -> PaperSize {
        PaperSize(widthMM: heightMM, heightMM: widthMM)
    }

    public static let all: [PaperSize] = PaperStandard.allCases.flatMap { s in
        [PaperSize(standard: s, orientation: .landscape),
         PaperSize(standard: s, orientation: .portrait)]
    }

    /// 舞台图纸常用的一组（横向），用于下拉的快捷项。
    public static let theatreSet: [PaperSize] = [.a0, .a1, .a2, .a3]

    public var size: Vec2 { Vec2(widthMM, heightMM) }
}

/// 图纸视觉语法常量 —— **单一定义来源**。
///
/// 这些数字全部是从参考图（NIDA《EX MACHINA》A1）的 PDF 矢量路径里量出来的，
/// 不是估的。原始测量见旧项目的 `docs/07-drafting-language.md`。
///
/// 改这里之前先明白代价：任何一处改动都会让黄金图回归失效，
/// 而"看起来更好"不是理由 —— 参考图是行业标准件。
public enum Paper {

    // MARK: - 单位换算

    /// cap / em 的兜底值（Arial 实测 1467/2048）。
    ///
    /// 真实值在运行期由 `TextMetrics` 从**内置字体**的表里读（见 TextMetrics.swift），
    /// 因为 iOS 与 macOS 的系统字体不同，硬编码会让 iPad 上的字高悄悄变。
    /// 这个常量只在字体加载失败时使用。
    public static let emToCapFallback: Double = 0.7163

    /// 1 pt = 25.4/72 mm。PDF 与 CoreGraphics 都用 pt，图纸用 mm。
    public static let mmPerPoint: Double = 25.4 / 72.0
    public static let pointsPerMM: Double = 72.0 / 25.4

    // MARK: - 线宽

    /// 线宽档位。参考图实测动态范围 28:1（0.025 → 0.713 mm）。
    ///
    /// `mm` 是设计意图（PDF / 画布用这个）；
    /// `dxfValue` 是吸附到 DXF 枚举后的值（导出 DXF 时用）。
    /// 两者必须成对维护：只改 `mm` 而不改 `dxfValue`，DXF 会静默变粗或变细。
    public enum LineWeight: String, CaseIterable, Sendable {
        case hair, truss, fine, thin, med, object, symbol, heavy, frame

        public var mm: Double {
            switch self {
            case .hair:   return 0.025
            case .truss:  return 0.049
            case .fine:   return 0.085
            case .thin:   return 0.127
            case .med:    return 0.152
            case .object: return 0.176
            case .symbol: return 0.254
            case .heavy:  return 0.350
            case .frame:  return 0.713
            }
        }

        /// DXF 规范只接受固定的一组线宽（单位 1/100 mm）。
        /// 任意浮点值会抛 DXFValueError，所以导出时必须吸附。
        public var dxfValue: Int {
            let allowed = [0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70,
                           80, 90, 100, 106, 120, 140, 158, 200, 211]
            let target = mm * 100
            return allowed.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }) ?? 25
        }
    }

    // MARK: - 字号（cap 高度，图纸 mm）

    /// 文字档位。
    ///
    /// **单位陷阱**：这张表是 **cap 高度（mm）**，不是 em。
    /// PDF/Canvas 的 `fontSize` 是 em，写入前必须 `cap / capToEm`。
    /// 反过来的错误（把 em 当 cap）会让全图文字放大 1.4 倍 ——
    /// 这就是旧项目里"雷霆大文字"的根因。
    public enum FontSize: String, CaseIterable, Sendable {
        case sheetNo, show, sheetTotal
        case zone, component, position, border
        case subtitle, field, tbLabel
        case legendHeader, device, note, dim
        case unit, color, micro

        public var capMM: Double {
            switch self {
            case .sheetNo:      return 10.63
            case .show:         return 8.19
            case .sheetTotal:   return 8.22
            case .zone:         return 6.35
            case .component:    return 6.35
            case .position:     return 6.09
            case .border:       return 4.55
            case .subtitle:     return 4.09
            case .field:        return 3.70
            case .tbLabel:      return 3.70
            case .legendHeader: return 3.51
            case .device:       return 3.04
            case .note:         return 3.04
            case .dim:          return 3.03
            case .unit:         return 2.51
            case .color:        return 2.24
            case .micro:        return 1.80
            }
        }
    }

    // MARK: - 颜色

    /// 参考图只有黑色：1934 条黑路径、0 条彩色路径。
    /// 层级完全靠线宽与字号表达，不靠颜色。
    public enum ACI {
        public static let black = 250   // 深灰黑，比纯黑柔和（参考图实测纯黑）
        public static let grey = 8      // 仅辅助信息（尺寸、光区），且要极少量
        public static let white = 7     // 仅用于图层定义（图层色随背景翻转）
    }

    /// 24 位真彩白。
    ///
    /// **必须用真彩，不能用 ACI 7。** ACI 7 在 CAD 里"随背景翻转"：
    /// 白底 CAD 上会渲染成黑色 —— 旧项目因此得到过一张全黑的图。
    /// true_color 需要 DXF R2004+，所以导出档位固定 R2004。
    public static let whiteRGB: UInt32 = 0xFFFFFF
    public static let blackRGB: UInt32 = 0x000000

    // MARK: - 图框

    /// 外框贴纸边：(0,0)-(841,594)。
    public static let frameMargin: Double = 0.0
    /// 内框：(20,20)-(821,574)。
    public static let frameInner: Double = 20.0

    // MARK: - 图层

    public struct LayerSpec: Hashable, Sendable {
        public let name: String
        public let aci: Int
        public let lineType: String
        public let weight: LineWeight
    }

    /// 图层表。顺序即 DXF 表顺序，不要随意重排（Vectorworks 会按此顺序显示）。
    public static let layers: [LayerSpec] = [
        .init(name: "BORDER",       aci: ACI.black, lineType: "Continuous", weight: .frame),
        .init(name: "GRID",         aci: ACI.black, lineType: "Continuous", weight: .hair),
        .init(name: "GRIDTEXT",     aci: ACI.black, lineType: "Continuous", weight: .thin),
        .init(name: "STAGE",        aci: ACI.black, lineType: "Continuous", weight: .heavy),
        .init(name: "SET",          aci: ACI.black, lineType: "Continuous", weight: .med),
        .init(name: "SET_DASH",     aci: ACI.grey,  lineType: "DASHED",     weight: .truss),
        .init(name: "SET_FILL",     aci: ACI.white, lineType: "Continuous", weight: .hair),
        .init(name: "TRUSS",        aci: ACI.black, lineType: "Continuous", weight: .truss),
        .init(name: "TRUSS_FILL",   aci: ACI.white, lineType: "Continuous", weight: .hair),
        .init(name: "PIPE",         aci: ACI.black, lineType: "Continuous", weight: .truss),
        .init(name: "PIPE_FILL",    aci: ACI.white, lineType: "Continuous", weight: .hair),
        .init(name: "FIXTURE",      aci: ACI.black, lineType: "Continuous", weight: .symbol),
        .init(name: "FIXTURE_FILL", aci: ACI.white, lineType: "Continuous", weight: .hair),
        .init(name: "FIXTURE_TXT",  aci: ACI.black, lineType: "Continuous", weight: .thin),
        .init(name: "BEAM",         aci: ACI.grey,  lineType: "DASHED",     weight: .truss),
        .init(name: "DIM",          aci: ACI.black, lineType: "Continuous", weight: .fine),
        .init(name: "LEADER",       aci: ACI.black, lineType: "Continuous", weight: .hair),
        .init(name: "SEAT",         aci: ACI.black, lineType: "Continuous", weight: .truss),
        .init(name: "ZONE",         aci: ACI.grey,  lineType: "DASHDOT",    weight: .truss),
        .init(name: "TITLEBLK",     aci: ACI.black, lineType: "Continuous", weight: .frame),
        .init(name: "TB_TEXT",      aci: ACI.black, lineType: "Continuous", weight: .thin),
        .init(name: "NOTES",        aci: ACI.black, lineType: "Continuous", weight: .thin),
        .init(name: "LEGEND",       aci: ACI.black, lineType: "Continuous", weight: .thin),
        .init(name: "ACCENT",       aci: ACI.black, lineType: "Continuous", weight: .heavy),
        .init(name: "MARK",         aci: ACI.black, lineType: "Continuous", weight: .fine),
        .init(name: "MASK",         aci: ACI.white, lineType: "Continuous", weight: .hair),
    ]

    public static func layer(_ name: String) -> LayerSpec {
        layers.first { $0.name == name }
            ?? LayerSpec(name: name, aci: ACI.black, lineType: "Continuous", weight: .thin)
    }

    /// 绘制顺序。**后画的盖住先画的**，这是白底遮罩"断裂"效果的前提。
    ///
    /// ★ 不要按图层名排序、不要按字典顺序遍历。
    ///   旧项目正是因为"按图层排序遍历实体"把桁架画成了空心方块 ——
    ///   底色盖在了格构上。
    public static let drawOrder: [String] = [
        "GRID", "GRIDTEXT",
        "ZONE",
        "SEAT",
        "STAGE",
        "SET_FILL", "SET", "SET_DASH",
        "TRUSS_FILL", "TRUSS",
        "PIPE_FILL", "PIPE",
        "BEAM",
        "FIXTURE_FILL", "FIXTURE",
        "MASK", "MARK",
        "LEADER", "FIXTURE_TXT",
        "DIM",
        "BORDER", "TITLEBLK", "TB_TEXT", "NOTES", "LEGEND",
        "ACCENT",
    ]

    // MARK: - 构件规格（真实毫米）

    /// 桁架规格。
    ///
    /// 参考图实测的是**图纸毫米 @1:25**（pitch 11.7687 / 高 12.0227 /
    /// 竖杆 1.016 / 弦杆 2.032）。乘 25 得到真实尺寸 ——
    /// 即一根 300mm 见方、弦杆 50.8mm（2 英寸）的标准方桁架。
    ///
    /// **为什么存真实毫米**：图纸尺寸 = 真实 / 比例。
    /// 存真实值才能在 1:50 或 1:20 的图上仍然正确，
    /// 也才能让"这根桁架实物多宽"这个信息不丢失。
    public enum TrussSpec {
        /// 单元节距（真实 mm）。实测 11.7687 × 25 = 294.22。
        public static let pitchMM: Double = 294.22
        /// 截面高度（真实 mm）。实测 12.0227 × 25 = 300.57。
        public static let heightMM: Double = 300.57
        /// 竖杆宽（真实 mm）= 1.016 × 25。
        public static let postWidthMM: Double = 25.4
        /// 弦杆高（真实 mm）= 2.032 × 25。
        public static let chordHeightMM: Double = 50.8
        /// 弦杆每 5 个单元（= 1.5m）一段，段间留可见接缝。
        /// 别改成通长 —— 接缝是参考图的关键层次感。
        public static let sectionCells: Int = 5

        public static var aspect: Double { heightMM / pitchMM }

        /// 归一化斜撑多边形（平行四边形），顶点顺序照抄参考图 PDF 的描边路径：
        /// 顶内 → 顶外 → 底内 → 底外。
        /// ★ 顺序错了会画成自交的"蝴蝶结"，渲出来就是"丑陋波浪线"。
        /// 坐标以单元左下角为原点、x 向右、y **向上**（已从 PDF 的向下坐标翻转）。
        public static let diagonalLeft: [Vec2] = [
            Vec2(0.48921, 0.93662),   // 顶内（顶点在单元中央）
            Vec2(0.56835, 0.89437),
            Vec2(0.16547, 0.06338),   // 底内
            Vec2(0.08633, 0.09859),
        ]
        public static let diagonalRight: [Vec2] = [
            Vec2(0.94964, 0.09859),
            Vec2(0.87050, 0.06338),
            Vec2(0.46763, 0.89437),
            Vec2(0.54676, 0.93662),
        ]

        /// 图纸上的单元宽度（mm）。
        public static func pitchOnSheet(scale: Double) -> Double { pitchMM / scale }
        public static func heightOnSheet(scale: Double) -> Double { heightMM / scale }
        public static func postWidthOnSheet(scale: Double) -> Double { postWidthMM / scale }
        public static func chordHeightOnSheet(scale: Double) -> Double { chordHeightMM / scale }
    }

    /// 管线规格（LX / SOUND 吊杆）。
    ///
    /// 参考图实测：外高 5.52pt = 1.9476mm 白填充 + 0.144pt 细描边，**没有内线**。
    /// 用户原话：「LX 和 SOUND 的这个线是空心线，是一个超级长方形。」
    public enum PipeSpec {
        /// 真实高度（mm）。实测 1.9476 × 25 = 48.69。
        public static let heightMM: Double = 48.69
        public static func heightOnSheet(scale: Double) -> Double { heightMM / scale }
    }

    /// 布景细线（`type: line`）的半高，仅影响避让计算。
    public static let lineHalfHeight: Double = 0.35

    /// 灯号圆圈的半径系数。参考图 r / 字高 ≈ 1.05。
    public static let markRadiusFactor: Double = 1.05
}
