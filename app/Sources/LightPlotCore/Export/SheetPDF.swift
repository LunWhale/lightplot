import Foundation
import CoreGraphics
import CoreText

/// A1 矢量 PDF 导出。
///
/// **这是"可导出正确尺寸"的实现。** 关键点只有一个：
/// 页面必须是 **841 × 594 毫米**，不是 841 × 594 点。
/// 1 pt = 25.4/72 mm，所以 A1 的 PDF 页面是 2383.937 × 1683.780 pt。
///
/// 把页面做成 841×594 pt（= 296×209mm）是这类程序最经典的错误：
/// 打印出来是 A4 大小，而所有人看屏幕都以为对。
/// 旧项目为此专门写了 `check_scale_pdf()` 反解图框位置来防它。
public enum SheetPDF {

    public enum PDFError: Error, LocalizedError {
        case cannotCreate(URL)
        case cannotOpenContext
        case noPages

        public var errorDescription: String? {
            switch self {
            case .cannotCreate(let url): return "Cannot create PDF at \(url.path)"
            case .cannotOpenContext:     return "Cannot open a PDF graphics context"
            case .noPages:               return "PDF contains no pages"
            }
        }
    }

    /// 点 / 毫米。
    public static let k = Paper.pointsPerMM

    /// 页面尺寸（点）。测试与校验都断言这个值。
    public static func mediaBox(for paper: PaperSize) -> CGRect {
        CGRect(x: 0, y: 0,
               width: paper.widthMM * k,
               height: paper.heightMM * k)
    }

    public static func write(_ sheet: SectionSheet, to url: URL) throws {
        // 剖面图的 PDF 标题不能沿用平面图的"LX PLAN" ——
        // 一份图纸集里两份 PDF 属性都叫同一个名字，归档时无从区分。
        try write(ops: sheet.ops, paper: sheet.layout.paper,
                  title: sectionTitle(for: sheet.doc),
                  subject: sheet.doc.meta.show + " — SECTION",
                  to: url)
    }

    /// 剖面图的 PDF 文档标题。
    static func sectionTitle(for doc: LXDocument) -> String {
        let base = "LIGHTING SECTION"
        return doc.meta.show.isEmpty ? base : base
    }

    public static func write(_ sheet: PlanSheet, to url: URL) throws {
        try write(ops: sheet.ops, paper: sheet.layout.paper,
                  title: sheet.doc.meta.sheetTitle,
                  subject: sheet.doc.meta.show,
                  to: url)
    }

    static func write(ops: [DrawOp], paper: PaperSize,
                      title: String, subject: String, to url: URL) throws {
        var box = mediaBox(for: paper)

        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw PDFError.cannotCreate(url)
        }
        // 元数据必须**在建上下文时**传入（auxiliaryInfo）——
        // 早先这段字典被构造出来后赋给 `_`，从未进入 PDF：
        // 打开文件属性是空的，看起来像没做完的工具。
        //
        // 刻意不写 CreationDate：同一份数据必须产出同样的字节，
        // 否则"改了一行代码导致图变了"和"只是时间戳变了"分不开。
        let info: [CFString: Any] = [
            kCGPDFContextCreator: "LightPlot \(LightPlotVersion.string)",
            kCGPDFContextTitle: title,
            kCGPDFContextSubject: subject,
        ]
        guard let ctx = CGContext(consumer: consumer, mediaBox: &box,
                                  info as CFDictionary) else {
            throw PDFError.cannotOpenContext
        }

        ctx.beginPDFPage(nil)

        // 进入"毫米坐标系"：之后所有坐标都是图纸毫米，原点左下、y 向上。
        // 这与图纸空间完全一致，所以不需要任何翻转 —— 翻转两次是这类代码的经典 bug。
        ctx.scaleBy(x: k, y: k)

        ctx.setLineJoin(.miter)
        ctx.setLineCap(.butt)
        ctx.setMiterLimit(10)
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)

        for op in ops {
            draw(op, in: ctx, text: FontLibrary.regular)
        }

        ctx.endPDFPage()
        ctx.closePDF()
    }

    // MARK: - 指令派发

    static func draw(_ op: DrawOp, in ctx: CGContext, text: TextMeasuring) {
        switch op {
        case .stroke(let points, let closed, _, let weight, let dash):
            strokePath(points, closed: closed, width: weight.mm, dash: dash, in: ctx)

        case .fill(let points, let rgb):
            fillPath(points, rgb: rgb, in: ctx)

        case .fillStroke(let points, let rgb, _, let weight):
            fillPath(points, rgb: rgb, in: ctx)
            strokePath(points, closed: true, width: weight.mm, dash: nil, in: ctx)

        case .circle(let center, let radius, _, let weight):
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(weight.mm)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2))
            ctx.strokePath()

        case .fillCircle(let center, let radius, let rgb):
            setFill(ctx, rgb)
            ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                      width: radius * 2, height: radius * 2))
            ctx.fillPath()

        case .text(let t):
            drawText(t, in: ctx)
        }
    }

    // MARK: - 路径

    static func path(_ points: [Vec2], closed: Bool) -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: CGPoint(x: first.x, y: first.y))
        for q in points.dropFirst() {
            p.addLine(to: CGPoint(x: q.x, y: q.y))
        }
        if closed { p.closeSubpath() }
        return p
    }

    static func strokePath(_ points: [Vec2], closed: Bool, width: Double,
                           dash: [Double]?, in ctx: CGContext) {
        guard points.count >= 2 else { return }
        ctx.setStrokeColor(gray: 0, alpha: 1)
        ctx.setLineWidth(max(width, 0.001))
        if let dash, dash.count >= 2 {
            ctx.setLineDash(phase: 0, lengths: dash.map { CGFloat($0) })
        } else {
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.addPath(path(points, closed: closed))
        ctx.strokePath()
    }

    static func fillPath(_ points: [Vec2], rgb: UInt32, in ctx: CGContext) {
        guard points.count >= 3 else { return }
        setFill(ctx, rgb)
        ctx.addPath(path(points, closed: true))
        ctx.fillPath()
    }

    static func setFill(_ ctx: CGContext, _ rgb: UInt32) {
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
    }

    // MARK: - 文字

    /// 画一段文字。
    ///
    /// **单位链条**（每一环都不能省）：
    ///   `capMM`（cap 高度，图纸 mm）
    ///     → `em = capMM / capToEm`（因为字体是按 em 度量的）
    ///     → 以 mm 为单位建 CTFont（当前坐标系本身就是 mm）
    ///     → 基线落在 `-capMM/2`，使 cap 盒子垂直居中
    static func drawText(_ t: TextOp, in ctx: CGContext) {
        guard !t.string.isEmpty, t.capMM > 0 else { return }

        let metrics = t.family.measuring
        let em = metrics.emSize(forCapMM: t.capMM)
        let fontName = (metrics as? CoreTextMeasurement)?.fontIdentifier ?? "Helvetica"
        let font = CTFontCreateWithName(fontName as CFString, em, nil)

        let attributed = NSAttributedString(string: t.string, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)

        let dx: Double
        switch t.align {
        case .left:   dx = 0
        case .center: dx = -width / 2
        case .right:  dx = -width
        }

        ctx.saveGState()
        ctx.translateBy(x: t.origin.x, y: t.origin.y)
        if abs(t.rotationDegrees) > 1e-9 {
            ctx.rotate(by: t.rotationDegrees * .pi / 180)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.textPosition = CGPoint(x: dx, y: -t.capMM / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
