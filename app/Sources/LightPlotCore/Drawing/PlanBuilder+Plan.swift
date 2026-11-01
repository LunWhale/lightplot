import Foundation

// MARK: - 图纸内容（舞台、观众席、布景、光区、构件、灯具）

extension PlanCanvas {

    // MARK: 观众席

    /// 观众席。行数/排距来自数据，不再硬编码 —— 换场地时图要跟着变。
    mutating func drawAudience() {
        let rows = max(0, doc.stage.audienceRows)
        guard rows > 0 else { return }

        let rowPitch = doc.stage.audienceRowDepth
        let cols = 12
        let colPitch: Double = 760
        let seatHalfW: Double = 290
        let seatHalfD: Double = 210

        for r in 0..<rows {
            // 第一排中心距台沿半个排距，整块观众席正好贴住台口。
            let y = -(Double(r) + 0.5) * rowPitch
            // 越往后越窄，形成轻微的扇形 —— 参考图就是这个梯形
            let halfSpan = 4200 - Double(r) * 220
            for c in 0..<cols {
                let x = -4200 + Double(c) * colPitch
                guard abs(x) <= halfSpan - seatHalfW else { continue }
                let a = s(x - seatHalfW, y - seatHalfD)
                let b = s(x + seatHalfW, y + seatHalfD)
                rect(Rect(x0: a.x, y0: a.y, x1: b.x, y1: b.y), "SEAT")
            }
        }

        // 最后一行之后的走道线 + 标注（留在图框内）
        let aisleY = -Double(rows) * rowPitch
        line(s(-4200, aisleY), s(4200, aisleY), "SEAT")
        text("AUDIENCE / FOH", at: s(-4200, aisleY) + Vec2(2.0, -3.4),
             size: .subtitle, layer: "SEAT", align: .left)
    }

    // MARK: 舞台

    mutating func drawStage() {
        let w = doc.stage.width
        let d = doc.stage.depth
        let half = w / 2

        poly([s(-half, 0), s(-half, d), s(half, d), s(half, 0)], "STAGE", closed: true)
        line(s(-half, 0), s(half, 0), "STAGE")
        text("STAGE EDGE", at: s(0, -420), size: .color, layer: "STAGE")

        // 台口线（如果有）
        if doc.stage.prosceniumX < 0 || doc.stage.prosceniumX > 0 {
            let px = doc.stage.prosceniumX
            line(s(px, 0), s(px, doc.stage.prosceniumHeight), "STAGE", dash: [6.0, 2.0, 0.8, 2.0])
        }
    }

    // MARK: 布景

    mutating func drawSetPieces() {
        for piece in doc.setPieces {
            switch piece.kind {
            case .line:
                let a = s(piece.x0, piece.y0)
                let b = s(piece.x1, piece.y1)
                line(a, b, "SET")
                if let label = piece.label, !label.isEmpty {
                    text(label, at: (a + b) * 0.5 + Vec2(0, 2.2),
                         size: .color, layer: "SET", mask: true)
                }

            case .rect:
                let r = docRectToSheet(piece.rect)
                // 白底先铺，再描边：布景内部不该有桁架线穿过去
                maskRect(r)
                rect(r, piece.dashed == true ? "SET_DASH" : "SET")
                if let label = piece.label, !label.isEmpty {
                    // 虚框（上层平台）标签放下边线外侧；实体布景放更下方，
                    // 让开灯位标注 —— 照抄参考图的实测偏移。
                    let dy = piece.dashed == true ? -2.6 : -7.2
                    text(label, at: Vec2(r.center.x, r.y0 + dy),
                         size: .color, layer: "SET", mask: true)
                }

            case .stair:
                drawStair(piece)
            }
        }
    }

    /// 楼梯：只画两条侧边 + 踏步线 + UP 箭头，**不封口**。
    ///
    /// 早期画成"矩形外框 + 平行线"，看起来像一排座位。
    /// 楼梯是斜向上的，封口就变成了一个盒子。
    mutating func drawStair(_ piece: SetPiece) {
        let steps = max(1, piece.steps ?? 12)
        let r = docRectToSheet(piece.rect)

        // 两条侧边
        line(Vec2(r.x0, r.y0), Vec2(r.x0, r.y1), "SET")
        line(Vec2(r.x1, r.y0), Vec2(r.x1, r.y1), "SET")

        // 踏步线
        for i in 1..<steps {
            let y = r.y0 + r.height * Double(i) / Double(steps)
            line(Vec2(r.x0, y), Vec2(r.x1, y), "SET")
        }

        // UP 箭头
        let midX = r.center.x
        let arrowTop = r.y1 - r.height * 0.12
        let arrowBottom = r.y0 + r.height * 0.12
        line(Vec2(midX, arrowBottom), Vec2(midX, arrowTop), "SET")
        line(Vec2(midX, arrowTop), Vec2(midX - 1.2, arrowTop - 1.8), "SET")
        line(Vec2(midX, arrowTop), Vec2(midX + 1.2, arrowTop - 1.8), "SET")

        if let label = piece.label, !label.isEmpty {
            text(label, at: Vec2(r.center.x, r.y0 - 2.6), size: .color,
                 layer: "SET", mask: true)
        }
    }

