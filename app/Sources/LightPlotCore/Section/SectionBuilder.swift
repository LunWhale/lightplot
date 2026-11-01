import Foundation

/// 剖面图构建器：把文档排成 A3 剖面图纸的绘制指令。
///
/// 与平面图共用 `DrawOp` 与 `SheetPDF`，所以只有一套渲染后端。
/// 剖面图的**信息密度比平面图高得多**，这也是它必须独立成模块的原因：
///   · 场地剖面（台面、台口、栅顶、马道、后墙）
///   · 观众席起坡 + 视线检查
///   · 布景剖面（按 A-A 切线投影）
///   · 吊挂位置（端面）+ 灯具 + 真实光束包络
///   · 光束遮挡判定
///   · 人形比例参照
///   · 右栏：说明 / 标高表 / 视线表 / 图签
public enum SectionBuilder {

    public static func build(doc: LXDocument, layout: SectionLayout,
                             lightingState: LightingState? = nil) -> [DrawOp] {
        var c = SectionCanvas(doc: doc, layout: layout,
                              lightingState: lightingState)

        c.drawVenue()
        c.drawAudienceAndSightlines()
        c.drawSetPieces()
        c.drawBoomPositions()
        c.drawHorizontalPositions()
        c.drawHumanFigure()
        c.drawCutMarker()
        c.drawFrame()
        c.drawPanels()
        return c.ops
    }
}

struct SectionCanvas {
    let doc: LXDocument
    let layout: SectionLayout
    /// 当前场景状态。nil = 基础剖面。
    var lightingState: LightingState?
    var ops: [DrawOp] = []

    init(doc: LXDocument, layout: SectionLayout,
         lightingState: LightingState? = nil) {
        self.doc = doc
        self.layout = layout
        self.lightingState = lightingState
    }

    /// 中线切线纵深。
    var cutDepth: Double { doc.sectionCutDepth }

    /// (纵深, 高度) → 纸张。
    func s(_ depth: Double, _ height: Double) -> Vec2 {
        layout.toSheet(depth: depth, height: height)
    }

    func len(_ d: Double) -> Double { layout.sheetLength(d) }

    // MARK: 基础

    mutating func line(_ a: Vec2, _ b: Vec2, _ layer: String, dash: [Double]? = nil) {
        let spec = Paper.layer(layer)
        ops.append(.stroke(points: [a, b], closed: false, layer: layer,
                           weight: spec.weight,
                           dash: dash ?? Dash.pattern(layerSpec: spec)))
    }

    mutating func poly(_ pts: [Vec2], _ layer: String, closed: Bool = false,
                       dash: [Double]? = nil) {
        let spec = Paper.layer(layer)
        ops.append(.stroke(points: pts, closed: closed, layer: layer,
                           weight: spec.weight,
                           dash: dash ?? Dash.pattern(layerSpec: spec)))
    }

    mutating func mask(_ pts: [Vec2]) {
        ops.append(.fill(points: pts, rgb: Paper.whiteRGB))
    }

    mutating func text(_ string: String, at p: Vec2, size: Paper.FontSize,
                       layer: String = "NOTES", align: TextAlign = .center,
                       rotation: Double = 0, family: FontFamily = .regular,
                       mask: Bool = false) {
        if mask {
            let box = family.measuring.textBox(string, at: p, capMM: size.capMM,
                                               align: align, rotationDegrees: rotation,
                                               pad: 0.3)
            ops.append(.fillRect(box, rgb: Paper.whiteRGB))
        }
        ops.append(.text(TextOp(string, at: p, capMM: size.capMM,
                                rotationDegrees: rotation, align: align,
                                layer: layer, family: family)))
    }

    mutating func fittedText(_ string: String, at p: Vec2, size: Paper.FontSize,
                              maxWidth: Double, layer: String = "NOTES",
                              align: TextAlign = .left,
                              family: FontFamily = .regular) {
        let cap = family.measuring.fitCapMM(string, capMM: size.capMM,
                                           maxWidthMM: maxWidth)
        ops.append(.text(TextOp(string, at: p, capMM: cap,
                                rotationDegrees: 0, align: align,
                                layer: layer, family: family)))
    }

    // MARK: 场地

