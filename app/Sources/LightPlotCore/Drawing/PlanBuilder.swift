import Foundation

/// 把一个 `LXDocument` 排成一张图幅的绘制指令。
///
/// 绘制顺序不是随意的：**后画的盖住先画的**，白底遮罩必须紧挨在它保护的对象之前。
/// 旧项目曾经"按图层名排序遍历实体"，结果底色盖在格构上，
/// 桁架变成空心方块 —— 所以这里严格按 `Paper.drawOrder` 手工编排。
public enum PlanBuilder {

    public static func build(doc: LXDocument, layout: SheetLayout,
                             lightingState: LightingState? = nil) -> [DrawOp] {
        buildFitted(doc: doc, layout: layout, lightingState: lightingState).ops
    }

    /// 排完并做**文字避让**。
    ///
    /// 区分为两步的原因：避让可能丢掉灯号/色片标注，
    /// 那必须在图上印一行说明（"这张纸读不了，换更大比例"）。
    /// 所以先排一遍看丢了什么，再决定是否补那行说明、重排一次。
    public static func buildFitted(doc: LXDocument, layout: SheetLayout,
                                   lightingState: LightingState? = nil)
        -> (ops: [DrawOp], fit: TextFitter.Result) {
        let raw = layoutOps(doc: doc, layout: layout, lightingState: lightingState,
                            densityNote: nil)
        let first = TextFitter.run(raw)

        guard first.lostEssentialLabels else {
            return (first.ops, first)
        }
        // 丢了核心标注 —— 重排一次，把说明写进 Notes 栏。
        let note = "LABELS OMITTED: \(first.totalDropped) at this scale. "
            + "Use a larger scale (1:50 or 1:25)."
        let raw2 = layoutOps(doc: doc, layout: layout, lightingState: lightingState,
                             densityNote: note)
        let second = TextFitter.run(raw2)
        return (second.ops, second)
    }

    /// 纯排版（不含避让）。
    static func layoutOps(doc: LXDocument, layout: SheetLayout,
                          lightingState: LightingState?,
                          densityNote: String?) -> [DrawOp] {
        var canvas = PlanCanvas(doc: doc, layout: layout,
                                lightingState: lightingState)
        canvas.densityNote = densityNote

        canvas.drawGrid()          // GRID + GRIDTEXT
        canvas.drawZones()         // ZONE
        canvas.drawAudience()      // SEAT
        canvas.drawStage()         // STAGE
        canvas.drawSetPieces()     // SET_FILL / SET / SET_DASH
        canvas.drawPositions()     // TRUSS_FILL / TRUSS / PIPE_FILL / PIPE
        canvas.drawBeamCones()     // BEAM
        canvas.drawFixtures()      // FIXTURE_FILL / FIXTURE / FIXTURE_TXT
        canvas.drawFrame()         // BORDER
        canvas.drawTitleBlock()    // TITLEBLK + TB_TEXT
        canvas.drawLegend()        // LEGEND
        canvas.drawNotes()         // NOTES
        canvas.drawStateBanner()   // 场景标签（仅分场景图）
        canvas.drawDensityBanner() // 密度警示（仅标注放不下时）

        return canvas.ops
    }
}

/// 绘制过程中的可变画布。
///
/// 有意做成 struct + mutating：所有坐标都从 `layout` 得来，
/// 不存在"某处偷偷用了个常量偏移"的路径。
struct PlanCanvas {
    let doc: LXDocument
    let layout: SheetLayout
    /// 当前场景状态。nil = 基础图（用文档原本的色片）。
    var lightingState: LightingState?
    /// 场景强度（用于在图上标注 0% 的构件）。
    var showUnlit: Bool = false
    /// 密度过高时的说明（写进 Notes 栏）。nil = 一切正常。
    var densityNote: String?
    /// 图例因纸太小而省略（说明栏会补一句）。
    var legendOmitted: Bool = false
    var ops: [DrawOp] = []

    init(doc: LXDocument, layout: SheetLayout,
         lightingState: LightingState? = nil) {
        self.doc = doc
        self.layout = layout
        self.lightingState = lightingState
    }