    // MARK: 光区

    mutating func drawZones() {
        for zone in doc.zones {
            let r = docRectToSheet(zone.rect)
            rect(r, "ZONE", dash: Dash.dashDot)
            // 标签贴框内左上角，但必须留在**安全区**里 ——
            // 否则大光区的左上角会跑到图框分区带上，压住分区号（实测 K 压 2）。
            let safe = inner.inset(by: 12)
            let lx = max(r.x0 + 3.0, safe.x0)
            // 文字是**垂直居中**于给定点的，所以只内缩 3mm 不够：
            // cap 高 7mm 时上半截会穿过光区顶边（实测 "K2" 被线划断）。
            //
            // 关键是先取**两个上界里更低的那个**再内缩，而不是各自 min 之后再内缩。
            // 早先写成 `min(r.y1 - 3 - cap/2, safe.y1)`：当安全区上界比光区
            // 顶边更高时，钳位结果正好贴在光区顶线上，标签仍被线划断。
            let cap = Paper.FontSize.position.capMM
            let topLimit = min(r.y1, safe.y1)
            let ly = topLimit - 3.0 - cap / 2
            text(zone.id, at: Vec2(lx, ly),
                 size: .position, layer: "ZONE", align: .left, mask: true)
        }
    }

    // MARK: 构件

    mutating func drawPositions() {
        for position in doc.positions.sorted(by: { $0.id < $1.id }) {
            guard let shape = position.shape else { continue }
            let start = s(shape.start)
            let end = s(shape.end)
            let scale = layout.scaleDenominator

            switch position.type {
            case .truss:
                let cell = Paper.TrussSpec.pitchOnSheet(scale: scale)
                for poly in TrussGeometry.polygons(from: start, to: end, cellWidth: cell) {
                    add(.fillStroke(points: poly.points, fill: Paper.whiteRGB,
                                    layer: poly.layer, weight: .truss))
                }

            case .pipe:
                let height = Paper.PipeSpec.heightOnSheet(scale: scale)
                if let pipe = PipeGeometry.polygon(from: start, to: end, height: height) {
                    add(.fillStroke(points: pipe.points, fill: Paper.whiteRGB,
                                    layer: pipe.layer, weight: .truss))
                }

            case .line:
                // 非吊挂构件：只画一条细线。
                // 用桁架画布景边缘会让人误读成"第四根灯杆"。
                line(start, end, "SET")
            }

            // 标高位置按构件朝向分开放。
            //
            // 横杆：左端下方。右端是 BOOM 的地盘，会撞。
            // 竖杆：**顶端上方**。底端紧挨着 BOOM 上的第一台灯，
            //   标高会压住它的色片号 —— 实测 A0@1:50 上
            //   '+3600' 压 'L119'，然后避让器把色片号丢掉了。
            //   **丢色片是执行错误**（装片的人会装错），
            //   所以必须让标高让路，而不是让色片让路。
            if position.type != .line, let trim = position.trim {
                let half = position.halfHeightOnSheet(scale: scale)
                switch position.kind {
                case .vertical:
                    // 横向夹进图面内：BOOM 贴在图框边，
                    // 居中的标高会伸进分区字母带（实测 '+3600' 压 'J'）。
                    let area = SheetLayout.planArea(paper: layout.paper)
                    let labelCap = Paper.FontSize.dim.capMM
                    let w = FontLibrary.regular.widthMM("+\(Int(trim))",
                                                        capMM: labelCap)
                    let x = min(max(start.x, area.x0 + 6 + w / 2),
                                area.x1 - 6 - w / 2)
                    text("+\(Int(trim))", at: Vec2(x, end.y + half + 3.4),
                         size: .dim, layer: "DIM", align: .center, mask: true)
                case .horizontal:
                    text("+\(Int(trim))", at: Vec2(start.x + 2.0, start.y - half - 3.4),
                         size: .dim, layer: "DIM", align: .left, mask: true)
                }
            }

            // 构件名：沿构件旋转，放在最宽的空档里 ——
            // 不这么做的话名字会压在灯具标注块上（旧项目踩过）。
            if position.type != .line {
                drawPositionName(position, shape: shape, start: start, end: end)
            }
        }
    }

