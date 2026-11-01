import SwiftUI
import LightPlotCore

/// 画布 —— 把 `[DrawOp]` 画到屏幕上。
///
/// **这是整个 UI 层唯一有绘制逻辑的地方。**
/// 它不生成几何、不做吸附、不改文档；它只在缩放到当前视口时把指令画出来。
/// 这个边界让内核可以被完全无头测试，而画布本身只负责"看起来对不对"。
public struct SheetCanvas: View {
    let sheet: PlanSheet
    let viewport: Viewport
    let selection: Selection
    let showBeams: Bool
    let hoverPosition: String?

    /// 自动适配：忽略传入的 zoom/pan，按画布**自身真实尺寸**拟合整张图纸。
    ///
    /// 为什么需要这个开关：SwiftUI 里视图的最终尺寸只有在 `Canvas` 的闭包里
    /// 才是确定的。模型侧算出的 pan 基于"它以为的画布尺寸"，一旦两者不一致
    /// （布局中间态、检查器挤压、分屏），图纸就会偏心甚至被裁掉半边。
    /// 让画布在**绘制那一刻**用真实尺寸做拟合，这一整类问题就不存在了。
    let autoFit: Bool
    /// 吸附预览（拖动时显示"会吸到这里"）。
    let snapPreview: EditorModel.SnapPreview?
    /// 画布尺寸（点）。**由父级显式传入**，不在绘制闭包里回读并改状态 ——
    /// 在 `Canvas` 的 draw 闭包里修改 @Published 会破坏 SwiftUI 的更新周期，
    /// 实测表现为"尺寸永远停在第一次的中间值"。
    let canvasSize: Vec2

    public init(sheet: PlanSheet, viewport: Viewport, selection: Selection,
                showBeams: Bool = true, hoverPosition: String? = nil,
                autoFit: Bool = false,
                canvasSize: Vec2 = Vec2(1000, 700),
                snapPreview: EditorModel.SnapPreview? = nil) {
        self.sheet = sheet
        self.viewport = viewport
        self.selection = selection
        self.showBeams = showBeams
        self.hoverPosition = hoverPosition
        self.autoFit = autoFit
        self.canvasSize = canvasSize
        self.snapPreview = snapPreview
    }

    public var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            // ★ 尺寸只认绘制闭包给的 `size` —— 那是这一刻屏幕上真实的像素点尺寸。
            //   父级传来的 canvasSize 只在非 autoFit 时用于对齐模型状态。
            let real = Vec2(size.width, size.height)
            var vp = viewport
            vp.sizePoints = real
            if autoFit {
                vp = Viewport(zoom: 1, pan: .zero, sizePoints: real)
                    .fitted(to: sheet.layout.outerFrame, padding: 20)
            }