    mutating func drawVenue() {
        let v = doc.stage
        let sd = v.depth
        let grid = v.gridHeight
        let prosH = v.prosceniumHeight
        let prosX = v.prosceniumX

        // 台面
        line(s(0, 0), s(sd, 0), "STAGE")
        // 台唇 + 台口台阶
        poly([s(0, 0), s(prosX, 0), s(prosX, -180), s(-600, -180), s(-600, -900)], "STAGE")
        // 后墙 + 栅顶
        line(s(sd, 0), s(sd, grid), "STAGE")
        line(s(prosX - 900, grid), s(sd, grid), "STAGE")
        // 台口塔与门头
        line(s(prosX, 0), s(prosX, prosH), "STAGE")
        line(s(prosX, prosH), s(prosX - 350, prosH), "STAGE")
        line(s(prosX - 350, prosH), s(prosX - 350, grid), "STAGE")

        // PROSCENIUM 标签放在台口线的**中段**，不是顶端。
        //
        // 放顶端会撞上构件名：一根 trim 恰好等于台口高的桁架，
        // 它的名字就在同一高度（实测 'PROSCENIUM' x 'LX 1'）。
        // 中段通常是空的 —— 构件都在各自的 trim 上，不在半空。
        text("PROSCENIUM", at: s(prosX - 175, prosH * 0.45), size: .micro,
             layer: "DIM", rotation: 90)

        // 马道
        for (frac, tag) in [(0.45, "CATWALK 1"), (0.82, "CATWALK 2")] {
            let cy = sd * frac
            line(s(cy, 4200), s(cy + 1200, 4200), "STAGE")
            line(s(cy, 4200), s(cy, 5000), "STAGE")
            line(s(cy + 1200, 4200), s(cy + 1200, 5000), "STAGE")
            text(tag, at: s(cy + 600, 5250), size: .micro, layer: "DIM")
        }

        // 标高标尺
        let rulerDepth = prosX - 1500
        var h = 0.0
        while h <= grid {
            let a = s(rulerDepth, h)
            let b = s(rulerDepth, h) + Vec2(2.4, 0)
            line(a, b, "DIM")
            text("+\(Int(h))", at: a + Vec2(-0.9, 0), size: .micro,
                 layer: "DIM", align: .right)
            h += 1000
        }
        line(s(rulerDepth, 0), s(rulerDepth, grid), "DIM")

        // 场地标注
        text("STAGE FLOOR  +/-0  (VERTICAL ZERO)", at: s(sd * 0.55, -420),
             size: .color, layer: "DIM", mask: true)
        text("BACK WALL", at: s(sd - 260, grid * 0.60), size: .micro,
             layer: "DIM", rotation: 90)
        text("GRID", at: s(sd * 0.55, grid + 220), size: .micro, layer: "DIM")
        text("UPSTAGE", at: s(sd - 900, grid + 700), size: .color, layer: "DIM")
        text("DOWNSTAGE", at: s(prosX + 600, grid + 700), size: .color, layer: "DIM")
    }

    // MARK: 观众席与视线

    mutating func drawAudienceAndSightlines() {
        let v = doc.stage
        let rows = v.audienceRows
        guard rows > 0 else { return }
        let rowDepth = v.audienceRowDepth
        let rake = v.audienceRake
        let firstRow = -Double(rows) * rowDepth

        let leftLimit = layout.drawingArea.x0 + 2

        var drawn = 0
        for i in 0..<rows {
            let depth = firstRow - Double(i) * rowDepth
            // 超出绘图区就不画（不裁掉图框，只是不越界）
            guard s(depth - rowDepth, 0).x >= leftLimit else { break }
            let floor = Double(i) * rake
            let nextFloor = Double(i + 1) * rake

            // 踏步
            line(s(depth, floor), s(depth - rowDepth, floor), "SEAT")
            line(s(depth - rowDepth, floor), s(depth - rowDepth, nextFloor), "SEAT")
            // 座椅
            poly([s(depth - 60, floor), s(depth - 460, floor),
                  s(depth - 460, floor + 90), s(depth - 60, floor + 90)],
                 "SEAT", closed: true)
            drawn += 1
        }

        // 视线：每排眼睛 → 台口底边。被前座挡住的那几排用红色强调。
        let sights = SectionGeometry.sightLines(
            rowCount: rows, rowDepth: rowDepth, rake: rake,
            firstRowDepth: firstRow,
            plasterDepth: v.prosceniumX)

        for sight in sights {
            let floor = Double(sight.row) * rake
            let eye = s(sight.eyeDepth, floor + SectionGeometry.seatedEyeHeight)
            let target = s(0, 0)
            // 视线只在绘图区内画，避免冲出图框
            guard eye.x >= leftLimit else { continue }
            let blocked = !sight.seesStageFloor
            if let seg = clipToArea(from: eye, to: target) {
                ops.append(.stroke(points: [seg.0, seg.1], closed: false,
                                   layer: blocked ? "ACCENT" : "SEAT",
                                   weight: blocked ? .fine : .hair,
                                   dash: blocked ? [1.2, 1.0] : [0.8, 1.6]))
            }
        }

        text("AUDIENCE", at: s(firstRow - Double(drawn) * rowDepth * 0.5, -560),
             size: .color, layer: "SEAT")
    }

    // MARK: 布景

