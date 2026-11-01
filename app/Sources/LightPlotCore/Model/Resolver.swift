import Foundation

/// 灯具的挂载方式 —— 解析后的**唯一真相**。
///
/// 编辑器、渲染、校验全部走这里，不要各自再推一遍
/// "到底看 x 还是看 y"。旧管线在 `render.py` 里推了一次、
/// 在 `schedule.py` 里推了另一次，两边一旦漂移就会得到
/// "图上在这、表里在那"的诡异结果。
public enum FixtureMount: Equatable, Sendable {
    /// 锁在构件轴线上。
    ///
    /// `axisValue` 是**绝对的轴线坐标**（水平构件是 x，竖直构件是 y），
    /// 不是"距杆端的偏移"。这一点必须记牢：
    /// 旧数据里 LX 1 从 -7500 到 7500，而灯写在 x=-3500 ——
    /// 若按"距杆端偏移"解释，灯会跑到 -11000，整排面光全部错位。
    case onPosition(positionID: String, axisValue: Double, shape: PositionShape)

    /// 自由摆放（台上实物、地面灯）。两个坐标都是世界坐标。
    case free(Vec2)

    /// 解析失败。用错误码而不是抛异常 —— 半成品文档必须能显示。
    case unresolved(LintCode)

    public var worldPoint: Vec2? {
        switch self {
        case .onPosition(_, let axis, let shape):
            switch shape {
            case .horizontal(_, _, let y): return Vec2(axis, y)
            case .vertical(let x, _, _):   return Vec2(x, axis)
            }
        case .free(let p):  return p
        case .unresolved:   return nil
        }
    }

    public var positionID: String? {
        if case .onPosition(let id, _, _) = self { return id }
        return nil
    }

    /// 距构件起点的偏移。排序、合并、沿杆滑行都用它。
    public var offsetFromStart: Double? {
        guard case .onPosition(_, let axis, let shape) = self else { return nil }
        switch shape {
        case .horizontal(let x0, _, _): return axis - x0
        case .vertical(_, let y0, _):   return axis - y0
        }
    }
}

public enum Resolver {

    /// 解析一台灯具的挂载方式。
    ///
    /// 规则（与旧数据完全兼容，但把隐含约定写成了显式逻辑）：
    ///  1. 实物灯 → 自由摆放（x、y 都是世界坐标）
    ///  2. 否则必须找到 `pos` 指向的构件
    ///  3. 水平构件读 `x`，竖直构件读 `y`
    ///
    /// **不做夹紧**。如果灯落在杆外，就按实际坐标画出来，
    /// 由 `Lint` 报 `fixture.offPosition`。
    /// 悄悄夹紧更危险：图上看起来"还算在附近"，而数据与图已经不一致了。
    public static func mount(of fixture: Fixture, in doc: LXDocument) -> FixtureMount {
        if fixture.isFreeMounted {
            guard let x = fixture.x, let y = fixture.y else {
                return .unresolved(.fixtureMissingCoordinate)
            }
            return .free(Vec2(x, y))
        }

        guard let posID = fixture.pos, !posID.isEmpty else {
            return .unresolved(.fixtureMissingField)
        }
        guard let pos = doc.position(id: posID) else {
            return .unresolved(.fixtureUnknownPosition)
        }
        guard let shape = pos.shape else {
            return .unresolved(.positionMissingShape)
        }

        // 歧义状态（两个坐标都给）优先按轴线坐标解，让灯仍然留在杆上。
        // 同时 `Lint` 会报错，迫使数据回到明确状态。
        let axis: Double
        switch shape {
        case .horizontal:
            guard let v = fixture.x ?? fixture.y else {
                return .unresolved(.fixtureMissingCoordinate)
            }
            axis = v
        case .vertical:
            guard let v = fixture.y ?? fixture.x else {
                return .unresolved(.fixtureMissingCoordinate)
            }
            axis = v
        }
        return .onPosition(positionID: posID, axisValue: axis, shape: shape)
    }

    /// 世界坐标（文档 mm）。解析失败返回 nil。
    public static func worldPoint(of fixture: Fixture, in doc: LXDocument) -> Vec2? {
        mount(of: fixture, in: doc).worldPoint
    }

    /// 批量解析，按灯号升序（稳定顺序，便于回归比对）。
    public static func allMounts(in doc: LXDocument) -> [(fixture: Fixture, mount: FixtureMount)] {
        doc.fixtures
            .sorted { $0.unit < $1.unit }
            .map { ($0, mount(of: $0, in: doc)) }
    }

    /// 一根构件上挂了哪些灯，按沿杆偏移升序。
    public static func fixtures(on positionID: String,
                                in doc: LXDocument) -> [(fixture: Fixture, offset: Double)] {
        allMounts(in: doc).compactMap { entry in
            if case .onPosition(let id, _, _) = entry.mount, id == positionID,
               let off = entry.mount.offsetFromStart {
                return (entry.fixture, off)
            }
            return nil
        }
        .sorted { $0.1 < $1.1 }
    }

    /// 灯具是否落在构件长度范围内。
    /// `false` 表示灯挂到杆外了 —— 这必须是可见的错误，不能夹紧。
    public static func isOnPosition(_ mount: FixtureMount) -> Bool {
        guard case .onPosition(_, let axis, let shape) = mount else { return true }
        switch shape {
        case .horizontal(let x0, let x1, _):
            return axis >= min(x0, x1) - 1e-6 && axis <= max(x0, x1) + 1e-6
        case .vertical(_, let y0, let y1):
            return axis >= min(y0, y1) - 1e-6 && axis <= max(y0, y1) + 1e-6
        }
    }
}