    // MARK: - 基础

    var paper: PaperSize { layout.paper }
    var inner: Rect { layout.innerFrame }
    var outer: Rect { layout.outerFrame }

    /// 文档坐标 → 图纸坐标。**全工程唯一的缩放入口。**
    func s(_ x: Double, _ y: Double) -> Vec2 { layout.toSheet(Vec2(x, y)) }
    func s(_ p: Vec2) -> Vec2 { layout.toSheet(p) }

    /// 文档长度 → 图纸长度。
    func len(_ d: Double) -> Double { layout.sheetLength(d) }

    mutating func add(_ op: DrawOp) { ops.append(op) }

    mutating func line(_ a: Vec2, _ b: Vec2, _ layer: String,
                       dash: [Double]? = nil) {
        let spec = Paper.layer(layer)
        add(.stroke(points: [a, b], closed: false, layer: layer,
                    weight: spec.weight,
                    dash: dash ?? Dash.pattern(layerSpec: spec)))
    }

    mutating func poly(_ pts: [Vec2], _ layer: String, closed: Bool = true,
                       dash: [Double]? = nil) {
        let spec = Paper.layer(layer)
        add(.stroke(points: pts, closed: closed, layer: layer,
                    weight: spec.weight,
                    dash: dash ?? Dash.pattern(layerSpec: spec)))
    }

    mutating func rect(_ r: Rect, _ layer: String, dash: [Double]? = nil) {
        poly([Vec2(r.x0, r.y0), Vec2(r.x1, r.y0),
              Vec2(r.x1, r.y1), Vec2(r.x0, r.y1)], layer, closed: true, dash: dash)
    }

    /// 白底遮罩：把底下的线"切断"。这是参考图里断线效果的唯一实现方式。
    mutating func mask(_ pts: [Vec2]) {
        add(.fill(points: pts, rgb: Paper.whiteRGB))
    }

    mutating func maskRect(_ r: Rect) {
        add(.fillRect(r, rgb: Paper.whiteRGB))
    }

    mutating func text(_ string: String, at p: Vec2, size: Paper.FontSize,
                       layer: String = "NOTES", align: TextAlign = .center,
                       rotation: Double = 0, family: FontFamily = .regular,
                       mask: Bool = false) {
        if mask {
            let box = family.measuring.textBox(string, at: p, capMM: size.capMM,
                                               align: align,
                                               rotationDegrees: rotation,
                                               pad: 0.35)
            maskRect(box)
        }
        add(.text(TextOp(string, at: p, capMM: size.capMM,
                         rotationDegrees: rotation, align: align,
                         layer: layer, family: family)))
    }

    /// 带缩放的文字：塞不进 `maxWidth` 就缩，但不低于 1.6mm（可读下限）。
    mutating func fittedText(_ string: String, at p: Vec2, size: Paper.FontSize,
                             maxWidth: Double, layer: String = "TB_TEXT",
                             align: TextAlign = .left,
                             family: FontFamily = .regular) {
        let cap = family.measuring.fitCapMM(string, capMM: size.capMM,
                                            maxWidthMM: maxWidth)
        add(.text(TextOp(string, at: p, capMM: cap,
                         rotationDegrees: 0, align: align,
                         layer: layer, family: family)))
    }

    // MARK: - 图框

