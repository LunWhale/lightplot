import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// 从 PDF 的**文字层**里读事实，用于与旧管线产出比对。
///
/// 只读文字，不渲染像素 —— 像素比对会被抗锯齿、字体替换、
/// 渲染器版本差异淹没，而"图上印了哪些字"是稳定的事实。
///
/// 注意 `PDFKit` 在 macOS 与 iOS 上都有，所以这里不需要平台分支；
/// 只在极少数没有 PDFKit 的环境下退化为"读不到"。
public enum PDFText {

    /// 一段带位置的可提取文字。
    public struct Span: Sendable {
        public let text: String
        public let x: Double
        public let y: Double     // 基线，PDF 坐标系（原点在左下）
        public init(text: String, x: Double, y: Double) {
            self.text = text; self.x = x; self.y = y
        }
    }

    /// 一页 PDF 的抽象。避免在调用处写 `#if canImport(PDFKit)`。
    public struct Page {
        var widthMM: Double
        var heightMM: Double
        var text: String
        var spans: [Span]
    }

    public static func firstPage(of url: URL) -> Page? {
        #if canImport(PDFKit)
        guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else {
            return nil
        }
        // PDF 的点是 1/72 英寸；图框实测值以 mm 表示，这里换算回来。
        let box = page.bounds(for: .mediaBox)
        let k = 25.4 / 72.0

        // **必须按视觉位置重排，不能用内容流顺序。**
        //
        // PDFKit 的 `page.string` 按内容流原序拼行，而内容流里的顺序
        // 是绘制调用顺序 —— 与视觉上的相邻单元格毫无关系。
        // 实测：色片行后面跟着的是另一个色片行，而不是它下面的灯号，
        // 于是"相邻两行即配对"这条规则在 PDFKit 上完全不成立。
        // PyMuPDF 默认按位置排序，所以 Python 侧看起来成立，换到这边就不成立。
        //
        // 解法：逐行取 selection，用它的 bounds 排序（先上后下、先左后右）。
        let ns = (page.string ?? "") as NSString
        var spans: [Span] = []
        var lineStart = 0
        var i = 0
        while i <= ns.length {
            let atEnd = i == ns.length
            let isBreak = !atEnd && (ns.character(at: i) == 10 || ns.character(at: i) == 13)
            if atEnd || isBreak {
                if i > lineStart {
                    let range = NSRange(location: lineStart, length: i - lineStart)
                    let raw = ns.substring(with: range)
                        .trimmingCharacters(in: .whitespaces)
                    if !raw.isEmpty, let sel = page.selection(for: range) {
                        let b = sel.bounds(for: page)
                        spans.append(Span(text: raw, x: b.minX * k, y: b.minY * k))
                    }
                }
                lineStart = i + 1
            }
            i += 1
        }
        // 视觉顺序：y 从上到下（PDF 原点在左下，所以 y 降序），同 y 时 x 升序。
        spans.sort { a, b in
            if abs(a.y - b.y) > 2 { return a.y > b.y }
            return a.x < b.x
        }

        return Page(widthMM: box.width * k, heightMM: box.height * k,
                    text: page.string ?? "", spans: spans)
        #else
        return nil
        #endif
    }

    public static func pageSizeMM(_ page: Page) -> (Double, Double) {
        (page.widthMM, page.heightMM)
    }

    /// 文字行（去掉空行与首尾空白）。
    ///
    /// 用 `\n` 切分即可：LightPlot 与旧管线写 PDF 时都是一行一次绘制调用。
    /// 视觉阅读顺序的文字行。
    ///
    /// 优先用 `spans`（已按位置排序）；取不到位置时退回内容流顺序，
    /// 并让调用方知道这一点（比对会因此更保守）。
    public static func lines(_ page: Page) -> [String] {
        if !page.spans.isEmpty {
            return page.spans.map(\.text).filter { !$0.isEmpty }
        }
        return page.text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 是不是一个色片号：`L###`、`R####`、或 `OPEN`。
    public static func isGelCode(_ s: String) -> Bool {
        if s == "OPEN" { return true }
        guard let f = s.first, f == "L" || f == "R" else { return false }
        let rest = s.dropFirst()
        return rest.count >= 2 && rest.allSatisfy(\.isNumber)
    }
}
