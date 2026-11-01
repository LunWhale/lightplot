import Foundation

/// 真实灯具符号库 —— 从厂家 GDTF 提取的多边形（实物毫米）。
///
/// 数据来源：旧项目的 `src/gdtf_symbol.py` 从 GDTF 的 GLB 网格投影出俯视轮廓，
/// 经 RDP 简化后存为 `symbols.json`。这是整套工程里最难得的一份资产 ——
/// 符号是从**真实灯具**身上量的，不是手画的图标。
public struct SymbolShape: Sendable {
    public let typeKey: String
    public let name: String
    public let manufacturer: String
    /// 俯视轮廓（实物 mm，原点在符号自身中心附近）。
    public let polygons: [[Vec2]]
    public let bounds: Rect

    public var longAxis: Double { max(bounds.width, bounds.height) }

}

public enum SymbolLibrary {

    /// USITT RP-2 的台上实物符号：一个三角。GDTF 里没有 practical。
    ///
    /// 坐标沿用旧管线的定义（实物 mm 量级），便于同一套缩放逻辑处理。
    static let practicalPolygon: [Vec2] = [
        Vec2(-90, -70), Vec2(90, -70), Vec2(0, 95),
    ]

    private static var cache: [String: SymbolShape]?
    private static let lock = NSLock()

    public static var all: [String: SymbolShape] {
        lock.lock()
        defer { lock.unlock() }
        if let c = cache { return c }
        let loaded = load()
        cache = loaded
        return loaded
    }

    public static func top(for typeKey: String) -> SymbolShape? {
        all[typeKey]
    }

    /// 画一个符号需要的多边形：优先真实符号，缺则用 USITT 三角。
    public static func polygons(for typeKey: String) -> [[Vec2]] {
        if let s = top(for: typeKey), !s.polygons.isEmpty { return s.polygons }
        if typeKey == "practical" { return [practicalPolygon] }
        return []
    }

    // MARK: 载入

    private struct RawFile: Decodable {}
    private struct RawView: Decodable { let polygons: [[[Double]]]? }
    private struct RawSymbol: Decodable {
        let name: String?
        let manufacturer: String?
        let top: RawView?
    }

    private static func load() -> [String: SymbolShape] {
        guard let url = Bundle.module.url(forResource: "symbols", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return [:]
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> [String: SymbolShape] {
        guard let raw = try? JSONDecoder().decode([String: RawSymbol].self, from: data) else {
            return [:]
        }
        var out: [String: SymbolShape] = [:]
        for (key, sym) in raw {
            guard let polys = sym.top?.polygons, !polys.isEmpty else { continue }
            let converted: [[Vec2]] = polys.compactMap { poly in
                let pts = poly.compactMap { pair -> Vec2? in
                    guard pair.count >= 2 else { return nil }
                    return Vec2(pair[0], pair[1])
                }
                return pts.count >= 3 ? pts : nil
            }
            guard let bounds = Rect(points: converted.flatMap { $0 }) , bounds.width > 0 || bounds.height > 0 else { continue }
            out[key] = SymbolShape(typeKey: key,
                                   name: sym.name ?? key,
                                   manufacturer: sym.manufacturer ?? "",
                                   polygons: converted,
                                   bounds: bounds)
        }
        return out
    }
}