    mutating func drawSetPieces() {
        for piece in doc.setPieces {
            let height = doc.sectionHeight(of: piece)
            switch piece.kind {
            case .rect, .stair:
                // 剖切判定：切线穿过这块布景才画成实线剖面
                let crossed = piece.y0 <= cutDepth && cutDepth <= piece.y1
                let near = abs((piece.y0 + piece.y1) / 2 - cutDepth) < 1200
                guard crossed || near else { continue }

                let layer = crossed ? "SET" : "SET_DASH"
                let d0 = crossed ? cutDepth : (piece.y0 + piece.y1) / 2
                // 剖到的画成实线剖面；没剖到的只画一小段虚线提示（不是整根墙）
                let top = crossed ? height : min(height, 400)
                line(s(d0, 0), s(d0, top), layer,
                     dash: crossed ? nil : Dash.dashed)
                if crossed {
                    line(s(d0 - 120, height), s(d0 + 120, height), layer)
                }

                if crossed, let label = piece.label, !label.isEmpty {
                    // 标签放在顶面**右侧**，而不是正上方 ——
                    // 正上方会撞到灯具与光束。
                    text(label, at: s(d0, height) + Vec2(2.2, 1.2), size: .micro,
                         layer: "SET", align: .left, mask: true)
                    text("+\(Int(height))", at: s(d0, height) + Vec2(2.2, -1.8),
                         size: .micro, layer: "DIM", align: .left, mask: true)
                }

            case .line:
                let crossed = abs(piece.y0 - cutDepth) < 300
                    || abs(piece.y1 - cutDepth) < 300
                let near = abs((piece.y0 + piece.y1) / 2 - cutDepth) < 2000
                guard crossed || near else { continue }
                let d = crossed ? (abs(piece.y0 - cutDepth) < abs(piece.y1 - cutDepth)
                                  ? piece.y0 : piece.y1)
                                : (piece.y0 + piece.y1) / 2
                line(s(d, 0), s(d, height), crossed ? "SET" : "SET_DASH",
                     dash: crossed ? nil : Dash.dashed)
                if let label = piece.label, !label.isEmpty {
                    text(label, at: s(d, height * 0.82) + Vec2(1.6, 0),
                         size: .micro, layer: "SET", align: .left, mask: true)
                }
            }
        }
    }

    // MARK: 位置与灯具

    /// 横向吊杆：在剖面上是一个端面 + 灯具 + 光束。
    mutating func drawHorizontalPositions() {
        let sd = doc.stage.depth
        // 焦点按位置性质分配 —— 全都打中区会让光束交叉成一团。
        let focusByID: [String: Double] = [
            "FOH LX": sd * 0.22,
            "LX 1":   sd * 0.38,
            "LX 2":   sd * 0.62,
            "LX 3":   sd * 0.88,
        ]

        // 遮挡物：布景、台口塔、观众席台阶
        let blockers = doc.setPieces.compactMap { piece -> SectionGeometry.Blocker? in
            guard piece.kind == .rect || piece.kind == .line else { return nil }
            let h = doc.sectionHeight(of: piece)
            let d0 = piece.kind == .line ? piece.y0 : piece.y0
            let d1 = piece.kind == .line ? piece.y1 : piece.y1
            guard d1 > 0 else { return nil }
            return .init(Rect(x0: d0, y0: 0, x1: d1, y1: h),
                         piece.label ?? piece.kind.rawValue)
        }

        for position in doc.positions where position.kind == .horizontal {
            guard let trim = position.trim, let depth = position.y else { continue }
            let halfWidth = len(400) / 2

            // 桁架端面
            let top = s(depth, trim)
            let box = Rect(x0: top.x - halfWidth, y0: top.y - 0.5,
                           x1: top.x + halfWidth, y1: top.y + 0.5)
            ops.append(.fillStroke(points: [Vec2(box.x0, box.y0), Vec2(box.x1, box.y0),
                                            Vec2(box.x1, box.y1), Vec2(box.x0, box.y1)],
                                   fill: Paper.whiteRGB, layer: "TRUSS", weight: .truss))

            // 构件名放在端面**左上方**并对齐右端，避免与右侧的标高数字撞在一起。
            // 剖面图比平面图密，构件名用小一档（.field 3.70mm 而不是 .position 6.09mm）——
            // 用 .position 会让"FOH LX"横跨半个台口，压住 PROSCENIUM 线。
            let nameCap = FontLibrary.regular.fitCapMM(
                position.id, capMM: Paper.FontSize.field.capMM, maxWidthMM: 20)
            ops.append(.text(TextOp(position.id,
                                    at: top + Vec2(-halfWidth - 1.4, 2.2),
                                    capMM: nameCap, rotationDegrees: 0,
                                    align: .right, layer: "FIXTURE_TXT",
                                    family: .regular)))
            text("+\(Int(trim))", at: top + Vec2(halfWidth + 3.0, -0.8),
                 size: .unit, layer: "DIM", align: .left, mask: true)

            let fixtures = Resolver.fixtures(on: position.id, in: doc)
            guard !fixtures.isEmpty else { continue }

            let shown = min(fixtures.count, 6)
            let defaultFocus = focusByID[position.id] ?? sd * 0.5

            // 一台代表性灯具的剖面轮廓（1:50 下约 3.5 × 5 mm）。
            // 不再为每台灯画一个 1mm 小方块 —— 1:50 下那是 0.02mm，
            // 渲染出来就是一串看不见的点。
            let bodyW: Double = 1.6
            let bodyH: Double = 2.6
            let yokeH: Double = 1.1
            // 场景里整根杆 0% 时，本体画虚线 —— 与平面图同一套语法：
            // 这张图上不工作的东西不画实线。
            let barDark = lightingState.map { st in
                st.level(forPosition: position.id) <= 0
            } ?? false
            poly([Vec2(top.x - bodyW, top.y - yokeH),
                  Vec2(top.x - bodyW, top.y - yokeH - bodyH),
                  Vec2(top.x + bodyW, top.y - yokeH - bodyH),
                  Vec2(top.x + bodyW, top.y - yokeH)],
                 "FIXTURE", closed: true,
                 dash: barDark ? [0.9, 0.7] : nil)
            // 镜筒（朝下）
            line(Vec2(top.x - bodyW * 0.55, top.y - yokeH - bodyH),
                 Vec2(top.x - bodyW * 0.55, top.y - yokeH - bodyH - 0.8), "FIXTURE")
            line(Vec2(top.x + bodyW * 0.55, top.y - yokeH - bodyH),
                 Vec2(top.x + bodyW * 0.55, top.y - yokeH - bodyH - 0.8), "FIXTURE")

            // 数量（超过 1 台时标出来，否则读图人以为只有一台）
            if fixtures.count > 1 {
                text("x\(fixtures.count)", at: Vec2(top.x + bodyW + 1.4,
                                                     top.y - yokeH - bodyH * 0.5),
                     size: .micro, layer: "FIXTURE_TXT", align: .left, mask: true)
            }

            for i in 0..<shown {
                let apexPaper = Vec2(top.x, top.y - yokeH - bodyH - 0.8)
                let apex = Vec2(depth, trim)

                // 只画边界灯的光束，否则 6 条锥叠成乱线
                guard i == 0 || i == shown - 1 || shown <= 2 else { continue }
                let fixture = fixtures[i].fixture

                // 场景里关掉的灯**不画光束** —— 画了就是误导：
                // 厨房那场 LX 2 是 0，剖面上却有一片光，读图人会以为它亮着。
                if let st = lightingState, st.level(for: fixture) <= 0 { continue }
                let beam = fixture.beam ?? 26
                var focus = fixture.focusDepth ?? defaultFocus
                focus = max(200, min(focus, sd - 200))

                let env = SectionGeometry.envelope(
                    apex: apex,
                    focusDepth: focus,
                    focusHeight: 0,
                    beamAngle: beam,
                    reach: abs(focus - depth) * 1.15 + 600)

                // 包络两条边：从灯口到各自终点，**裁剪到绘图区**。
                // 不裁剪的话光束会画到纸外 —— 剖面图上锥体很容易超出图框。
                let e = env.endpoints
                for tip in [e.0, e.1] {
                    if let seg = clipToArea(from: apexPaper + Vec2(0, -1.6),
                                            to: s(tip.x, tip.y)) {
                        line(seg.0, seg.1, "BEAM")
                    }
                }

                // 焦点处的光斑宽度（这是"这盏灯照多宽"的可读答案）
                if let slice = env.slice(atDepth: focus) {
                    let a = s(focus, slice.low)
                    let b = s(focus, slice.high)
                    line(Vec2(a.x, a.y), Vec2(b.x, b.y), "BEAM")
                    // 光斑宽度标签：**每个位置只标一次**。
                    //
                    // 同一位置有左右两台边界灯，它们焦点纵深相同、
                    // 光束角相同 → 光斑宽度与横向位置完全一样。
                    // 标两次就是在同一坐标上叠字（实测 bbox 一模一样）。
                    // 只标左边界灯，语义也更清楚：这是"该位置的光斑宽度"。
                    if i == 0 {
                        let row = Double(positionIndex(position.id))
                        let labelY = a.y + 2.8 + row * 3.2
                        text("\(Int(slice.width))", at: Vec2((a.x + b.x) / 2, labelY),
                             size: .micro, layer: "DIM", mask: true)
                    }
                }

                // 遮挡
                if let hit = SectionGeometry.blockage(env, by: blockers) {
                    text("BLOCKED \(Int(hit.depth))", at: s(hit.depth, 200),
                         size: .micro, layer: "ACCENT", mask: true)
                }
            }
        }
    }

