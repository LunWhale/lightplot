import Foundation

/// 剖面图的空间。
///
/// **和平面图是两套坐标系，不要混。**
///
///   平面图：文档 x = 舞台横向，文档 y = 舞台纵深
///   剖面图：横轴 = 文档 **y**（纵深），纵轴 = **高度**
///
/// 也就是说剖面图把 (纵深, 高度) 画成 (x, y)。这个换向只在这里做一次。
/// 旧管线的 `section.py` 用 `s(y_rig, h)` 做同一件事 —— 名字相同，
/// 但它的 `Y_OFF` 是"把整段纵深推到纸面中间"的硬编码平移。
/// 这里改成可配置的 `depthWindow`：用户能看到场地任意一段，
/// 而不是永远盯着从 -4200 开始的那 21m。
public struct SectionLayout: Sendable, Equatable, Codable {
    public var paper: PaperSize
    /// 比例分母。剖面图默认 1:50（A3 能装下整个台深）。
    public var scaleDenominator: Double
    /// 可见的纵深窗口（文档 y 范围，mm）。nil = 按内容自动。
    public var depthWindow: ClosedRange<Double>?
    /// 可见的高度范围（mm）。nil = 从最低点到栅顶。
    public var heightRange: ClosedRange<Double>?
    /// 图框在纸上的位置（mm）。
    public var originOnSheet: Vec2
    /// 绘图区（纸张 mm 内框以内，扣掉右侧信息栏）。
    public var drawingArea: Rect

    public init(paper: PaperSize = .a3,
                scaleDenominator: Double = 50,
                depthWindow: ClosedRange<Double>? = nil,
                heightRange: ClosedRange<Double>? = nil,
                originOnSheet: Vec2 = Vec2(24, 96),
                // 绘图区必须**让开右栏**。
                //
                // 右栏宽度 62mm、离内框 9mm，所以栏左侧 =
                // paper.width - frameInner - 62 - 9 = 420 - 20 - 71 = 329。
                // 早先写 332 会与栏重叠 3mm，光束直接画进图例里（实测抓到）。
                drawingArea: Rect? = nil) {
        self.paper = paper
        self.scaleDenominator = scaleDenominator
        self.depthWindow = depthWindow
        self.heightRange = heightRange
        self.originOnSheet = originOnSheet
        self.drawingArea = drawingArea ?? Self.defaultDrawingArea(for: paper)
    }

    /// 剖面图右栏的宽度与边距（与 `SectionBuilder.drawPanels` 必须一致）。
    public static let panelWidth: Double = 62
    /// 面板与图框右边带的间隙。
    ///
    /// 9mm 时面板右边界落在 391mm，而右侧分区字母在 393.6mm ——
    /// 只差 0.3mm，看起来像字母压在面板边框上（我自己两次误判为 bug）。
    /// 改成 13mm 后两侧各留 2.6 / 6.4mm，视觉上干净。
    public static let panelGap: Double = 13

    /// 右栏左边缘（图纸 mm）。
    public static func panelLeft(for paper: PaperSize) -> Double {
        paper.widthMM - Paper.frameInner - panelWidth - panelGap
    }

    /// 默认绘图区：内框内缩，并在右侧让开信息栏。
    public static func defaultDrawingArea(for paper: PaperSize) -> Rect {
        Rect(x0: Paper.frameInner + 8,
             y0: Paper.frameInner + 10,
             x1: panelLeft(for: paper) - 4,
             y1: paper.heightMM - Paper.frameInner - 8)
    }

    /// (纵深, 高度) mm → 纸张 mm。**全工程唯一的高度换向点。**
    public func toSheet(depth: Double, height: Double) -> Vec2 {
        Vec2(originOnSheet.x + depth / scaleDenominator,
             originOnSheet.y + height / scaleDenominator)
    }

    public func toSheet(_ p: Vec2) -> Vec2 { toSheet(depth: p.x, height: p.y) }

    /// 纸张 mm → (纵深, 高度) mm。
    public func toDocument(_ p: Vec2) -> Vec2 {
        Vec2((p.x - originOnSheet.x) * scaleDenominator,
             (p.y - originOnSheet.y) * scaleDenominator)
    }

    public func sheetLength(_ d: Double) -> Double { d / scaleDenominator }

    public var isValid: Bool {
        scaleDenominator.isFinite && scaleDenominator >= 1
            && drawingArea.width > 1 && drawingArea.height > 1
    }

