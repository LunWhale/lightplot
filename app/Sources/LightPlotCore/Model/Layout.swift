import Foundation

extension LXDocument {

    /// 所有会被画出来的东西的外接矩形（文档 mm）。
    ///
    /// 用途只有两个：**把平面放进图幅**，以及**判断它放不放得下**。
    /// 必须包含灯具符号的实际占位 —— 只算构件会漏掉挂在杆两端的灯，
    /// 于是"看起来塞进去了"但符号压在图框上。
    public var contentBounds: Rect {
        var pieces: [Rect] = [stageBounds]

        for p in positions {
            if let shape = p.shape {
                if let r = Rect(points: [shape.start, shape.end]) { pieces.append(r) }
            }
        }
        for z in zones { pieces.append(z.rect) }
        for s in setPieces { pieces.append(s.rect) }

        // 灯具：世界点 ± 符号半径。符号长轴在图纸上 11.2mm，
        // 换算回文档尺寸要 × 比例，并留出一点标注空间。
        let symbolRadiusDoc = Paper.TrussSpec.pitchMM        // ≈294mm，足够覆盖符号与圆圈
        for (fixture, mount) in Resolver.allMounts(in: self) {
            guard let p = mount.worldPoint else { continue }
            let pad = symbolRadiusDoc / 2
            pieces.append(Rect(x0: p.x - pad, y0: p.y - pad, x1: p.x + pad, y1: p.y + pad))
            _ = fixture
        }

        return pieces.dropFirst().reduce(pieces[0]) { $0.union($1) }
    }
}

extension SheetLayout {

    /// 右侧信息栏的宽度（图纸 mm）。
    ///
    /// **必须是宽度而不是绝对坐标。** 早先写死 `infoColumnX = 700`
    /// （为 A1 定的绝对位置），换成 A0 后平面可用宽度仍是 660mm ——
    /// 纸变大了却一点没多出来，用户会以为"换纸没用"。
    public static let infoColumnWidth: Double = 130

    /// A4 / Letter 这类小纸上，130mm 的信息栏会吃掉一半宽度，
    /// 图就只剩一条缝。所以小纸按纸宽收窄，大纸保持 130mm。
    ///
    /// **锚点是 A1 = 130mm**（这是实测调好的值，图例与图签正好装下）。
    /// 只在小纸上收缩，不放大 —— 大纸上加宽信息栏会把平面挤窄，
    /// 反而降低容量（实测 A1 从 130 改成 152 就让平面少了 22mm）。
    public static func infoColumnWidth(for paper: PaperSize) -> Double {
        let usable = paper.widthMM - 2 * Paper.frameInner
        // A1 可用宽约 801mm → 130mm。取同等比例，但不超过 130。
        let proportional = usable * (130.0 / 801.0)
        return min(max(proportional, 46), infoColumnWidth)
    }

    /// 右侧信息栏的起点（图纸 mm）。随纸幅走。
    public static func infoColumnX(for paper: PaperSize) -> Double {
        paper.widthMM - Paper.frameInner - infoColumnWidth(for: paper)
    }

    /// A1 的信息栏起点（保持旧调用点可用）。
    public static let infoColumnX: Double = 841 - 20 - 130

    /// 平面可用的图纸区域。
    public static func planArea(paper: PaperSize,
                                padding: Double = 4) -> Rect {
        Rect(x0: Paper.frameInner + padding,
             y0: Paper.frameInner + padding,
             x1: infoColumnX(for: paper) - padding,
             y1: paper.heightMM - Paper.frameInner - padding)
    }

    /// **按内容自动放置图框原点，比例保持不变。**
    ///
    /// 这是"可导出正确尺寸"的另一半：比例锁死 1:25，
    /// 能动的只有图框在纸上的位置。所以这里只做居中，绝不缩放。
    ///
    /// 旧管线把原点写死成 (355, 215)，而那份数据只有 5 排观众席；
    /// 换成 7 排（真实数据）就会掉出图框 —— 写死原点这类问题是隐形的，
    /// 因为图上"看起来还在"，只是少了半截观众席。
    public static func fitted(to content: Rect,
                              paper: PaperSize = .a1,
                              scaleDenominator: Double = 25,
                              padding: Double = 4) -> SheetLayout {
        let area = planArea(paper: paper, padding: padding)
        let safeScale = max(1, scaleDenominator)
        let centre = content.center / safeScale
        let origin = Vec2(area.center.x - centre.x,
                          area.center.y - centre.y)
        return SheetLayout(paper: paper,
                           scaleDenominator: safeScale,
                           originOnSheet: origin)
    }

    /// 右侧信息栏的内缩量。
    ///
    /// 图框分区号与刻度画在 `innerFrame` **内侧** 3.4mm 处，
    /// 信息栏若顶到 `innerFrame.x1` 就会压住它们
    /// （实测图例的灯具数量 "2" 压住了分区号 "2"）。
    public static let infoInset: Double = 10