    mutating func drawFrame() {
        // 外框贴纸边，内框 20mm 进深 —— 参考图实测。
        add(.strokeRect(outer, layer: "BORDER", weight: .frame))
        add(.strokeRect(inner, layer: "BORDER", weight: .frame))

        // 分区刻度与编号。参考图 95 处分区号，是读图人定位用的。
        let step: Double = 50
        let tick: Double = 3.0

        let cols = Int(((inner.width) / step).rounded(.up))
        for i in 0...cols {
            let x = min(inner.x0 + Double(i) * step, inner.x1)
            line(Vec2(x, inner.y0), Vec2(x, inner.y0 + tick), "BORDER")
            line(Vec2(x, inner.y1), Vec2(x, inner.y1 - tick), "BORDER")
            if i < cols {
                let cx = x + step / 2
                // 信息栏所在的横向区间不画分区数字 ——
                // 图签就长在那里，数字会压住 "SHEET:" 这类字段名
                // （实测 A4 上 '5' x 'SHEET:'）。制图惯例也是
                // 分区基准带止于图签左边界。
                let infoLeft = SheetLayout.infoColumnX(for: layout.paper)
                if cx < inner.x1 - 4 && cx < infoLeft - 2 {
                    text("\(i + 1)", at: Vec2(cx, inner.y1 - tick - 3.2),
                         size: .border, layer: "GRIDTEXT")
                    text("\(i + 1)", at: Vec2(cx, inner.y0 + tick + 3.2),
                         size: .border, layer: "GRIDTEXT")
                }
            }
        }

        let rows = Int(((inner.height) / step).rounded(.up))
        for j in 0...rows {
            let y = min(inner.y0 + Double(j) * step, inner.y1)
            line(Vec2(inner.x0, y), Vec2(inner.x0 + tick, y), "BORDER")
            line(Vec2(inner.x1, y), Vec2(inner.x1 - tick, y), "BORDER")
            if j < rows {
                let cy = y + step / 2
                if cy < inner.y1 - 4 {
                    let letter = j < 26 ? String(UnicodeScalar(65 + j)!) : "\(j + 1)"
                    text(letter, at: Vec2(inner.x0 + tick + 3.2, cy),
                         size: .border, layer: "GRIDTEXT", rotation: 90)
                    text(letter, at: Vec2(inner.x1 - tick - 3.2, cy),
                         size: .border, layer: "GRIDTEXT", rotation: 90)
                }
            }
        }
    }

    /// 网格（场地基准线）。参考图只有极淡的构造线，不要画成方格纸。
    mutating func drawGrid() {
        // 只在舞台中心画一条 + 一条，作为读图基准。
        let b = doc.stageBounds
        line(s(0, b.y0), s(0, b.y1), "GRID", dash: [1.0, 6.0])
    }

    // MARK: - 图签

    mutating func drawTitleBlock() {
        let tb = Self.titleBlockRect(for: layout)
        add(.strokeRect(tb, layer: "TITLEBLK", weight: .frame))

        let x0 = tb.x0
        let x1 = tb.x1
        let inset: Double = 2.6
        let width = tb.width - 2 * inset
        var y = tb.y1

        /// 各带的设计高度（在 A1 上就是这些值，总和 126mm）。
        /// 小纸上按比例压缩 —— 否则 A4 上 126mm 图签 + 66mm 说明栏
        /// 就已经超过可用高度 170mm，图例完全没地方放（实测重叠）。
        let designTotal: Double = 22 + 10 + 10 + 10 + 10 + 13 + 10 + 10 + 10 + 12 + 9
        let k = min(1.0, tb.height / designTotal)

        /// 一条横带。返回该带的可绘制矩形（自下而上）。
        func band(_ designHeight: Double) -> Rect {
            let height = designHeight * k
            let bottom = y - height
            let box = Rect(x0: x0, y0: bottom, x1: x1, y1: y)
            y = bottom
            line(Vec2(x0, y), Vec2(x1, y), "TITLEBLK")
            return box
        }

        // 1) 剧名 —— 图签里最大的一行
        var box = band(22)
        fittedText(doc.meta.show, at: Vec2(x0 + inset, box.y0 + 7.5 * k),
                   size: .show, maxWidth: width, layer: "TB_TEXT", family: .bold)

        // 2) 编剧
        box = band(10)
        fittedText(doc.meta.playwright, at: Vec2(x0 + inset, box.y0 + 3.2 * k),
                   size: .field, maxWidth: width, layer: "TB_TEXT")

        // 3–5) 场地 / 导演 / 设计师
        fieldBand("VENUE", doc.meta.venue, band(10), inset: 2.6)
        fieldBand("DIRECTOR", doc.meta.director, band(10), inset: 2.6)
        fieldBand("DESIGNER", doc.meta.designer, band(10), inset: 2.6)

        // 6) 图名
        box = band(13)
        fittedText(doc.meta.sheetTitle, at: Vec2(x0 + inset, box.y0 + 4.4 * k),
                   size: .subtitle, maxWidth: width, layer: "TB_TEXT", family: .bold)

        // 7) 比例
        box = band(10)
        // **必须报实际比例与实际纸张。**
        //
        // 早先写死 "1:25 @ A1" —— 打到 A0 或 A4 上都这么写。
        // 与说明栏那句是同一类错误，但这句藏在图签格里：
        // 早先的比例测试只查以 "SCALE 1:" 开头的行，正好漏过它。
        // （实现在 A4@1:100 的图上印着 "1:25 @ A1"，就是这么发现的。）
        fieldBand("SCALE",
                  "1:\(Int(layout.scaleDenominator)) @ \(layout.paper.name)",
                  box, inset: 2.6)

        // 8) 日期
        box = band(10)
        fieldBand("DATE", doc.meta.date, box, inset: 2.6)

        // 9) 版本
        box = band(10)
        fieldBand("REV", doc.meta.revision, box, inset: 2.6)

        // 10) 图号
        box = band(12)
        fieldBand("SHEET", "\(doc.meta.sheetNo) OF \(doc.meta.sheetOf)", box, inset: 2.6)

        // 11) 版本说明
        box = band(9)
        fittedText(doc.meta.revNote, at: Vec2(x0 + inset, box.y0 + 2.6 * k),
                   size: .micro, maxWidth: width, layer: "TB_TEXT")
    }