    /// 竖直 BOOM：中心线剖面切不到它们，画成虚线并注明 BEYOND CUT。
    mutating func drawBoomPositions() {
        let booms = doc.positions.filter { $0.kind == .vertical }
        guard let first = booms.first else { return }
        let midDepth = ((first.y0 ?? 0) + (first.y1 ?? 0)) / 2
        let trim = booms.compactMap(\.trim).max() ?? 3600

        line(s(midDepth, 0), s(midDepth, trim), "TRUSS", dash: Dash.dashed)
        poly([s(midDepth - 350, 0), s(midDepth + 350, 0),
              s(midDepth + 350, 120), s(midDepth - 350, 120)], "TRUSS", closed: true)

        let names = booms.map(\.id).joined(separator: " / ")
        text("\(names)  (BEYOND CUT)",
             at: s(midDepth + 500, trim + 300), size: .micro,
             layer: "DIM", align: .left)
    }

    // MARK: 人形

    /// 1.75m 人形比例参照。没有它，剖面图的尺度感是不可读的。
    mutating func drawHumanFigure() {
        let depth = doc.stage.depth * 0.42
        let h = 1750.0
        let base = s(depth, 0)
        let k = len(h)
        let headR = len(h) * 0.13 / 1.75 * 1.0

        ops.append(.fillCircle(center: base + Vec2(0, k - headR), radius: headR,
                               rgb: Paper.whiteRGB))
        ops.append(.circle(center: base + Vec2(0, k - headR), radius: headR,
                           layer: "DIM", weight: .fine))
        // 躯干
        line(base + Vec2(0, 0), base + Vec2(0, k - headR * 2), "DIM")
        // 肩
        poly([base + Vec2(-0.16 * k, 0.62 * k), base + Vec2(0, 0.74 * k),
              base + Vec2(0.16 * k, 0.62 * k)], "DIM")
        // 腿
        line(base + Vec2(0, 0.05 * k), base + Vec2(-0.09 * k, 0), "DIM")
        line(base + Vec2(0, 0.05 * k), base + Vec2(0.09 * k, 0), "DIM")

        text("1.75m", at: base + Vec2(0.12 * k, k + 1.0), size: .micro,
             layer: "DIM", align: .left)
    }