    /// 按内容自动放置：比例不变，只移动原点，让内容居中在绘图区。
    ///
    /// 与平面图同一条纪律：**绝不为了塞下而改比例**。
    /// 装不下就报错，由用户决定是缩比例还是裁范围 —— 而不是悄悄变形。
    public static func fitted(content: Rect,
                              paper: PaperSize = .a3,
                              scaleDenominator: Double = 50) -> SectionLayout {
        // 与默认值一致：内框内缩 + 右侧让开信息栏。
        let area = defaultDrawingArea(for: paper)
        let safe = max(1, scaleDenominator)
        let centreDepth = content.center.x / safe
        let centreHeight = content.center.y / safe
        let origin = Vec2(area.center.x - centreDepth,
                          area.center.y - centreHeight)
        return SectionLayout(paper: paper,
                             scaleDenominator: safe,
                             originOnSheet: origin,
                             drawingArea: area)
    }

    /// 内容是否完整落在绘图区内。
    public func contentFits(_ content: Rect) -> Bool {
        let a = toSheet(depth: content.x0, height: content.y0)
        let b = toSheet(depth: content.x1, height: content.y1)
        return a.x >= drawingArea.x0 - 0.5 && a.y >= drawingArea.y0 - 0.5
            && b.x <= drawingArea.x1 + 0.5 && b.y <= drawingArea.y1 + 0.5
    }
}

/// 剖面图的内容范围。
extension LXDocument {

    /// 剖面图（沿舞台中轴切线，朝 SL 看）能看见的全部内容外接矩形。
    ///
    /// 横轴 = 纵深，纵轴 = 高度。包含：
    ///   · 台面到栅顶
    ///   · 观众席（向下为负高）
    ///   · 台口前区
    ///   · 所有横向吊杆（它们在剖面上是一个点，但要留出标注空间）
    ///   · 人形与尺寸标尺的余量
    public var sectionContentBounds: Rect {
        var minDepth = -Double(stage.audienceRows) * stage.audienceRowDepth - 600
        var maxDepth = stage.depth + 400
        var minHeight = -Double(stage.audienceRows) * stage.audienceRake - 900
        var maxHeight = stage.gridHeight + 700

        // 台口可能在台唇外（负纵深）
        minDepth = min(minDepth, stage.prosceniumX - 1200)

        // 横向吊杆：trim 可能高于栅顶（打在天幕上），也要算进去
        for position in positions where position.kind == .horizontal {
            if let trim = position.trim {
                maxHeight = max(maxHeight, trim + 600)
            }
            if let y = position.y {
                minDepth = min(minDepth, y - 500)
                maxDepth = max(maxDepth, y + 500)
            }
        }

        // 竖直 BOOM：在剖面上是虚线（BEYOND CUT），但标签要放得下
        for position in positions where position.kind == .vertical {
            if let trim = position.trim { maxHeight = max(maxHeight, trim + 400) }
        }

        return Rect(x0: minDepth, y0: minHeight, x1: maxDepth, y1: maxHeight)
    }

    /// 布景在剖面上的高度。
    ///
    /// 数据里没有 `height` 字段时用按类型的合理缺省 ——
    /// 布景高度是"光打在什么上"的关键，缺省值必须保守（不要凭空造一面 3m 高墙）。
    public func sectionHeight(of piece: SetPiece) -> Double {
        if let explicit = piece.height { return explicit }
        switch piece.kind {
        case .stair:   return 2400       // 楼梯通常通向上层平台
        case .rect:    return 750        // 台/床/桌这一档
        case .line:    return 2400       // 墙/隔断
        }
    }

    /// 中线切线位置（剖面 A-A 的切点）。
    ///
    /// 默认切舞台纵深中点；如果场地上有布景跨过那条线，优先切布景 ——
    /// 剖到空处会得到一张"什么都没切到"的图。
    public var sectionCutDepth: Double {
        let mid = stage.depth * 0.5
        let crossing = setPieces.filter { piece in
            switch piece.kind {
            case .rect, .stair:
                return piece.y0 <= mid && mid <= piece.y1
            case .line:
                return abs((piece.y0 + piece.y1) / 2 - mid) < 1200
            }
        }
        guard let first = crossing.min(by: {
            abs(($0.y0 + $0.y1) / 2 - mid) < abs(($1.y0 + $1.y1) / 2 - mid)
        }) else { return mid }
        return (first.y0 + first.y1) / 2
    }
}
