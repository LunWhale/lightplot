import Foundation

/// 与轴对齐的矩形。单位由使用者所在空间决定（文档 mm / 图纸 mm / 屏幕 pt）。
///
/// 约定：`x0 <= x1`、`y0 <= y1`。构造器会自行翻转，
/// 因为拖拽时经常出现"从右下往左上拖"的负矩形，
/// 让每个调用点自己 min/max 是 bug 的温床。
public struct Rect: Hashable, Sendable, Codable {
    public var x0: Double
    public var y0: Double
    public var x1: Double
    public var y1: Double

    public init(x0: Double, y0: Double, x1: Double, y1: Double) {
        self.x0 = min(x0, x1)
        self.y0 = min(y0, y1)
        self.x1 = max(x0, x1)
        self.y1 = max(y0, y1)
    }

    public init(origin: Vec2, size: Vec2) {
        self.init(x0: origin.x, y0: origin.y, x1: origin.x + size.x, y1: origin.y + size.y)
    }

    public init(center: Vec2, halfSize: Vec2) {
        self.init(x0: center.x - halfSize.x, y0: center.y - halfSize.y,
                  x1: center.x + halfSize.x, y1: center.y + halfSize.y)
    }

    /// 由一组点求包围盒。空数组返回 nil —— 不要静默返回零矩形，
    /// 否则"没有几何"会被当成"在原点有个点"，进而画出一堆假东西。
    public init?(points: [Vec2]) {
        guard let first = points.first else { return nil }
        var r = Rect(x0: first.x, y0: first.y, x1: first.x, y1: first.y)
        for p in points.dropFirst() {
            r.x0 = min(r.x0, p.x)
            r.y0 = min(r.y0, p.y)
            r.x1 = max(r.x1, p.x)
            r.y1 = max(r.y1, p.y)
        }
        self = r
    }

    public static let zero = Rect(x0: 0, y0: 0, x1: 0, y1: 0)

    public var width: Double { x1 - x0 }
    public var height: Double { y1 - y0 }
    public var center: Vec2 { Vec2((x0 + x1) / 2, (y0 + y1) / 2) }
    public var minX: Double { x0 }
    public var maxX: Double { x1 }
    public var minY: Double { y0 }
    public var maxY: Double { y1 }

    public func inset(by d: Double) -> Rect {
        Rect(x0: x0 + d, y0: y0 + d, x1: x1 - d, y1: y1 - d)
    }

    public func offset(by v: Vec2) -> Rect {
        Rect(x0: x0 + v.x, y0: y0 + v.y, x1: x1 + v.x, y1: y1 + v.y)
    }

    public func contains(_ p: Vec2) -> Bool {
        p.x >= x0 && p.x <= x1 && p.y >= y0 && p.y <= y1
    }

    public func intersects(_ o: Rect) -> Bool {
        x0 < o.x1 && o.x0 < x1 && y0 < o.y1 && o.y0 < y1
    }

    /// 严格相交（允许接触边不算相交）。文字压字检查用这个：
    /// 两个字紧贴边界是允许的，重叠才是错。
    public func overlapsStrictly(_ o: Rect, pad: Double = 0) -> Bool {
        x0 < o.x1 - pad && o.x0 < x1 - pad && y0 < o.y1 - pad && o.y0 < y1 - pad
    }

    public func union(_ o: Rect) -> Rect {
        Rect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }

    public func intersection(_ o: Rect) -> Rect? {
        let r = Rect(x0: max(x0, o.x0), y0: max(y0, o.y0), x1: min(x1, o.x1), y1: min(y1, o.y1))
        return (r.width > 0 && r.height > 0) ? r : nil
    }
}