    // MARK: 剖切线标记

    /// 剖切标记。
    ///
    /// 早先画的是"一条线 + 一个 A 字"，那个 A 既压在观众席图形上，
    /// 又和图框分区字母 A/B 撞在一起（`Section text layout` 测试抓到的）。
    /// 现在改成 USITT 惯用的**剖切箭头 + 空心三角**，而且整体沉到
    /// 绘图区下方、纸边与内框之间的留白里，不与任何内容抢位置。
    mutating func drawCutMarker() {
        let area = layout.drawingArea
        // 位置：绘图区下沿与内框之间的留白带里。
        //
        // 分区号在 y ≈ innerFrame + 6.4（cap 4.55 居中在 innerFrame+3.4 上方），
        // 所以符号必须压在 y ≤ innerFrame + 3，并且 x 要避开分区号的横向范围
        // （分区号在每格中心，即 area.x0 往右约 40mm 才到第一个）。
        // 实测两轮：先撞分区号，再撞其基线 —— 现在两者都让开。
        let y = Paper.frameInner + 3.2
        let x0 = area.x0 + 2
        let x1 = x0 + 11

        // 视线方向箭头
        line(Vec2(x0, y), Vec2(x1, y), "ACCENT")
        line(Vec2(x1, y), Vec2(x1 - 2.6, y + 1.5), "ACCENT")
        line(Vec2(x1, y), Vec2(x1 - 2.6, y - 1.5), "ACCENT")

        // 空心三角（USITT RP-2 的剖切符号）
        let tri = [Vec2(x0 - 2.4, y - 1.8), Vec2(x0 - 2.4, y + 1.8),
                   Vec2(x0, y)]
        poly(tri, "ACCENT", closed: true)

        // 字母放在箭头左侧，小一号，避免与分区号抢位置
        text("A", at: Vec2(x0 - 4.4, y), size: .micro, layer: "ACCENT",
             align: .right, mask: true)
    }

    // MARK: 图框

    mutating func drawFrame() {
        let outer = Rect(x0: Paper.frameMargin, y0: Paper.frameMargin,
                         x1: layout.paper.widthMM - Paper.frameMargin,
                         y1: layout.paper.heightMM - Paper.frameMargin)
        let inner = Rect(x0: Paper.frameInner, y0: Paper.frameInner,
                         x1: layout.paper.widthMM - Paper.frameInner,
                         y1: layout.paper.heightMM - Paper.frameInner)
        ops.append(.strokeRect(outer, layer: "BORDER", weight: .frame))
        ops.append(.strokeRect(inner, layer: "BORDER", weight: .frame))

        // 分区刻度（A3 用 8 格）
        let cols = 8, rows = 6
        let tick = 3.0
        for i in 0...cols {
            let x = inner.x0 + inner.width * Double(i) / Double(cols)
            line(Vec2(x, inner.y0), Vec2(x, inner.y0 + tick), "BORDER")
            line(Vec2(x, inner.y1), Vec2(x, inner.y1 - tick), "BORDER")
            if i < cols {
                let cx = x + inner.width / Double(cols) / 2
                // 右侧面板栏所在区间不画分区数字 ——
                // 面板就长在那里，数字会压住 NOTES / TRIM SCHEDULE 的标题
                // （实测剖面图上的 '7' '8' 落在面板栏内）。
                // 与平面图用同一条规则：基准带止于面板左边界。
                if cx < SectionLayout.panelLeft(for: layout.paper) - 2 {
                    text("\(i + 1)", at: Vec2(cx, inner.y1 - tick - 3.4),
                         size: .border, layer: "GRIDTEXT")
                    text("\(i + 1)", at: Vec2(cx, inner.y0 + tick + 3.4),
                         size: .border, layer: "GRIDTEXT")
                }
            }
        }
        for j in 0...rows {
            let y = inner.y0 + inner.height * Double(j) / Double(rows)
            line(Vec2(inner.x0, y), Vec2(inner.x0 + tick, y), "BORDER")
            line(Vec2(inner.x1, y), Vec2(inner.x1 - tick, y), "BORDER")
            if j < rows {
                let cy = y + inner.height / Double(rows) / 2
                let letter = j < 26 ? String(UnicodeScalar(65 + j)!) : "\(j + 1)"
                text(letter, at: Vec2(inner.x0 + tick + 3.4, cy),
                     size: .border, layer: "GRIDTEXT", rotation: 90)
                text(letter, at: Vec2(inner.x1 - tick - 3.4, cy),
                     size: .border, layer: "GRIDTEXT", rotation: 90)
            }
        }

        // 图名（分场景时带场景名，否则三张剖面看起来一样）
        let cx = layout.drawingArea.center.x
        var title = "SECTION A-A"
        if let st = lightingState {
            title += "  -  " + (st.act.isEmpty ? st.name : "\(st.act)  \(st.name)")
        }
        text(title, at: Vec2(cx, layout.paper.heightMM - 34),
             size: .subtitle, layer: "TB_TEXT", family: .bold)
        text("SECTION A-A  LOOKING SL  /  SCALE 1:\(Int(layout.scaleDenominator)) @ \(layout.paper.name)",
             at: Vec2(cx, layout.paper.heightMM - 41),
             size: .micro, layer: "DIM")
    }

