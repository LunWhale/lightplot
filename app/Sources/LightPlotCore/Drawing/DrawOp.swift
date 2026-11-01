import Foundation

public enum LightPlotVersion {
    /// 语义化版本。
    ///
    /// **打包成 .app 之后要读 bundle 里的版本**，否则发布版的
    /// PDF 元数据里还写着这个兜底值 —— 用户看"关于"和看文件属性会对不上。
    /// 命令行工具（`lpx`）没有 bundle，退回这里的常量。
    ///
    /// 构建号固定 "dev"：**不允许写时间戳**，摘要与产物必须可字节级回归。
    public static let fallback = "0.001"
    public static let build = "dev"

    public static var string: String { bundleVersion ?? fallback }

    static var bundleVersion: String? {
        guard let v = Bundle.main
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !v.isEmpty else { return nil }
        // 命令行没有 bundle 时 CfBundleShortVersionString 可能落到别处，
        // 只有长得像版本号才采用。
        return v.first?.isNumber == true ? v : nil
    }
}

/// 图纸绘制指令。
///
/// **这是整套架构里最关键的一个抽象。**
///
/// 旧管线有两套独立的渲染实现：DXF（ezdxf）与 PDF（pdfout.py，手写）。
/// 技术报告明确说那是"这套系统最大的一处结构性重复" ——
/// 改一处忘了另一处，PDF 和 DXF 就会不一致。
///
/// 这里改成：**几何只生成一次，变成指令列表；两个后端只负责把指令画出来。**
///   · `SheetPDF` → CoreGraphics
///   · `CanvasView`（SwiftUI）→ GraphicsContext
///   · `SheetDXF`（将来）→ ASCII 文本
///
/// 指令列表本身是可断言的：灯数、多边形数、文字数、包围盒都能在测试里数。
/// 这就是"GUI 也能被精确测试"的前提。
public enum DrawOp: Equatable, Sendable {
    /// 只描边。`dash` 为 nil 表示实线，否则是"实线段/空白段"交替的长度表（mm）。
    case stroke(points: [Vec2], closed: Bool, layer: String,
                weight: Paper.LineWeight, dash: [Double]?)

    /// 只填充（白底遮罩用）。
    case fill(points: [Vec2], rgb: UInt32)

    /// 填充 + 描边（桁架杆件、管线、设备块）。
    case fillStroke(points: [Vec2], fill: UInt32, layer: String, weight: Paper.LineWeight)

    /// 圆：只描边。
    case circle(center: Vec2, radius: Double, layer: String, weight: Paper.LineWeight)

    /// 圆：填充（遮罩）。
    case fillCircle(center: Vec2, radius: Double, rgb: UInt32)

    case text(TextOp)

    /// 该指令覆盖的点（用于版面边界检查）。文字与圆返回 nil。
    public var pointsForBounds: [Vec2]? {
        switch self {
        case .stroke(let p, _, _, _, _):  return p
        case .fill(let p, _):              return p
        case .fillStroke(let p, _, _, _):  return p
        default:                           return nil
        }
    }

    public var layer: String? {
        switch self {
        case .stroke(_, _, let l, _, _):    return l
        case .fillStroke(_, _, let l, _):   return l
        case .circle(_, _, let l, _):       return l
        case .text(let t):                  return t.layer
        case .fill, .fillCircle:            return nil
        }
    }
}

public struct TextOp: Equatable, Sendable {
    public var string: String
    /// 锚点（图纸 mm）。垂直方向按 cap 高度居中。
    public var origin: Vec2
    /// **cap 高度**（图纸 mm），不是 em。
    public var capMM: Double
    public var rotationDegrees: Double
    public var align: TextAlign
    public var layer: String
    public var family: FontFamily

    public init(_ string: String,
                at origin: Vec2,
                capMM: Double,
                rotationDegrees: Double = 0,
                align: TextAlign = .center,
                layer: String = "NOTES",
                family: FontFamily = .regular) {
        self.string = string
        self.origin = origin
        self.capMM = capMM
        self.rotationDegrees = rotationDegrees
        self.align = align
        self.layer = layer
        self.family = family
    }
}

public enum FontFamily: String, Equatable, Sendable {
    case regular, bold