    mutating func drawPositionName(_ position: Position, shape: PositionShape,
                                   start: Vec2, end: Vec2) {
        let cap = Paper.FontSize.component.capMM
        let width = FontLibrary.regular.widthMM(position.id, capMM: cap)
        let half = position.halfHeightOnSheet(scale: layout.scaleDenominator)

        // 灯具在杆上的位置（沿杆偏移，图纸 mm）
        let occupied = Resolver.fixtures(on: position.id, in: doc)
            .map { len($0.offset) }
            .sorted()
        let span = len(shape.length)

        // 找最宽空档
        var gaps: [(Double, Double)] = []
        var cursor: Double = 0
        for off in occupied where off > cursor {
            gaps.append((cursor, off))
            cursor = max(cursor, off)
        }
        gaps.append((cursor, span))
        let best = gaps.max { ($0.1 - $0.0) < ($1.1 - $1.0) }

        let along: Double
        if let best, best.1 - best.0 > width + 4 {
            along = (best.0 + best.1) / 2
        } else {
            along = span / 2
        }

        let dir = (end - start).normalized ?? Vec2(1, 0)
        let normal = Vec2(-dir.y, dir.x)
        var at = start + dir * along + normal * (half + 1.6)
        // 构件名不能跑到图框分区带里 —— 竖直构件的名字尤其容易撞上分区字母
        // （实测 BOOM SL 压住分区 I）。
        let safe = inner.inset(by: 13)
        at = Vec2(at.x.clamped(to: safe.x0...safe.x1),
                  at.y.clamped(to: safe.y0...safe.y1))
        let angle = dir.angleDegrees

        // 文字永远不上下颠倒
        let rotation = (angle > 90 || angle < -90) ? angle + 180 : angle
        add(.text(TextOp(position.id, at: at, capMM: cap,
                         rotationDegrees: rotation, align: .center,
                         layer: "TRUSS", family: .regular)))
    }

    // MARK: 灯具