    // MARK: 右栏

    mutating func drawPanels() {
        // 右栏必须完全落在内框以内，并给分区数字留位置。
        // A3 内框 20..400，分区刻度内侧 3mm、数字再往里 3.4mm ——
        // 所以右栏右边界不能超过 400 - 9 = 391。
        // 与 SectionLayout 共用同一组常量 —— 早先两处各写一遍，
        // 绘图区边界与栏起点差 3mm，光束画进了图例里。
        let W = SectionLayout.panelWidth
        let X = SectionLayout.panelLeft(for: layout.paper)
        let innerTop = layout.paper.heightMM - Paper.frameInner - 9
        let innerBottom = Paper.frameInner + 9

        func box(_ y0: Double, _ y1: Double, _ title: String) {
            ops.append(.strokeRect(Rect(x0: X, y0: y0, x1: X + W, y1: y1),
                                   layer: "TITLEBLK", weight: .frame))
            if !title.isEmpty {
                text(title, at: Vec2(X + 2, y1 - 4), size: .legendHeader,
                     layer: "TB_TEXT", align: .left, family: .bold)
            }
        }

        // ---- 说明
        let notesTop = innerTop
        let notesBottom = notesTop - 76
        box(notesBottom, notesTop, "NOTES")
        var y = notesTop - 9
        let notes = [
            "1. Section on centreline, looking SL.",
            "2. Vertical zero = stage floor.",
            "3. Horizontal zero = plaster line.",
            "4. Trim measured floor to BOTTOM OF PIPE.",
            "5. Beam cones at nominal angle, edge to edge.",
            "6. Human figure 1.75m (USITT RP-2).",
            "7. Dashed lantern = beyond the cut.",
            "8. Red dashed sightline = blocked.",
        ]
        for note in notes {
            for line in wrap(note, width: W - 4, cap: Paper.FontSize.micro.capMM) {
                guard y > notesBottom + 2 else { break }
                text(line, at: Vec2(X + 2, y), size: .micro, layer: "NOTES", align: .left)
                y -= 3.4
            }
            y -= 1.2
        }

        // ---- 标高表
        let trimTop = notesBottom - 2
        let trimBottom = trimTop - 42
        box(trimBottom, trimTop, "TRIM SCHEDULE")
        let cols: [(String, Double)] = [("POSITION", 2), ("TRIM", 30), ("TYPE", 46)]
        for (t, ox) in cols {
            text(t, at: Vec2(X + ox, trimTop - 10), size: .micro, layer: "TB_TEXT", align: .left)
        }
        line(Vec2(X + 2, trimTop - 12), Vec2(X + W - 2, trimTop - 12), "NOTES")
        for (i, p) in doc.positions.prefix(6).enumerated() {
            let yy = trimTop - 16 - Double(i) * 4.4
            guard yy > trimBottom + 2 else { break }
            text(p.id, at: Vec2(X + 2, yy), size: .micro, layer: "NOTES", align: .left)
            text(p.trim.map { "+\(Int($0))" } ?? "-",
                 at: Vec2(X + 30, yy), size: .micro, layer: "NOTES", align: .left)
            text(p.type.rawValue, at: Vec2(X + 46, yy), size: .micro,
                 layer: "NOTES", align: .left)
        }

        // ---- 视线表（剖面图独有，也是最有价值的自查）
        let sightTop = trimBottom - 2
        let sightBottom = sightTop - 46
        box(sightBottom, sightTop, "SIGHTLINES")
        let sights = SectionGeometry.sightLines(
            rowCount: doc.stage.audienceRows,
            rowDepth: doc.stage.audienceRowDepth,
            rake: doc.stage.audienceRake,
            firstRowDepth: -Double(doc.stage.audienceRows) * doc.stage.audienceRowDepth,
            plasterDepth: doc.stage.prosceniumX)
        let blocked = sights.filter { !$0.seesStageFloor }
        if sights.isEmpty {
            text("no audience", at: Vec2(X + 2, sightTop - 12), size: .micro,
                 layer: "NOTES", align: .left)
        } else if blocked.isEmpty {
            text("all rows see the stage floor",
                 at: Vec2(X + 2, sightTop - 12), size: .micro,
                 layer: "NOTES", align: .left)
        } else {
            let worst = blocked.min { $0.margin < $1.margin } ?? blocked[0]
            text("\(blocked.count) of \(sights.count) rows blocked",
                 at: Vec2(X + 2, sightTop - 12), size: .micro,
                 layer: "ACCENT", align: .left)
            text("worst row \(worst.row + 1): \(Int(worst.margin)) mm",
                 at: Vec2(X + 2, sightTop - 17), size: .micro,
                 layer: "ACCENT", align: .left)
            text("raise rake or re-seat", at: Vec2(X + 2, sightTop - 22),
                 size: .micro, layer: "NOTES", align: .left)
        }

        // ---- 图签
        let tbTop = sightBottom - 2
        let tbBottom = innerBottom
        box(tbBottom, tbTop, "")
        let cx = X + W / 2
        var ty = tbTop - 6
        fittedText(doc.meta.show, at: Vec2(X + 2, ty),
                   size: .subtitle, maxWidth: W - 4,
                   layer: "TB_TEXT", family: .bold)
        ty -= 5
        fittedText(doc.meta.playwright, at: Vec2(X + 2, ty),
                   size: .micro, maxWidth: W - 4, layer: "TB_TEXT")
        ty -= 4
        line(Vec2(X + 2, ty), Vec2(X + W - 2, ty), "NOTES")
        ty -= 4

        fittedText(doc.meta.venue, at: Vec2(X + 2, ty),
                   size: .micro, maxWidth: W - 4, layer: "TB_TEXT")
        ty -= 4.6
        fittedText("LIGHTING SECTION", at: Vec2(X + 2, ty),
                   size: .field, maxWidth: W - 4, layer: "TB_TEXT", family: .bold)
        ty -= 4
        line(Vec2(X + 2, ty), Vec2(X + W - 2, ty), "NOTES")
        ty -= 5

        let fields: [(String, String)] = [
            ("DESIGNER", doc.meta.designer),
            ("DIRECTOR", doc.meta.director),
            ("SCALE", "1:\(Int(layout.scaleDenominator)) @ A3"),
            ("DATE", doc.meta.date),
            ("SHEET", "\(doc.meta.sheetNoSection) OF \(doc.meta.sheetOf)"),
            ("REV", doc.meta.revision),
        ]
        for (k, v) in fields {
            guard ty > tbBottom + 4 else { break }
            text(k, at: Vec2(X + 2, ty), size: .micro, layer: "TB_TEXT", align: .left)
            fittedText(v, at: Vec2(X + 22, ty), size: .micro,
                       maxWidth: W - 24, layer: "TB_TEXT")
            ty -= 4.2
        }
        let legal = "(C) 2026 - ISSUE FOR PRODUCTION"
        let legalCap = FontLibrary.regular.fitCapMM(
            legal, capMM: Paper.FontSize.micro.capMM, maxWidthMM: W - 3)
        ops.append(.text(TextOp(legal, at: Vec2(cx, tbBottom + 3.4),
                                capMM: legalCap, rotationDegrees: 0,
                                align: .center, layer: "TB_TEXT",
                                family: .regular)))
    }

