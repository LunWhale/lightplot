import Foundation

/// 文档空间 → 图纸空间。
///
/// **只有这一处允许做 `/ scaleDenominator`。** 全工程其它地方一律不许出现除法。
/// 这条纪律的来历：旧项目把"图纸 mm"和"真实 mm"混在同一个变量里，
/// 结果复核器报"图框 21025×14850 应为 841×594"，把人引向"渲染坏了"，
/// 实际是两份产物用了不同的基准。
///
/// 三个空间，各自只在这里出现：
///   · 文档空间（真实 mm）：舞台 x -7500…7500、y -4000…9000
///   · 图纸空间（纸张 mm）：A1 0…841 × 0…594
///   · 视图空间（屏幕 pt）：见 `Viewport`
public struct SheetLayout: Sendable, Equatable, Codable {
    /// 纸张尺寸。
    public var paper: PaperSize
    /// 比例分母。默认 1:25。
    public var scaleDenominator: Double
    /// 文档原点 (0,0) 落在纸上的位置（纸张 mm）。
    ///
    /// 旧管线的默认值是 (355, 215)：平面图偏左，右侧留给图例与图签。
    /// 在编辑器里这就是"图纸框"的位置 —— 用户可以移动它。
    public var originOnSheet: Vec2

    public init(paper: PaperSize = .a1,
                scaleDenominator: Double = 25,
                originOnSheet: Vec2 = Vec2(355, 215)) {
        self.paper = paper
        self.scaleDenominator = scaleDenominator
        self.originOnSheet = originOnSheet
    }

    /// 文档 mm → 纸张 mm。
    public func toSheet(_ p: Vec2) -> Vec2 {
        Vec2(originOnSheet.x + p.x / scaleDenominator,
             originOnSheet.y + p.y / scaleDenominator)
    }

    /// 纸张 mm → 文档 mm。
    public func toDocument(_ p: Vec2) -> Vec2 {
        Vec2((p.x - originOnSheet.x) * scaleDenominator,
             (p.y - originOnSheet.y) * scaleDenominator)
    }

    /// 文档长度 → 纸张长度。
    public func sheetLength(_ d: Double) -> Double { d / scaleDenominator }

    /// 图幅外框（纸张 mm）。
    public var outerFrame: Rect {
        Rect(x0: Paper.frameMargin, y0: Paper.frameMargin,
             x1: paper.widthMM - Paper.frameMargin, y1: paper.heightMM - Paper.frameMargin)
    }

    /// 图幅内框（纸张 mm）：参考图实测 (20,20)-(821,574)。
    public var innerFrame: Rect {
        Rect(x0: Paper.frameInner, y0: Paper.frameInner,
             x1: paper.widthMM - Paper.frameInner, y1: paper.heightMM - Paper.frameInner)
    }

    /// 当前场地在纸上占的矩形（文档 mm → 纸张 mm）。用于"缩放到图纸"。
    public func sheetRect(forDocumentRect r: Rect) -> Rect {
        Rect(x0: toSheet(Vec2(r.x0, r.y0)).x, y0: toSheet(Vec2(r.x0, r.y0)).y,
             x1: toSheet(Vec2(r.x1, r.y1)).x, y1: toSheet(Vec2(r.x1, r.y1)).y)
    }

    /// 校验：比例必须是正数。编辑器里用户可能把 25 改成 0，
    /// 那会让所有坐标变成 inf 并污染文档 —— 必须在这里挡住。
    public var isValid: Bool { scaleDenominator.isFinite && scaleDenominator >= 1 }
}

/// 图纸空间 → 视图空间（屏幕）。
///
/// 视图空间 y 轴**向下**（SwiftUI / UIKit 约定），图纸空间 y 轴**向上**（CAD 约定）。
/// 翻转只在这里发生一次。翻两次是这类代码最典型的 bug。
public struct Viewport: Sendable, Equatable, Codable {
    /// 每个图纸毫米对应多少屏幕点。
    public var zoom: Double
    /// 图纸原点 (0,0) 在视图中的位置（点）。
    public var pan: Vec2
    /// 视图尺寸（点）。
    public var sizePoints: Vec2

    public init(zoom: Double = 1, pan: Vec2 = .zero, sizePoints: Vec2 = Vec2(1000, 700)) {
        self.zoom = zoom
        self.pan = pan
        self.sizePoints = sizePoints
    }

    public func toView(_ sheet: Vec2) -> Vec2 {
        Vec2(sheet.x * zoom + pan.x,
             -sheet.y * zoom + pan.y)
    }

    public func toSheet(_ view: Vec2) -> Vec2 {
        Vec2((view.x - pan.x) / zoom,
             (pan.y - view.y) / zoom)
    }

    /// 缩放并保持 `anchor`（视图点）下方的图纸位置不动。
    ///
    /// 这是"以光标为中心缩放"的全部实现。它必须是一个纯函数并有单测 ——
    /// 手感差最常见的根因就是这里算错了半格。
    public func zoomed(by factor: Double, around anchor: Vec2) -> Viewport {
        let limit = 0.02...400.0          // 图纸 mm → 点的合理范围
        let newZoom = (zoom * factor).clamped(to: limit)
        guard newZoom != zoom else { return self }
        let s = toSheet(anchor)
        var v = self
        v.zoom = newZoom
        v.pan = Vec2(anchor.x - s.x * newZoom,
                     anchor.y + s.y * newZoom)
        return v
    }

    /// 把一块图纸矩形放进视野（留边距，单位点）。
    /// 把一块图纸矩形放进视野。
    ///
    /// `topInset` / `bottomInset` 是**画布上下被浮层遮住的点数**。
    /// 应用里有浮层工具栏与状态栏压在画布上 —— 不把它们算进来，
    /// 适配之后图纸顶部就钻到工具栏底下（实测 K2 光区名被完全盖住）。
    /// 只加一个统一的 padding 不行：那会连左右也一起缩小，
    /// 在大窗口里白白浪费宽度。所以要能分开给。
    public func fitted(to rect: Rect, padding: Double = 24,
                       topInset: Double = 0,
                       bottomInset: Double = 0) -> Viewport {
        let availW = max(1, sizePoints.x - 2 * padding)
        let availH = max(1, sizePoints.y - 2 * padding - topInset - bottomInset)
        let sx = rect.width > 1e-9 ? availW / rect.width : 1
        let sy = rect.height > 1e-9 ? availH / rect.height : 1
        let z = min(sx, sy).clamped(to: 0.02...400.0)
        var v = self
        v.zoom = z
        // 可见区域在画布里整体下移了 (topInset − bottomInset)/2，
        // 所以图纸中心也要跟着移同样的量。
        let shift = (topInset - bottomInset) / 2
        v.pan = Vec2(sizePoints.x / 2 - rect.center.x * z,
                     sizePoints.y / 2 - shift + rect.center.y * z)
        return v
    }

    /// 平移（视图点位移）。
    public func panned(by delta: Vec2) -> Viewport {
        var v = self
        v.pan = Vec2(pan.x + delta.x, pan.y + delta.y)
        return v
    }

    /// 视图里可见的图纸矩形。用于视口剔除（虽然本工程只有几百个实体，
    /// 但剔除能让"以后要画大图"这条路不用重构）。
    public var visibleSheetRect: Rect {
        let a = toSheet(.zero)
        let b = toSheet(sizePoints)
        return Rect(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }
}