    /// "标签：值" 的窄栏版本。标签宽度按**真实字宽**算，不写死。
    ///
    /// 旧项目因为把标签列宽写死，换成 Arial 之后 `DIRECTOR` 和它的值重叠了。
    mutating func fieldBand(_ label: String, _ value: String, _ box: Rect,
                            inset: Double) {
        // 窄格里字段名 + 值会一起超出格子（实测 A4 上 "VENUE: STUDIO THEATRE"
        // 伸出图签右边界）。字段名本身也要限宽。
        let cap = Paper.FontSize.tbLabel.capMM
        let baseline = box.y0 + 3.4
        let labelCap = FontLibrary.regular.fitCapMM(label + ":",
                                                    capMM: cap,
                                                    maxWidthMM: box.width * 0.45,
                                                    minCapMM: 1.8)
        let labelText = label + ":"
        add(.text(TextOp(labelText, at: Vec2(box.x0 + inset, baseline),
                         capMM: labelCap, rotationDegrees: 0, align: .left,
                         layer: "TB_TEXT", family: .regular)))
        let labelWidth = FontLibrary.regular.widthMM(labelText, capMM: labelCap)
        let valueX = box.x0 + inset + labelWidth + 1.6
        let available = box.x1 - inset - valueX
        guard available > 4 else { return }

        let valueCap = FontLibrary.regular.fitCapMM(value,
                                                    capMM: Paper.FontSize.field.capMM,
                                                    maxWidthMM: available)
        add(.text(TextOp(value, at: Vec2(valueX, baseline),
                         capMM: valueCap, rotationDegrees: 0, align: .left,
                         layer: "TB_TEXT", family: .regular)))
    }

    /// "标签：值" 的一行。标签宽度按**真实字宽**算，不写死 ——
    /// 旧项目因为写死列宽，换字体后 `DIRECTOR` 和值重叠了。
    mutating func fieldRow(_ label: String, _ value: String, in box: Rect,
                           labelWidth: Double) {
        let cap = Paper.FontSize.tbLabel.capMM
        let labelText = label + ":"
        add(.text(TextOp(labelText, at: Vec2(box.x0 + 3, box.y0 + 4.0),
                         capMM: cap, rotationDegrees: 0, align: .left,
                         layer: "TB_TEXT", family: .regular)))
        // 标签实际宽度 = 字宽 × 字数…… 这里用真实度量，不用估算
        let measured = FontLibrary.regular.widthMM(labelText, capMM: cap)
        let valueX = box.x0 + 3 + max(labelWidth, measured + 1.5)
        let available = box.x1 - valueX - 2
        guard available > 4 else { return }
        let valueCap = FontLibrary.regular.fitCapMM(value, capMM: Paper.FontSize.field.capMM,
                                                    maxWidthMM: available)
        add(.text(TextOp(value, at: Vec2(valueX, box.y0 + 4.0),
                         capMM: valueCap, rotationDegrees: 0, align: .left,
                         layer: "TB_TEXT", family: .regular)))
    }