    /// 构件在文档里的稳定序号（用于错开标签）。
    func positionIndex(_ id: String) -> Int {
        doc.positions
            .filter { $0.kind == .horizontal }
            .sorted { $0.id < $1.id }
            .firstIndex { $0.id == id } ?? 0
    }

    // MARK: 裁剪

    /// 把一条线段裁到绘图区内。返回 nil 表示整条落在区外。
    ///
    /// 用 Liang–Barsky 的参数化裁剪 —— 逐点判断会漏掉"两端在外、中间在内"的段。
    func clipToArea(from a: Vec2, to b: Vec2) -> (Vec2, Vec2)? {
        let area = layout.drawingArea
        var t0 = 0.0, t1 = 1.0
        let dx = b.x - a.x, dy = b.y - a.y

        func clip(_ p: Double, _ q: Double) -> Bool {
            if abs(p) < 1e-12 { return q >= 0 }
            let r = q / p
            if p < 0 {
                if r > t1 { return false }
                if r > t0 { t0 = r }
            } else {
                if r < t0 { return false }
                if r < t1 { t1 = r }
            }
            return true
        }

        guard clip(-dx, a.x - area.x0), clip(dx, area.x1 - a.x),
              clip(-dy, a.y - area.y0), clip(dy, area.y1 - a.y) else { return nil }
        guard t1 - t0 > 1e-6 else { return nil }
        return (Vec2(a.x + dx * t0, a.y + dy * t0),
                Vec2(a.x + dx * t1, a.y + dy * t1))
    }

    // MARK: 折行