    public var measuring: TextMeasuring {
        switch self {
        case .regular: return FontLibrary.regular
        case .bold:    return FontLibrary.bold
        }
    }
}

// MARK: - 便捷构造

extension DrawOp {
    public static func stroke(_ points: [Vec2], layer: String,
                              weight: Paper.LineWeight, closed: Bool = false) -> DrawOp {
        .stroke(points: points, closed: closed, layer: layer, weight: weight, dash: nil)
    }

    /// 轴对齐矩形描边。
    public static func strokeRect(_ r: Rect, layer: String, weight: Paper.LineWeight) -> DrawOp {
        .stroke(points: [Vec2(r.x0, r.y0), Vec2(r.x1, r.y0),
                         Vec2(r.x1, r.y1), Vec2(r.x0, r.y1)],
                closed: true, layer: layer, weight: weight, dash: nil)
    }

    /// 轴对齐矩形填充。
    public static func fillRect(_ r: Rect, rgb: UInt32) -> DrawOp {
        .fill(points: [Vec2(r.x0, r.y0), Vec2(r.x1, r.y0),
                       Vec2(r.x1, r.y1), Vec2(r.x0, r.y1)], rgb: rgb)
    }
}

/// 一张排好版的图纸：文档 + 版面 + 指令列表。
public struct PlanSheet: Sendable {
    public let doc: LXDocument
    public let layout: SheetLayout
    public let ops: [DrawOp]
    /// 文字避让的结果：丢了哪些标注。
    ///
    /// 暴露出来是为了让 UI 能提示用户"这张纸上标注放不下"，
    /// 而不是让用户自己从一张糊成一片的图里看出来。
    public let textFit: TextFitter.Result

    public init(doc: LXDocument, layout: SheetLayout,
                lightingState: LightingState? = nil) {
        self.doc = doc
        self.layout = layout
        let built = PlanBuilder.buildFitted(doc: doc, layout: layout,
                                            lightingState: lightingState)
        self.ops = built.ops
        self.textFit = built.fit
    }

    /// 这张纸上是否因为太密而丢了核心标注（灯号 / 色片 / 通道）。
    public var labelsWereOmitted: Bool { textFit.lostEssentialLabels }

    /// 内容是否完整落在图幅内。版面错误必须被报出来，不能靠眼睛发现。
    public var contentFitsSheet: Bool {
        layout.contentFits(doc.contentBounds)
    }

    /// 各图层的指令数（摘要与测试用）。
    public var opCountsByLayer: [String: Int] {
        var counts: [String: Int] = [:]
        for op in ops {
            let key = op.layer ?? "FILL"
            counts[key, default: 0] += 1
        }
        return counts
    }

    public var textCount: Int {
        ops.reduce(0) { $1.isText ? $0 + 1 : $0 }
    }

    public var polygonCount: Int {
        ops.reduce(0) { $1.isPolygon ? $0 + 1 : $0 }
    }
}

extension DrawOp {
    public var isText: Bool {
        if case .text = self { return true }
        return false
    }

    public var isPolygon: Bool {
        switch self {
        case .stroke, .fill, .fillStroke: return true
        default: return false
        }
    }
}