    /// 图签矩形（图纸 mm）。
    public static func titleBlockRect(for layout: SheetLayout) -> Rect {
        let x0 = infoColumnX(for: layout.paper)
        // 右边让开**分区字母带**。
        //
        // 分区字母画在内框内侧 3mm 处（约 x = innerFrame.x1 − 6）。
        // 信息栏若只让 10mm，说明文字一长就伸进去压住字母
        // （实测 'D' 压 'LANTERN POSITIONS SHOWN AT TRIM'）。
        // 12mm 才能稳定让开，且它在 A1 上仍留足宽度。
        let x1 = layout.innerFrame.x1 - infoInset - 2
        let y0 = layout.innerFrame.y0
        let layoutHeight = layout.innerFrame.height
        // 图签高度按可用高度压缩。
        //
        // 设计值 126mm（A1 上正好）。但 A4 只有 210mm 高、可用 170mm，
        // 126 + 说明栏 66 已经超过可用高度 —— 图例被挤到负高度，
        // 所有图例内容叠在一条线上（实测 'FIXTURES' 压 'SCALE 1:100 ON A4'）。
        //
        // 取 52%：给说明栏和图例各留出位置，且 A1 及以上仍取满 126mm
        // （A1 可用高度 554mm，554×0.52 = 288 > 126，所以 min 取 126）。
        let h = min(126, layoutHeight * 0.52)
        return Rect(x0: x0, y0: y0, x1: x1, y1: y0 + h)
    }

    /// 说明栏（比例行 + 尺寸声明 + 场地尺寸 + 比例尺）占的高度。
    ///
    /// 图例必须让开这一条 —— 早先两者都"从图签上方开始"，
    /// 在小纸上直接叠在一起（A3 实测 'COLOUR' x 'SCALE 1:50'）。
    /// 说明栏是**读图的前提**，图例是可压缩的，所以图例让。
    /// **实测值 66mm，不是估的。**
    ///
    /// 说明栏从 `tb.y1 + 62` 起、5 行 × 4.4mm 向下，再加比例尺 ——
    /// 内容实际占据 `tb.y1 + 29` 到 `tb.y1 + 62` 这一段。
    /// 早先写 46 是错的：A1 上因为 `top - 190` 比它大，
    /// 图例被推到更上方，偶然避开了；A2/A3 上 `top - 190` 更小，
    /// 图例就从 46 起，直接压在说明上（实测 'L119 … Dark Blue'
    /// 压 'ALL DIMENSIONS IN MILLIMETRES'）。
    /// **偶然避开比明显出错更坏** —— 它让错误的常数看起来是对的。
    /// 说明栏高度。A1 及以上 66mm；小纸按可用高度收缩。
    ///
    /// 固定值在小纸上会把图例挤成负高度 —— A4 可用 170mm，
    /// 图签 88 + 说明 66 = 154，只剩 16mm，图例内容全叠在一条线上。
    public static func notesBandHeight(for paper: PaperSize) -> Double {
        let usable = paper.heightMM - 2 * Paper.frameInner
        return min(66, usable * 0.36)
    }

    /// 图例矩形（图纸 mm）：图签上方、说明栏之上，**用满这段空间**。
    ///
    /// 早先高度固定 190mm —— 图例里有两张表（灯具类型 + 色片），
    /// 类型表 7 行就吃掉 134mm，色片区只剩一两行，
    /// 其余色片被截成 "N more in the gel library"。
    /// 而图签上方到图框顶端之间其实还有几百毫米空着。
    ///
    /// 固定高度等于把"能装多少"硬编码进版面 —— 一旦文档里的
    /// 类型/色片变多就必然溢出。改成用满可用空间，容量随纸幅自动变化。
    public static func legendRect(for layout: SheetLayout) -> Rect {
        let tb = titleBlockRect(for: layout)
        let top = layout.innerFrame.y1 - 16
        let floor = tb.y1 + notesBandHeight(for: layout.paper)
        return Rect(x0: tb.x0, y0: floor, x1: tb.x1, y1: top)
    }

    /// 图例可用的最小高度。低于它就该**整块省略**并说明，
    /// 而不是画成一堆重叠的行。
    public static let legendMinimumHeight: Double = 30

    /// 当前纸幅 + 比例下，平面区能装下的最大场地尺寸（文档 mm）。
    ///
    /// 这个数字是给用户看的："A1 @ 1:25 最多装 16.5 × 12.4 米"。
    /// 没有它，用户只能靠"图装不下"这条错误反推，而不知道该怎么改。
    public static func capacity(paper: PaperSize, scale: Double) -> Vec2 {
        let area = planArea(paper: paper)
        return Vec2(area.width * scale, area.height * scale)
    }

    /// 内容是否完整落在平面区域内（含容差）。不落进去就是版面错误，必须报出来。
    public func contentFits(_ content: Rect, padding: Double = 0) -> Bool {
        let area = Self.planArea(paper: paper, padding: padding)
        let tl = toSheet(Vec2(content.x0, content.y1))
        let br = toSheet(Vec2(content.x1, content.y0))
        return tl.x >= area.x0 - 0.5 && tl.y >= area.y0 - 0.5
            && br.x <= area.x1 + 0.5 && br.y <= area.y1 + 0.5
    }

    /// 内容在纸上的矩形。
    public func sheetBounds(of content: Rect) -> Rect {
        let a = toSheet(Vec2(content.x0, content.y0))
        let b = toSheet(Vec2(content.x1, content.y1))
        return Rect(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }
}