    /// 按真实字宽折行。
    ///
    /// 右栏只有 62mm 宽，一条说明放不下一整行。用固定字数折行会在
    /// 窄体/宽体混排时溢出，所以必须按字宽度量。
    func wrap(_ text: String, width: Double, cap: Double) -> [String] {
        let m = FontLibrary.regular
        var out: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            let trial = current.isEmpty ? String(word) : current + " " + word
            if m.widthMM(trial, capMM: cap) > width && !current.isEmpty {
                out.append(current)
                current = String(word)
            } else {
                current = trial
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// 剖面图成品。
public struct SectionSheet: Sendable {
    public let doc: LXDocument
    public let layout: SectionLayout
    public let ops: [DrawOp]
    /// 文字避让结果。
    public let textFit: TextFitter.Result

    public init(doc: LXDocument, layout: SectionLayout,
                lightingState: LightingState? = nil) {
        self.doc = doc
        self.layout = layout
        // 剖面图同样要过文字避让 —— 小比例下"标高 + 每排灯具计数"
        // 会叠在一起（实测 A0@1:100 上 '+7200' 压 'x8'）。
        // 与平面图共用同一个避让器，避免两套规则漂移。
        let fit = TextFitter.run(
            SectionBuilder.build(doc: doc, layout: layout,
                                 lightingState: lightingState))
        self.ops = fit.ops
        self.textFit = fit
    }

    /// 用预渲染指令构造（溢出提示页走这条路）。
    public init(preRenderedDoc doc: LXDocument, layout: SectionLayout, ops: [DrawOp]) {
        self.doc = doc
        self.layout = layout
        self.ops = ops
        self.textFit = TextFitter.Result(ops: ops, dropped: [:])
    }

    /// 自动版面：比例锁死 1:50，只移动原点居中。
    ///
    /// **装不下时不静默出图** —— 与平面图同一策略：
    /// 输出一张带说明的提示页，而不是一张跑了内容的空白纸。
    public init(fitting doc: LXDocument, paper: PaperSize = .a3) {
        self.init(fitting: doc, paper: paper, scale: 50)
    }

    /// 分场景剖面图：关掉的灯不画光束，本体画虚线。
    public init(fitting doc: LXDocument, paper: PaperSize, scale: Double,
                lightingState: LightingState?) {
        let content = doc.sectionContentBounds
        let layout = SectionLayout.fitted(content: content, paper: paper,
                                          scaleDenominator: max(1, scale))
        if layout.contentFits(content) {
            self.init(doc: doc, layout: layout, lightingState: lightingState)
        } else {
            self = SectionSheet.overflowNotice(doc: doc, layout: layout)
        }
    }

    /// 指定纸幅**与比例**（多页图纸集用：每页自己的设置）。
    public init(fitting doc: LXDocument, paper: PaperSize, scale: Double) {
        let content = doc.sectionContentBounds
        let layout = SectionLayout.fitted(content: content, paper: paper,
                                          scaleDenominator: max(1, scale))
        if layout.contentFits(content) {
            self.init(doc: doc, layout: layout)
        } else {
            self = SectionSheet.overflowNotice(doc: doc, layout: layout)
        }
    }

    /// 剖面图装不下时的提示页。
    public static func overflowNotice(doc: LXDocument,
                                      layout: SectionLayout) -> SectionSheet {
        let paper = layout.paper
        let content = doc.sectionContentBounds
        let area = layout.drawingArea
        let regular = FontLibrary.regular
        var ops: [DrawOp] = []

        ops.append(.strokeRect(Rect(x0: Paper.frameMargin, y0: Paper.frameMargin,
                                    x1: paper.widthMM - Paper.frameMargin,
                                    y1: paper.heightMM - Paper.frameMargin),
                               layer: "BORDER", weight: .frame))
        ops.append(.strokeRect(Rect(x0: Paper.frameInner, y0: Paper.frameInner,
                                    x1: paper.widthMM - Paper.frameInner,
                                    y1: paper.heightMM - Paper.frameInner),
                               layer: "BORDER", weight: .frame))

        let centre = Vec2(area.center.x, area.center.y)
        func note(_ text: String, _ dy: Double, cap capMM: Double,
                  bold: Bool = false) {
            let fitted = regular.fitCapMM(text, capMM: capMM,
                                          maxWidthMM: area.width * 0.92)
            ops.append(.text(TextOp(text, at: Vec2(centre.x, centre.y + dy),
                                    capMM: fitted, rotationDegrees: 0,
                                    align: .center, layer: "NOTES",
                                    family: bold ? .bold : .regular)))
        }

        // A3 比 A1 小，字号也相应小一档，但仍要显著大于正常图面字号。
        // 行距 > 字号，否则两行重叠。
        note("THE SECTION DOES NOT FIT", 36, cap: 12, bold: true)
        note("ON \(layout.paper.name) AT 1:\(Int(layout.scaleDenominator))",
             20, cap: 12, bold: true)
        note(String(format: "Depth %.1f m, height %.1f m",
                    content.width / 1000, content.height / 1000),
             0, cap: 6)
        note(String(format: "This sheet holds %.1f x %.1f m at 1:%.0f",
                    area.width * layout.scaleDenominator / 1000,
                    area.height * layout.scaleDenominator / 1000,
                    layout.scaleDenominator),
             -9, cap: 6)
        note("Reduce the stage, or use a smaller scale.", -22, cap: 6)

        return SectionSheet(preRenderedDoc: doc, layout: layout, ops: ops)
    }

    public var contentFitsSheet: Bool {
        layout.contentFits(doc.sectionContentBounds)
    }

    public var textCount: Int { ops.reduce(0) { $1.isText ? $0 + 1 : $0 } }
    public var polygonCount: Int { ops.reduce(0) { $1.isPolygon ? $0 + 1 : $0 } }

    /// 视线检查结果（供 UI 与自检使用）。
    public var sightLines: [SectionGeometry.SightLine] {
        SectionGeometry.sightLines(
            rowCount: doc.stage.audienceRows,
            rowDepth: doc.stage.audienceRowDepth,
            rake: doc.stage.audienceRake,
            firstRowDepth: -Double(doc.stage.audienceRows) * doc.stage.audienceRowDepth,
            plasterDepth: doc.stage.prosceniumX)
    }
}