extension PlanSheet {
    /// 一份"装不下"的图纸应该长什么样。
    ///
    /// 早先的行为：内容照常画在纸外，用户得到一张**空白纸** ——
    /// 没有任何提示说明为什么空。这是最糟的失败方式：
    /// 看起来像"图没画出来"，而不是"你的场地装不进这张纸"。
    ///
    /// 现在的行为：纸面照画（图框、图签都在），中间只留一行说明
    /// 告诉用户实际内容多大、这张纸能装多大、建议怎么做。
    /// 这比"空白"有用得多，也比"自动缩小比例"诚实 ——
    /// 比例是设计要求，不该被悄悄改掉。
    public static func overflowNotice(doc: LXDocument,
                                      layout: SheetLayout) -> PlanSheet {
        let paper = layout.paper
        let cap = SheetLayout.capacity(paper: paper,
                                       scale: layout.scaleDenominator)
        let content = doc.contentBounds
        let area = SheetLayout.planArea(paper: paper)

        var ops: [DrawOp] = []
        // 图框
        ops.append(.strokeRect(layout.outerFrame, layer: "BORDER", weight: .frame))
        ops.append(.strokeRect(layout.innerFrame, layer: "BORDER", weight: .frame))

        // 这张纸是给"装不下"用的，整张纸只有这几行字 ——
        // 字号必须**远大于**正常图面字号，否则 A1 上只剩一个看不清的小点。
        let centre = Vec2(paper.widthMM / 2, paper.heightMM / 2)
        let regular = FontLibrary.regular
        func note(_ text: String, _ dy: Double, cap capMM: Double,
                  bold: Bool = false) {
            let family: FontFamily = bold ? .bold : .regular
            let fitted = regular.fitCapMM(text, capMM: capMM,
                                          maxWidthMM: area.width * 0.9)
            ops.append(.text(TextOp(text, at: Vec2(centre.x, centre.y + dy),
                                    capMM: fitted, rotationDegrees: 0,
                                    align: .center,
                                    layer: "NOTES", family: family)))
        }

        // 行距必须大于字号。22mm cap 的两行至少隔 30mm，
        // 否则上下两行会压在一起（这是 Text layout 测试抓到的真实 bug）。
        let big: Double = 20
        // 必须写明**是哪张纸**装不下 —— 否则用户不知道该改什么。
        note("THE DRAWING DOES NOT FIT", 62, cap: big, bold: true)
        note("ON \(layout.paper.name) AT 1:\(Int(layout.scaleDenominator))",
             34, cap: big, bold: true)
        note(String(format: "Content is  %.1f x %.1f m",
                    content.width / 1000, content.height / 1000),
             2, cap: 9)
        note(String(format: "\(layout.paper.name) holds  %.1f x %.1f m  at 1:%.0f",
                    cap.x / 1000, cap.y / 1000, layout.scaleDenominator),
             -16, cap: 9)
        note("Use a larger sheet, or a smaller scale.", -36, cap: 9)
        note("(Paper and Scale are in the inspector.)", -50, cap: 6)

        return PlanSheet(preRenderedDoc: doc, layout: layout, ops: ops)
    }

    /// 用预先算好的指令构造（剖面图走这条路）。
    ///
    /// 存在的理由：剖面图的几何在 `SectionBuilder` 里已经全部算成纸张坐标，
    /// 不需要再经过 `PlanBuilder`。让两条路径共用 `PlanSheet` / `SheetCanvas`，
    /// 就只有一个绘制实现 —— 这是避免"两套渲染漂移"的关键。
    public init(preRenderedDoc doc: LXDocument,
                layout: SheetLayout,
                ops: [DrawOp]) {
        self.doc = doc
        self.layout = layout
        self.ops = ops
        // 剖面图在 SectionBuilder 里已自己处理版面；这里如实报告没有丢字。
        self.textFit = TextFitter.Result(ops: ops, dropped: [:])
    }

    /// 用自动版面：比例锁死，只移动图框原点让内容居中。
    ///
    /// **装不下时不静默出图** —— 改为输出一张带说明的提示页。
    /// 空白纸是最糟的失败方式：用户会以为程序坏了，而不是"场地太大"。
    public init(fitting doc: LXDocument, paper: PaperSize = .a1) {
        self.init(fitting: doc, paper: paper, scale: doc.meta.scale)
    }

    /// 分场景平面图：色片显示为**该场景实际使用**的色号。
    public init(fitting doc: LXDocument, paper: PaperSize, scale: Double,
                lightingState: LightingState?) {
        let layout = SheetLayout.fitted(to: doc.contentBounds,
                                        paper: paper,
                                        scaleDenominator: scale)
        if layout.contentFits(doc.contentBounds) {
            self.init(doc: doc, layout: layout, lightingState: lightingState)
        } else {
            self = PlanSheet.overflowNotice(doc: doc, layout: layout)
        }
    }

    /// 指定纸幅**与比例**（多页图纸集用：每页自己的设置）。
    public init(fitting doc: LXDocument, paper: PaperSize, scale: Double) {
        let layout = SheetLayout.fitted(to: doc.contentBounds,
                                        paper: paper,
                                        scaleDenominator: scale)
        if layout.contentFits(doc.contentBounds) {
            self.init(doc: doc, layout: layout)
        } else {
            self = PlanSheet.overflowNotice(doc: doc, layout: layout)
        }
    }
}