    mutating func drawFixtures() {
        let targetLong: Double = 11.2       // 参考图实测：符号长轴在图纸上的长度

        for (fixture, mount) in Resolver.allMounts(in: doc) {
            guard let world = mount.worldPoint else { continue }
            let at = s(world)
            let aim = fixture.aim ?? 90

            // 场景状态下显示**实际用的色片**（替换后的），而不是基础色片。
            // 否则分场景平面图会印错色号 —— 那是最致命的一类错误：
            // 图看起来正常，灯光师按图装片却装错。
            let shownGel = lightingState?.gel(for: fixture) ?? fixture.gelCode

            // 场景里强度 0 的灯画**虚轮廓** ——
            // 制图惯例：这张图上不工作的东西用虚线。
            // 否则分场景图会把全台灯都画成实线，操作员以为全都要开。
            let isDark = lightingState.map { $0.level(for: fixture) <= 0 } ?? false

            let polys = SymbolLibrary.polygons(for: fixture.type)
            let bounds = drawSymbol(polys, at: at, aim: aim,
                                    targetLong: targetLong,
                                    typeKey: fixture.type,
                                    dashed: isDark)

            // ---- 标注：通道号在左（圆圈），色片号与灯号在右
            //
            // 偏移量必须按**符号旋转后的真实包围盒**算，不能用符号长轴的一半：
            // fresnel 在 aim=90 时是竖着放的，半宽只有 2mm，
            // 而长轴的一半是 5.6mm —— 用长轴算会把标注推到很远，
            // 用固定的 3.8mm 又会压住符号（旧项目踩过这个坑）。
            // 标注避让：用符号**包围盒**而不是旋转后的窄边。
            // 三角（practical）在尖端附近宽度趋近 0，
            // 只按宽度算会让 "OPEN/901" 的 O 压在三角尖上（实测）。
            let halfW = (bounds.map { max($0.width, $0.height) } ?? targetLong) / 2
            let r = Paper.FontSize.unit.capMM * Paper.markRadiusFactor
            let gap: Double = 1.6

            // 标注默认在符号右侧（色片号 + 灯号），通道圆圈在左侧。
            // 但最右边的 BOOM（x≈±8.1m）离图例栏只有几毫米 ——
            // 标注向右会伸进图例里（实测 "603" 压住 "COLOUR"）。
            // 制图惯例：外侧放不下就翻到内侧。
            let gelCap = Paper.FontSize.color.capMM
            let unitCap = Paper.FontSize.unit.capMM
            let labelText = shownGel ?? "OPEN"
            let unitText = String(fixture.unit)
            let labelW = max(FontLibrary.regular.widthMM(labelText, capMM: gelCap),
                             FontLibrary.regular.widthMM(unitText, capMM: unitCap))
            let area = SheetLayout.planArea(paper: layout.paper)
            let flip = at.x + halfW + gap + labelW > area.x1 - 1.0

            // 翻转时整个标注块（标签 + 圆圈）都移到符号左侧，
            // 否则圆圈会顶到图例栏（实测 "53" 压住 "COLOUR"）。
            let chX = flip
                ? at.x - halfW - gap - labelW - gap - r
                : at.x - halfW - r - gap
            let chText = fixture.ch.map { String($0) } ?? "-"
            add(.fillCircle(center: Vec2(chX, at.y), radius: r, rgb: Paper.whiteRGB))
            add(.circle(center: Vec2(chX, at.y), radius: r, layer: "MARK", weight: .fine))
            add(.text(TextOp(chText, at: Vec2(chX, at.y), capMM: Paper.FontSize.unit.capMM,
                             rotationDegrees: 0, align: .center,
                             layer: "MARK", family: .regular)))

            // 两行字的中心距 = 两个 cap 的一半 + 行距，保证不挨在一起
            let lineGap = (gelCap + unitCap) / 2 + 0.9
            if flip {
                let leftX = at.x - halfW - gap
                text(labelText, at: Vec2(leftX, at.y + lineGap), size: .color,
                     layer: "FIXTURE_TXT", align: .right, mask: true)
                text(unitText, at: Vec2(leftX, at.y - lineGap), size: .unit,
                     layer: "FIXTURE_TXT", align: .right, mask: true)
                _ = leftX
            } else {
                let rightX = at.x + halfW + gap
                text(labelText, at: Vec2(rightX, at.y + lineGap), size: .color,
                     layer: "FIXTURE_TXT", align: .left, mask: true)
                text(unitText, at: Vec2(rightX, at.y - lineGap), size: .unit,
                     layer: "FIXTURE_TXT", align: .left, mask: true)
            }
        }
    }

    /// 画一个灯具符号。
    ///
    /// 三件事必须同时正确，否则整排灯就是错的：
    ///  1. **缩放**：符号长轴在图纸上 = `targetLong`（参考图实测 11.2mm）
    ///  2. **旋转**：GDTF 符号的镜片在 **-Y**，所以 `rotation = aim + 90`。
    ///     旧代码按 +Y 当前方算成 `aim - 90`，结果全台灯反了 180°、对着观众。
    ///  3. **白底**：符号体是实心白块，桁架线在它的轮廓处断开。
    @discardableResult
    mutating func drawSymbol(_ polys: [[Vec2]], at: Vec2,
                             aim: Double, targetLong: Double,
                             typeKey: String = "",
                             dashed: Bool = false,
                             layer: String = "FIXTURE") -> Rect? {
        guard let all = Rect(points: polys.flatMap { $0 }), all.width > 0 || all.height > 0 else {
            return nil
        }
        let long = max(all.width, all.height)
        guard long > 1e-6 else { return nil }
        let sc = targetLong / long
        let rotation = FixtureOrientation.rotation(for: typeKey, aim: aim)

        var transformed: [[Vec2]] = []
        for poly in polys {
            let pts = poly.map { p -> Vec2 in
                let scaled = Vec2(p.x * sc, p.y * sc)
                return at + scaled.rotated(byDegrees: rotation)
            }
            transformed.append(pts)
        }

        // 先铺全部白底，再描全部轮廓 ——
        // 否则后一个多边形的白底会盖住前一个的描边。
        for pts in transformed {
            add(.fill(points: pts, rgb: Paper.whiteRGB))
        }
        for pts in transformed {
            add(.stroke(points: pts, closed: true, layer: layer,
                        weight: .symbol,
                        dash: dashed ? [0.9, 0.7] : nil))
        }

        return Rect(points: transformed.flatMap { $0 })
    }

    // MARK: 尺寸标注