    /// 图签：右侧信息栏的栏宽（131mm），自下而上 11 条横带。
    static func titleBlockRect(for layout: SheetLayout) -> Rect {
        SheetLayout.titleBlockRect(for: layout)
    }

    static func legendRect(for layout: SheetLayout) -> Rect {
        SheetLayout.legendRect(for: layout)
    }

    // MARK: - 图例

    mutating func drawLegend() {
        let box = Self.legendRect(for: layout)

        // 空间不足就**整块省略**，并在说明栏写一句。
        // 挤成几行重叠的字比没有图例更糟：读图人会以为那些色号是乱码。
        guard box.height >= SheetLayout.legendMinimumHeight else {
            legendOmitted = true
            return
        }
        var y = box.y1

        text("FIXTURES", at: Vec2(box.x0, y - 4), size: .legendHeader,
             layer: "LEGEND", align: .left, family: .bold)
        y -= 8
        line(Vec2(box.x0, y), Vec2(box.x1, y), "LEGEND")

        // 只列**图上真的有灯**的类型。
        //
        // 早先遍历 `doc.types.keys`（整个类型表），于是 7 个类型全画，
        // 哪怕图上一台 profile 都没有。类型表吃掉 8 行（含表头）后，
        // 色片区只剩一行 —— 实测 kitchen 图例因此只剩 2 个色片、
        // 其余以 "1 more" 草草带过。图例是执行依据，不是类型字典。
        let counts = Dictionary(grouping: doc.fixtures, by: \.type)
            .mapValues(\.count)

        for key in doc.types.keys.sorted() where (counts[key] ?? 0) > 0 {
            guard y > box.y0 + 70 else { break }
            let type = doc.types[key]!
            let rowMid = y - 9

            // 符号（按图上的缩放画，让图例与正文大小一致）
            let polys = SymbolLibrary.polygons(for: key)
            if !polys.isEmpty {
                // 图例符号用独立图层。
                //
                // 早先它和台上的灯同为 "FIXTURE" —— 于是
                // "把符号多边形变换到图纸坐标验证朝向" 那类检查
                // 会把图例里的符号也采样进去，得到自相矛盾的结果
                // （实测 fresnel 的宽端判定被图例符号带反）。
                drawSymbol(polys, at: Vec2(box.x0 + 7, rowMid), aim: 0,
                           targetLong: 9.0, typeKey: key, layer: "LEGEND_SYM")
            }

            // 标签必须按**实际栏宽**取短名。
            //
            // 窄栏（A3 只有 61.7mm）上 "PROFILE  Profile / ERS 750W"
            // 宽 62mm —— 正好压住右侧计数和图纸分区字母（实测）。
            // 所以：能耗到计数就用全名，耗不到就退回短名（只写类型键）。
            // 图例的目的是让人对上号，不是列出完整产品名。
            // 三级退化：全名 → 短名 → 只留符号与计数。
            //
            // 纵向纸张的信息栏只有 40mm 出头（A3 portrait），
            // "FOLLOW" 在 3.5mm cap 下就有 13mm —— 减去符号与计数后
            // 放不下，于是压住右侧的计数（实测 'FOLLOW' x '2'）。
            let count = counts[key] ?? 0
            let countText = "\(count)"
            let roomMM = box.width - 18 - 5 - 1
            let full = "\(key.uppercased())  \(type.label)"
            let short = key.uppercased()
            var labelCap = Paper.FontSize.device.capMM
            var label: String? = FontFamily.regular.measuring
                .widthMM(full, capMM: labelCap) <= roomMM ? full : short
            if let l = label,
               FontFamily.regular.measuring.widthMM(l, capMM: labelCap) > roomMM {
                let fitted = labelCap * roomMM
                    / max(1e-6, FontFamily.regular.measuring.widthMM(l, capMM: labelCap)) * 0.98
                if fitted >= 2.0 { labelCap = fitted } else { label = nil }
            }
            if let label {
                add(.text(TextOp(label,
                                 at: Vec2(box.x0 + 18, rowMid + 1.4),
                                 capMM: labelCap, rotationDegrees: 0, align: .left,
                                 layer: "LEGEND", family: .regular)))
            }
            add(.text(TextOp(countText, at: Vec2(box.x1 - 2, rowMid + 1.4),
                             capMM: labelCap, rotationDegrees: 0, align: .right,
                             layer: "LEGEND", family: .regular)))
            // 行距固定 18mm。
            //
            // 曾试过"类型多时压缩到 13mm 给色片区让位"，结果把符号缩放
            // 也带偏了 —— 朝向检查随即失败（fresnel 宽端跑到了下方）。
            // 图例框已经改成用满图签上方的全部空间（见 legendRect），
            // 所以不需要再压行距。
            y -= 18
        }

        // ---- 场景说明（仅分场景图）
        if lightingState != nil, y > box.y0 + 30 {
            y -= 3
            text("DASHED = OFF IN THIS SCENE",
                 at: Vec2(box.x0, y), size: .micro, layer: "LEGEND", align: .left)
            y -= 7
        }

        // ---- 色片
        //
        // 间距要够：标题字高 3.51mm，若只减 4 再画在 y-4，
        // 上一段的最后一行会贴上来（实测压住 "COLOUR"）。
        guard y > box.y0 + 40 else { return }
        y -= 10
        text("COLOUR", at: Vec2(box.x0, y), size: .legendHeader,
             layer: "LEGEND", align: .left, family: .bold)
        y -= 6
        line(Vec2(box.x0, y), Vec2(box.x1, y), "LEGEND")
        y -= 2

        // 色片表。**必须全部画出来** —— 早期版本用 `guard y > box.y0` 提前 break，
        // 结果 8 个色片只画了 4 个，剩下的静默消失。
        // 图例少几行不会让图"看起来坏"，但会让读图人以为那些灯没有颜色。
        // 所以改成两列自动分栏：行数超过单列容量就换列。
        // 图例只列**这张图上真正用到**的色片。
        //
        // 分场景图尤其重要：kitchen 只用到少数几个色片，
        // 若把全表（8 个）都列出来，灯光师会以为还有别的色片要用。
        // 图例是执行依据，不是资料卡 —— 它必须与图面一致。
        // 图例只列**这张图上真正用到**的色片 —— 基础图也一样。
        //
        // 早先基础图列整本色库（45 项）。在小纸上那是灾难：
        // A3 的图例只有 105mm 高，45 个色片要 280mm，
        // 于是图例压住说明、比例尺、色片行互相叠（实测 15 处碰撞）。
        //
        // 更根本的理由：图例是**执行依据**，不是资料卡。
        // 列 45 个而只用 2 个，只会让装灯的人困惑。
        let usedCodes = lightingState.map { $0.usedGels(in: doc) }
            ?? Set(doc.fixtures.compactMap { $0.gel })
        let gels = doc.gels
            .filter { usedCodes.contains($0.code) }
            .sorted {
                // OPEN 排最前：它是"没装色片"的说明项，语义上属于第一行。
                // 排在字母序末尾（"OPEN" > "L…"）会被分栏截断吃掉 ——
                // 实测 kitchen 场景图例因此丢了 OPEN 那一项，
                // 于是 9 台 OPEN 灯在图上找不到解释。
                if $0.code == "OPEN" { return true }
                if $1.code == "OPEN" { return false }
                return $0.code < $1.code
            }

        // "OPEN" 必须保留：它表示"这不是色片，是没装色片"。
        // 若图上有灯用了 OPEN，图例不列它，操作员会找不到对应项。
        let needsOpen = usedCodes.contains("OPEN")
        let columnTop = y - 2
        let rowHeight: Double = 10.5
        let available = columnTop - box.y0
        let rowsPerColumn = max(1, Int(available / rowHeight))
        // 最多两列：栏宽 131mm，三列会把文字挤出图框。
        // 两列装不下时压缩行高，而不是继续加列。
        let maxColumns = 2
        let columns = min(maxColumns, max(1, (gels.count + rowsPerColumn - 1) / rowsPerColumn))
        let columnWidth = box.width / Double(columns)

        // 仍然装不下时截断，并明确写"N more" —— 静默丢弃最糟。
        //
        // 那行说明会**占掉底部一行的高度**，所以要先把这段高度让出来，
        // 否则它会压住最后一排色片（实测 A3 上 "2 more" 压 "L103 …"）。
        // 文字也要短：窄栏里 "N more in the gel library" 放不下，
        // "N more" 在任何幅面上都读得懂。
        let truncationText = "\(max(0, gels.count)) more"
        let hasTruncation = gels.count > 0
        let reserveForNote = hasTruncation ? rowHeight : 0
        let usable = max(rowHeight, available - reserveForNote)
        let maxRows = max(1, Int(usable / rowHeight)) * 2
        let shown = Array(gels.prefix(maxRows))
        let hidden = gels.count - shown.count
        if hidden > 0 {
            text("\(hidden) more", at: Vec2(box.x0, box.y0 + 1.6),
                 size: .micro, layer: "LEGEND", align: .left)
        }
        _ = needsOpen
        for (index, gel) in shown.enumerated() {
            let perColumn = (shown.count + columns - 1) / columns
            let column = index / perColumn
            let row = index % perColumn
            let cx = box.x0 + Double(column) * columnWidth
            // 行高按实际需要压缩，保证所有色片都落在图例框内
            let rowsThisColumn = max(1, (shown.count - column * perColumn) < perColumn
                                     ? shown.count - column * perColumn : perColumn)
            let effectiveRowHeight = min(rowHeight, available / Double(max(1, rowsThisColumn)))
            let mid = columnTop - Double(row) * effectiveRowHeight - effectiveRowHeight / 2

            let swatchH = min(4.4, effectiveRowHeight * 0.55)
            let swatch = Rect(x0: cx + 0.5, y0: mid - swatchH / 2,
                              x1: cx + 7.5, y1: mid + swatchH / 2)
            if let rgb = gel.rgb {
                add(.fillRect(swatch, rgb: rgb))
            }
            add(.strokeRect(swatch, layer: "LEGEND", weight: .hair))

            // 窄栏（A3 只有 61.7mm，两列后每列 30mm）里
            // "L132  Lee 132  Quarter CT Straw" 有 50mm —— 必然伸出图框。
            // 所以按实际列宽退化：放得下就用全名，放不下就只写色号。
            // 色号是执行时真正用的东西，全名只是方便认读。
            let cap = min(Paper.FontSize.color.capMM, effectiveRowHeight * 0.42)
            let full = "\(gel.code)  \(gel.name)"
            let room = columnWidth - 10 - 1.5
            let label = FontLibrary.regular.widthMM(full, capMM: cap) <= room
                ? full : gel.code
            add(.text(TextOp(label,
                             at: Vec2(cx + 10, mid),
                             capMM: cap, rotationDegrees: 0, align: .left,
                             layer: "LEGEND", family: .regular)))
        }
    }

