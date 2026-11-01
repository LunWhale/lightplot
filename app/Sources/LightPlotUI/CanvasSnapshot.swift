import SwiftUI
import LightPlotCore
import LightPlotUI

#if os(macOS)
import AppKit
/// 离屏渲染 —— 把画布渲成 PNG，不需要窗口。
///
/// 三个用途：
///   1. **视觉回归**：CI 里比对渲染结果，不需要人盯屏幕
///   2. **文档配图**：README / 说明书里的截图可自动生成
///   3. **快速自查**：改了绘制代码立刻能看到效果
///
/// 它渲染的是 `SheetCanvas`（也就是应用里真正在用的那个视图），
/// 不是另画一遍 —— 否则"预览"和"实际"迟早会分叉。
@MainActor
public enum CanvasSnapshot {

    public enum SnapshotError: Error, LocalizedError {
        case renderFailed
        case encodingFailed

        public var errorDescription: String? {
            switch self {
            case .renderFailed: return "SwiftUI could not render the canvas."
            case .encodingFailed: return "Could not encode the snapshot as PNG."
            }
        }
    }

    /// 渲染整张图纸到 PNG。
    ///
    /// - Parameters:
    ///   - scale: 像素 / 点。2 = Retina，4 = 用于放大检查细节。
    public static func render(doc: LXDocument,
                              width: CGFloat = 1600,
                              scale: CGFloat = 2,
                              showBeams: Bool = true,
                              selection: Selection = .empty) throws -> Data {
        var filled = doc
        _ = GelLibrary.fillMissingColours(in: &filled)

        let sheet = PlanSheet(fitting: filled)
        var vp = Viewport(zoom: 1, pan: Vec2.zero,
                          sizePoints: Vec2(Double(width), Double(width) * 0.706))
        vp = vp.fitted(to: sheet.layout.outerFrame, padding: 20)

        let view = SheetCanvas(sheet: sheet, viewport: vp,
                               selection: selection, showBeams: showBeams)
            .frame(width: width, height: width * 0.706)

        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { throw SnapshotError.renderFailed }

        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: width, height: width * 0.706)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed
        }
        return data
    }

    /// 渲染并写盘。
    @discardableResult
    public static func write(doc: LXDocument, to url: URL,
                             width: CGFloat = 1600, scale: CGFloat = 2,
                             showBeams: Bool = true) throws -> URL {
        let data = try render(doc: doc, width: width, scale: scale, showBeams: showBeams)
        try data.write(to: url)
        return url
    }
}
#endif