    mutating func drawDimensions() {
        let half = doc.stage.width / 2
        let y = doc.stageBounds.y0 - 1600

        dimension(from: Vec2(-half, y), to: Vec2(half, y),
                  offset: 900, label: "\(Int(doc.stage.width))")
        dimension(from: Vec2(-half - 1400, 0), to: Vec2(-half - 1400, doc.stage.depth),
                  offset: -900, label: "\(Int(doc.stage.depth))")
    }

    /// 线性尺寸：引出线 + 尺寸线 + 端部斜杠 + 数值。
    ///
    /// 用斜杠而不是箭头 —— 建筑/舞台图纸的惯例，而且在小尺寸下更清楚。
    mutating func dimension(from a: Vec2, to b: Vec2, offset: Double, label: String) {
        let dir = (b - a).normalized ?? Vec2(1, 0)
        let normal = Vec2(-dir.y, dir.x)
        let da = a + normal * offset
        let db = b + normal * offset

        // 引出线（略微越过尺寸线）
        line(s(a), s(a + normal * (offset * 1.12)), "DIM")
        line(s(b), s(b + normal * (offset * 1.12)), "DIM")
        // 尺寸线
        line(s(da), s(db), "DIM")
        // 端部斜杠
        let tick = dir * 0.45 + normal * 0.45
        line(s(da) - tick, s(da) + tick, "DIM")
        line(s(db) - tick, s(db) + tick, "DIM")
        // 数值
        let mid = (da + db) * 0.5
        let angle = dir.angleDegrees
        var rotation = (angle > 90 || angle < -90) ? angle + 180 : angle
        if abs(rotation) < 1e-9 { rotation = 0 }
        text(label, at: s(mid + normal * 1.6), size: .dim, layer: "DIM",
             rotation: rotation, mask: true)
    }

    // MARK: 场景标签

    /// 分场景平面图时，在图纸区左上角标出场景名。
    ///
    /// 没有它，三张平面图（基础 / kitchen / boston）看起来一模一样 ——
    /// 打印出来分不清哪张是哪场，而它们的色片与强度是不同的。
    mutating func drawStateBanner() {
        guard let state = lightingState else { return }
        // 位置：图纸区左上角，但必须避开图框分区带。
        //
        // 分区刻度在图框内侧 3mm、分区数字再往里 3.4mm —— 横幅若贴到
        // area.y1 就会压住顶部的 "1" "2"（实测被抓到）。
        // 所以从内框往内多让 12mm。
        let area = SheetLayout.planArea(paper: layout.paper)
        let cap = Paper.FontSize.position.capMM
        let label = state.act.isEmpty
            ? state.name
            : "\(state.act)  -  \(state.name)"
        let safeTop = layout.innerFrame.y1 - 12
        let at = Vec2(area.x0 + 5, min(area.y1 - 7, safeTop))

        let box = FontLibrary.bold.textBox(label, at: at, capMM: cap, align: .left)
        add(.fillRect(box.inset(by: -1.8), rgb: Paper.whiteRGB))
        ops.append(.text(TextOp(label, at: at, capMM: cap, rotationDegrees: 0,
                                align: .left, layer: "NOTES", family: .bold)))

    }

    /// 密度警示横幅：标注放不下时，在图纸区顶部横一条白底黑字。
    ///
    /// **不能塞进说明栏。** 说明栏只有 60 多毫米宽，而这句警示
    /// 有 70mm 以上，塞进去会伸出图框（实测）。放在图纸区里既有位置，
    /// 也更显眼 —— 这类"图能出但读不了"的问题必须一眼可见。
    mutating func drawDensityBanner() {
        guard let text = densityNote else { return }
        let area = SheetLayout.planArea(paper: layout.paper)
        let cap = Paper.FontSize.position.capMM * 0.8

        // 场景横幅占了左上角，密度警示放到它下面，避免两者相撞。
        let top = layout.innerFrame.y1 - 12
            - (lightingState == nil ? 0 : 9)
        let at = Vec2(area.x0 + 5, min(area.y1 - 7, top))

        let box = FontLibrary.bold.textBox(text, at: at, capMM: cap, align: .left)
        add(.fillRect(box.inset(by: -2.0), rgb: Paper.whiteRGB))
        add(.strokeRect(box.inset(by: -2.0), layer: "NOTES", weight: .hair))
        ops.append(.text(TextOp(text, at: at, capMM: cap, rotationDegrees: 0,
                                align: .left, layer: "NOTES", family: .bold)))
    }

    // MARK: 辅助

    func docRectToSheet(_ r: Rect) -> Rect {
        let a = s(r.x0, r.y0)
        let b = s(r.x1, r.y1)
        return Rect(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }
}