    // MARK: - 说明与比例尺

    mutating func drawNotes() {
        let tb = Self.titleBlockRect(for: layout)
        let x = tb.x0
        var y = tb.y1 + 62

        // 说明文字必须**限宽到信息栏**。
        //
        // 不限宽时 "LANTERN POSITIONS SHOWN AT TRIM" 在 A3 上伸出 3mm，
        // 压住图框右侧的分区字母（实测 'D' x 那句话）。
        // 限宽会等比缩小该行的字号 —— 这与"不缩放图面"不冲突：
        // 缩的是说明文字，不是图纸。
        let maxWidth = tb.width - 2
        for note in Self.notes(for: doc, layout: layout) {
            // 三级退化：全名 → 短名 → 省略整行。
            //
            // 窄栏（A3 portrait 信息栏仅 40mm）里
            // "LANTERN POSITIONS SHOWN AT TRIM" 缩到最小字号仍有 40mm，
            // 会伸出图框压住分区字母（实测 'D' 压那句话）。
            // 只缩字号是不够的 —— 必须允许换用短句或直接不写。
            var line: String? = nil
            if Self.fitsWidth(note.full, size: .micro, maxWidth: maxWidth) {
                line = note.full
            } else if Self.fitsWidth(note.short, size: .micro, maxWidth: maxWidth) {
                line = note.short
            }
            if let line {
                text(line, at: Vec2(x, y), size: .micro,
                     layer: "NOTES", align: .left)
            }
            y -= 4.4
        }

        // 图例被省略时补一句（此处而不是图例里，避免与说明栏重叠）
        if legendOmitted,
           Self.fitsWidth("LEGEND OMITTED - SEE SCHEDULE", size: .micro, maxWidth: maxWidth) {
            text("LEGEND OMITTED - SEE SCHEDULE", at: Vec2(x, y), size: .micro,
                 layer: "NOTES", align: .left)
            y -= 4.4
        }


        drawScaleBar(at: Vec2(x, y - 8))
    }