            drawPaper(in: &context, viewport: vp)
            drawOps(in: &context, viewport: vp)
            drawSelection(in: &context, viewport: vp)
            drawHover(in: &context, viewport: vp)
            drawSnap(in: &context, viewport: vp)
        }
        // 不加 .drawingGroup()：它会强制离屏渲染，使 Canvas 的尺寸协商
        // 按"内容建议尺寸"进行（实测塌到 161pt 高）。
        // 我们的实体数量在几百这个量级，直接绘制完全够快。
        .background(Color(nsColorLike: 0xF2F2F4))
    }

    // MARK: 纸张

    private func drawPaper(in context: inout GraphicsContext, viewport vp: Viewport) {
        // 纸面与阴影：让"图纸"和"桌面"分开，用户一眼看出边界在哪
        let frame = sheet.layout.outerFrame
        let topLeft = vp.toView(Vec2(frame.x0, frame.y1))
        let bottomRight = vp.toView(Vec2(frame.x1, frame.y0))
        let rect = CGRect(x: topLeft.x, y: topLeft.y,
                          width: bottomRight.x - topLeft.x,
                          height: bottomRight.y - topLeft.y)

        context.fill(Path(rect.offsetBy(dx: 2, dy: 3)), with: .color(.black.opacity(0.10)))
        context.fill(Path(rect), with: .color(.white))
        context.stroke(Path(rect), with: .color(.black.opacity(0.25)), lineWidth: 1)

        // 纸张之外压暗，视线自然收在图纸上
        var outside = Path(CGRect(origin: .zero, size: vp.sizePoints.cgSize))
        outside.addRect(rect)
        context.fill(outside, with: .color(.black.opacity(0.06)), style: FillStyle(eoFill: true))
    }

    // MARK: 指令

    private func drawOps(in context: inout GraphicsContext, viewport vp: Viewport) {
        let visible = vp.visibleSheetRect.inset(by: -40)

        for op in sheet.ops {
            switch op {
            case .stroke(let points, let closed, let layer, let weight, let dash):
                if layer == "BEAM" && !showBeams { continue }
                guard let path = makePath(points, closed: closed, viewport: vp),
                      pathBoundsIntersect(path, visible: visible, vp: vp) else { continue }
                let style = strokeStyle(weight: weight, dash: dash, zoom: vp.zoom)
                context.stroke(path, with: .color(color(for: layer)), style: style)

            case .fill(let points, let rgb):
                guard let path = makePath(points, closed: true, viewport: vp),
                      pathBoundsIntersect(path, visible: visible, vp: vp) else { continue }
                context.fill(path, with: .color(Color(rgb: rgb)))

            case .fillStroke(let points, let rgb, let layer, let weight):
                guard let path = makePath(points, closed: true, viewport: vp),
                      pathBoundsIntersect(path, visible: visible, vp: vp) else { continue }
                context.fill(path, with: .color(Color(rgb: rgb)))
                context.stroke(path, with: .color(color(for: layer)),
                               style: strokeStyle(weight: weight, dash: nil, zoom: vp.zoom))

            case .circle(let center, let radius, let layer, let weight):
                let c = vp.toView(center)
                let r = radius * vp.zoom
                guard r > 0.2 else { continue }
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.stroke(Path(ellipseIn: rect), with: .color(color(for: layer)),
                               style: strokeStyle(weight: weight, dash: nil, zoom: vp.zoom))

            case .fillCircle(let center, let radius, let rgb):
                let c = vp.toView(center)
                let r = radius * vp.zoom
                guard r > 0.2 else { continue }
                let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(Color(rgb: rgb)))

            case .text(let t):
                drawText(t, in: &context, viewport: vp)
            }
        }
    }

    /// 文字。
    ///
    /// **屏幕上的字有最小可读尺寸。** 缩得太小时不出字（省算力，也避免糊成灰块），
    /// 但也不能无限放大 —— 那会让图看起来像被"贴"了一层字。
    /// 这与 PDF 的行为不同：PDF 是固定 1:1，没有这个问题。
    private func drawText(_ t: TextOp, in context: inout GraphicsContext, viewport vp: Viewport) {
        let naturalCap = t.capMM * vp.zoom

        // 屏幕文字的物理约束：整张 A1 塞进 800pt 时，2.24mm 的色片号只剩 2.13pt。
        //
        // 我试过两种极端，都不对：
        //   · 一律跳过（<3pt 不画）→ 全部 64 个灯号与 32 个通道号消失
        //   · 一律放大到 3.5pt   → 2.24mm 被撑到 3.68mm（1.64×），
        //                          灯号、色片号、通道圆圈互相压在一起
        //
        // 根因是**标注间距是按原始字高设计的**。放大字必定挤压。
        // 所以正确做法是：保持真实尺寸，只在低于"完全看不见"时给一个
        // 极小的下限（1.6pt），其余交给用户放大 —— 图上放大一圈就全清楚了。
        //
        // 这比强行放大诚实：**屏幕上的密度反映纸上的真实密度**。
        guard naturalCap > 1.6 else { return }
        let capPoints = naturalCap

        let metrics = t.family.measuring
        let em = metrics.emSize(forCapMM: t.capMM) * vp.zoom * (capPoints / naturalCap)
        guard em > 0.5, em < 4000 else { return }

        let anchor = vp.toView(t.origin)
        let font = Font.custom(fontName(for: t.family), size: em)

        var text = Text(t.string).font(font).foregroundColor(.black)
        if capPoints < 5 { text = text.fontWeight(.regular) }

        let resolved = context.resolve(text)
        // 用 UnitPoint 做对齐，不去 measure ——
        // 在无界约束下 measure 不可靠，会导致"每个字符一个位置"的错乱。
        let anchorPoint: UnitPoint
        switch t.align {
        case .left:   anchorPoint = UnitPoint(x: 0, y: 0.5)
        case .center: anchorPoint = UnitPoint(x: 0.5, y: 0.5)
        case .right:  anchorPoint = UnitPoint(x: 1, y: 0.5)
        }

        var layer = context
        layer.translateBy(x: anchor.x, y: anchor.y)
        if abs(t.rotationDegrees) > 0.01 {
            layer.rotate(by: .degrees(-t.rotationDegrees))   // 视图 y 向下，符号相反
        }
        // 视觉居中：字形在 em 盒里偏下，往上挪一点，让 cap 盒子居中对齐锚点。
        layer.draw(resolved, at: .zero, anchor: anchorPoint)
    }

    // MARK: 选中与悬停

    private func drawSelection(in context: inout GraphicsContext, viewport vp: Viewport) {
        let accent = Color.accentColor

        for unit in selection.fixtures {
            guard let f = sheet.doc.fixture(unit: unit),
                  let world = sheet.doc.worldPoint(of: f) else { continue }
            let p = vp.toView(sheet.layout.toSheet(world))
            let r = max(6, 11.2 * vp.zoom / 2 + 3)
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(accent), lineWidth: 1.5)
        }

        for id in selection.positions {
            guard let pos = sheet.doc.position(id: id), let shape = pos.shape else { continue }
            let a = vp.toView(sheet.layout.toSheet(shape.start))
            let b = vp.toView(sheet.layout.toSheet(shape.end))
            var path = Path()
            path.move(to: CGPoint(x: a.x, y: a.y))
            path.addLine(to: CGPoint(x: b.x, y: b.y))
            context.stroke(path, with: .color(accent),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }

    private func drawHover(in context: inout GraphicsContext, viewport vp: Viewport) {
        guard let id = hoverPosition,
              let pos = sheet.doc.position(id: id),
              let shape = pos.shape else { return }
        let a = vp.toView(sheet.layout.toSheet(shape.start))
        let b = vp.toView(sheet.layout.toSheet(shape.end))
        var path = Path()
        path.move(to: CGPoint(x: a.x, y: a.y))
        path.addLine(to: CGPoint(x: b.x, y: b.y))
        context.stroke(path, with: .color(.accentColor.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round))
        // 端点手柄：提示"这里可以拖"
        for p in [a, b] {
            let r: CGFloat = 4
            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(.accentColor.opacity(0.8)))
        }
    }

    // MARK: 吸附指示

    /// 吸附指示器：一个十字准星 + 类型标签 + 到原始位置的引线。
    ///
    /// 为什么要画"引线"：吸附点常常离鼠标有一段距离（吸附半径内），
    /// 只画准星会让用户以为鼠标位置错了。引线把"你在这儿、会吸到那儿"讲清楚。
    private func drawSnap(in context: inout GraphicsContext, viewport vp: Viewport) {
        guard let snap = snapPreview else { return }
        let p = vp.toView(snap.point)
        let raw = vp.toView(snap.raw)
        let accent = Color.accentColor

        // 引线
        if p.distance(to: raw) > 3 {
            var lead = Path()
            lead.move(to: CGPoint(x: raw.x, y: raw.y))
            lead.addLine(to: CGPoint(x: p.x, y: p.y))
            context.stroke(lead, with: .color(accent.opacity(0.45)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // 准星
        let r: CGFloat = 5
        var cross = Path()
        cross.move(to: CGPoint(x: p.x - r, y: p.y))
        cross.addLine(to: CGPoint(x: p.x + r, y: p.y))
        cross.move(to: CGPoint(x: p.x, y: p.y - r))
        cross.addLine(to: CGPoint(x: p.x, y: p.y + r))
        context.stroke(cross, with: .color(accent), lineWidth: 1.5)

        // 空心态圈（与准星区分，避免和灯具符号混淆）
        context.stroke(Path(ellipseIn: CGRect(x: p.x - r - 2.5, y: p.y - r - 2.5,
                                              width: (r + 2.5) * 2,
                                              height: (r + 2.5) * 2)),
                       with: .color(accent.opacity(0.85)), lineWidth: 1)

        // 类型标签
        let label = Text(snap.kind.label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(.white)
        let resolved = context.resolve(label)
        let size = resolved.measure(in: CGSize(width: 200, height: 40))
        let pad: CGFloat = 4
        let box = CGRect(x: p.x + r + 6, y: p.y - size.height / 2 - pad,
                         width: size.width + pad * 2,
                         height: size.height + pad * 2)
        context.fill(Path(roundedRect: box, cornerRadius: 4),
                     with: .color(accent.opacity(0.92)))
        context.draw(resolved, at: CGPoint(x: box.minX + pad, y: box.minY + pad),
                     anchor: .topLeading)
    }

    // MARK: 辅助

    private func makePath(_ points: [Vec2], closed: Bool, viewport vp: Viewport) -> Path? {
        guard points.count >= 2 else { return nil }
        var path = Path()
        let first = vp.toView(points[0])
        path.move(to: CGPoint(x: first.x, y: first.y))
        for p in points.dropFirst() {
            let q = vp.toView(p)
            path.addLine(to: CGPoint(x: q.x, y: q.y))
        }
        if closed { path.closeSubpath() }
        return path
    }

    private func pathBoundsIntersect(_ path: Path, visible: Rect, vp: Viewport) -> Bool {
        let b = path.boundingRect
        guard b.width.isFinite, b.height.isFinite else { return false }
        let tl = vp.toSheet(Vec2(Double(b.minX), Double(b.maxY)))
        let br = vp.toSheet(Vec2(Double(b.maxX), Double(b.minY)))
        return Rect(x0: tl.x, y0: tl.y, x1: br.x, y1: br.y).intersects(visible)
    }

    /// 线条的最小屏幕宽度。
    ///
    /// 0.049mm 的桁架线在缩到 30% 时只有 0.036pt —— 屏幕上会消失。
    /// 所以设一个 0.6pt 的下限：细线依然"最细"，但不会不见。
    private func strokeStyle(weight: Paper.LineWeight, dash: [Double]?,
                             zoom: Double) -> StrokeStyle {
        let width = max(weight.mm * zoom, 0.6)
        var style = StrokeStyle(lineWidth: width, lineCap: .butt, lineJoin: .miter)
        if let dash, dash.count >= 2 {
            // 虚线长度也用图纸 mm × 缩放，但设下限，避免缩小时虚线变成实线
            style.dash = dash.map { max($0 * zoom, 1.0) }
        }
        return style
    }

    private func color(for layer: String) -> Color {
        let spec = Paper.layer(layer)
        if spec.aci == Paper.ACI.grey { return Color.black.opacity(0.55) }
        return .black
    }

    private func fontName(for family: FontFamily) -> String {
        switch family {
        case .regular: return FontLibrary.regular.fontIdentifier
        case .bold:    return FontLibrary.bold.fontIdentifier
        }
    }
}

// MARK: - 小工具

extension Vec2 {
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

extension Vec2 {
    var cgSize: CGSize { CGSize(width: x, height: y) }
}

extension Color {
    /// 24 位真彩。
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }

    /// 用 0xRRGGBB 表示系统色。只在需要"桌面背景"这类固定色时使用。
    init(nsColorLike rgb: UInt32) {
        self.init(rgb: rgb)
    }
}
