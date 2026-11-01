import Foundation

/// 二维点 / 向量。
///
/// **单位约定（全工程最重要的约定之一）**
/// 本类型不携带单位，但每个使用者必须明确自己在哪个空间：
///   · 文档空间 = **真实毫米**（A1 @ 1:25 → 21025 × 14850 mm）
///   · 图纸空间 = **纸张毫米**（A1 → 841 × 594 mm）
///   · 视图空间 = **屏幕点**（pt，受缩放影响）
///
/// 换算只允许发生在 `Transforms.swift` 的两种变换里，别处一律不做乘法。
public struct Vec2: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }

    /// 角度（度）。0° = +X，90° = +Y。与 `rig.yaml` 的 `aim` 同一约定。
    public var angleDegrees: Double {
        atan2(y, x) * 180.0 / .pi
    }

    public init(angleDegrees: Double, length: Double = 1.0) {
        let r = angleDegrees * .pi / 180.0
        self.init(cos(r) * length, sin(r) * length)
    }

    /// 单位方向向量；零向量返回 nil（避免静默产生 NaN）。
    public var normalized: Vec2? {
        let l = length
        guard l > 1e-12 else { return nil }
        return Vec2(x / l, y / l)
    }

    public func rotated(byDegrees degrees: Double) -> Vec2 {
        let r = degrees * .pi / 180.0
        let c = cos(r), s = sin(r)
        return Vec2(x * c - y * s, x * s + y * c)
    }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { a * s }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }

    /// 叉积的 z 分量（用于判定左右侧 / 共线性）。
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }

    /// 投影到 a→b 线段上，返回 (参数 t 已夹紧 0...1, 最近点)。
    /// 沿杆滑行、端点吸附都靠它，所以必须夹紧 —— 否则灯会跑出杆外。
    public func projected(onto a: Vec2, _ b: Vec2) -> (t: Double, point: Vec2) {
        let ab = b - a
        let denom = ab.lengthSquared
        guard denom > 1e-12 else { return (0, a) }
        let t = ((self - a).dot(ab) / denom).clamped(to: 0...1)
        return (t, a + ab * t)
    }
}

extension Comparable {
    /// 夹紧。写频繁的几何代码里比 min/max 嵌套更好读。
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

extension Double {
    public func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