    /// 比例尺：1 米（图纸上 = 1000 / 比例）。
    mutating func drawScaleBar(at origin: Vec2) {
        let metre = len(1000)
        let h: Double = 2.2
        let bar = Rect(x0: origin.x, y0: origin.y, x1: origin.x + metre, y1: origin.y + h)
        add(.strokeRect(bar, layer: "LEGEND", weight: .hair))
        // 交替填黑，读图时不用数格子
        let half = metre / 2
        add(.fillRect(Rect(x0: origin.x, y0: origin.y, x1: origin.x + half, y1: origin.y + h),
                      rgb: Paper.blackRGB))
        for (i, label) in ["0", "0.5", "1 m"].enumerated() {
            text(label, at: Vec2(origin.x + half * Double(i), origin.y - 3.2),
                 size: .micro, layer: "LEGEND")
        }
    }

    /// 图纸说明栏。
    ///
    /// **必须报实际纸张与实际比例。** 早先硬编码 "ON A1"、用
    /// `doc.meta.scale` —— 于是打到 A3@1:50 的图上仍写 "1:25 ON A1"。
    /// 一张印错比例的图比没有图更危险：装灯的人会照它量。
    /// 一行说明：`full` 是标准写法，`short` 是窄栏备用。
    struct Note {
        let full: String
        let short: String
    }

    /// 该字符串在给定字号下能否放进给定宽度。
    static func fitsWidth(_ s: String, size: Paper.FontSize,
                          maxWidth: Double) -> Bool {
        FontLibrary.regular.widthMM(s, capMM: size.capMM) <= maxWidth
    }

    static func notes(for doc: LXDocument, layout: SheetLayout) -> [Note] {
        var lines = [
            Note(full: "SCALE 1:\(Int(layout.scaleDenominator)) ON \(layout.paper.name)",
                 short: "SCALE 1:\(Int(layout.scaleDenominator))"),
            Note(full: "ALL DIMENSIONS IN MILLIMETRES",
                 short: "ALL DIMS IN MM"),
            Note(full: "DO NOT SCALE FROM THIS DRAWING",
                 short: "DO NOT SCALE"),
            Note(full: "LANTERN POSITIONS SHOWN AT TRIM",
                 short: "POSITIONS AT TRIM"),
            Note(full: "STAGE \(Int(doc.stage.width)) x \(Int(doc.stage.depth))  GRID +\(Int(doc.stage.gridHeight))",
                 short: "STAGE \(Int(doc.stage.width))x\(Int(doc.stage.depth))"),
        ]
        if doc.stage.prosceniumHeight > 0 {
            lines.append(Note(
                full: "PROSCENIUM OPENING +\(Int(doc.stage.prosceniumHeight))",
                short: "PROSC +\(Int(doc.stage.prosceniumHeight))"))
        }
        return lines
    }
}
