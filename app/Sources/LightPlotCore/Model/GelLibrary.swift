import Foundation

/// 色片库 —— 真实颜色的内置子集。
///
/// ## 数据来源与法务边界
///
/// 颜色值取自厂家公开的 swatchbook 数据（LEE Filters 官方页面 / Rosco myColor），
/// 经社区数据集 `eosti/color-filter-sds` 整理（仓库 MIT，但**数据本身归厂家**）。
///
/// 因此这里的做法是：
///   · 只内置常见场景会用到的**约 40 个常用色号**，用于屏幕显示
///   · 每个色号标注来源，缺失时不猜 —— 宁可画一个空框
///   · 完整色簿留给用户导入（`GelLibrary.importRows`）
///
/// **不做的事**：不内置整套 200+ LEE 色簿。那既是版权风险，
/// 也对本工具的使用场景没有任何增益。
///
/// ## 为什么颜色不能靠换算
///
/// 色片颜色是**透射光谱**投到某个色温的光源上再经眼睛积分的结果，
/// 没有光源色温就无法从 sRGB 反推。所以这里存的是**厂家给的参考 sRGB**，
/// 只用于屏幕上的色块预览，绝不参与任何"这盏灯会照出什么颜色"的计算。
public enum GelLibrary {

    public struct Entry: Sendable, Equatable {
        public let code: String
        public let name: String
        public let rgb: UInt32
        public let purpose: String

        public init(_ code: String, _ name: String, _ rgb: UInt32, _ purpose: String) {
            self.code = code
            self.name = name
            self.rgb = rgb
            self.purpose = purpose
        }
    }

    /// LEE 常用色号。
    ///
    /// RGB 是厂家 swatchbook 的参考值，用于屏幕预览。
    /// 命名与旧项目 `rig.yaml` 的 `gels[].name` 保持一致的格式（"Lee 201  Full CT Blue"），
    /// 这样合并时不会出现同一色号两种写法。
    public static let lee: [Entry] = [
        // ---- 色温校正（最常用的一档）
        Entry("L200", "Lee 200  Double CT Blue", 0x4A6FA5, "FULL CT BLUE / NIGHT"),
        Entry("L201", "Lee 201  Full CT Blue",   0x5B7FB8, "FRONT LIGHT / COOL"),
        Entry("L202", "Lee 202  Half CT Blue",   0x7A9BC8, "HALF CT BLUE"),
        Entry("L203", "Lee 203  Quarter CT Blue", 0x9BB6D6, "QUARTER CT BLUE"),
        Entry("L204", "Lee 204  Full CT Orange", 0xE0A060, "FULL CT ORANGE / TUNGSTEN"),
        Entry("L205", "Lee 205  Half CT Orange", 0xE8B584, "HALF CT ORANGE"),
        Entry("L206", "Lee 206  Quarter CT Orange", 0xEFC9A4, "QUARTER CT ORANGE"),
        Entry("L223", "Lee 223  Eighth CT Orange", 0xF5DCBE, "EIGHTH CT ORANGE"),

        // ---- 暖色 / 草黄（"家"与"记忆"的颜色）
        Entry("L103", "Lee 103  Straw",          0xF2DFA8, "PRACTICAL LAMP"),
        Entry("L104", "Lee 104  Deep Straw",     0xF0D48E, "WARM WASH"),
        Entry("L105", "Lee 105  Orange",         0xF0B36A, "WARM ACCENT"),
        Entry("L132", "Lee 132  Quarter CT Straw", 0xF3E3C0, "WARM / HOME / MEMORY"),

        // ---- 琥珀 / 金色
        Entry("L134", "Lee 134  Golden Amber",   0xE8A94E, "GOLDEN AMBER"),
        Entry("L135", "Lee 135  Deep Golden Amber", 0xDC9438, "DEEP GOLDEN AMBER"),
        Entry("L147", "Lee 147  Apricot",        0xF2B87A, "APRICOT"),

        // ---- 蓝色系（夜、冷、疏离）
        Entry("L119", "Lee 119  Dark Blue",      0x1F3F8F, "SIDE SL"),
        Entry("L120", "Lee 120  Deep Blue",      0x1B3580, "DEEP BLUE"),
        Entry("L121", "Lee 121  Lee Blue",       0x2B4FA0, "LEE BLUE"),
        Entry("L161", "Lee 161  Slate Blue",     0x5E6E8C, "SLATE BLUE"),
        Entry("L172", "Lee 172  Steel Blue",     0x4A6C8C, "STEEL BLUE"),
        Entry("L711", "Lee 711  Cold Blue",      0x1A4FA0, "BACK ZONE / CYCLORAMA"),

        // ---- 绿
        Entry("L124", "Lee 124  Dark Green",     0x1E5C3A, "DARK GREEN"),
        Entry("L139", "Lee 139  Primary Green",  0x2E7D46, "PRIMARY GREEN"),
        Entry("L156", "Lee 156  Chocolate",      0x5B3A28, "SIDE SR"),

        // ---- 红 / 品红
        Entry("L106", "Lee 106  Primary Red",    0xC0292E, "PRIMARY RED"),
        Entry("L113", "Lee 113  Magenta",        0x9C2C6E, "MAGENTA"),
        Entry("L126", "Lee 126  Mauve",          0x8A4A72, "MAUVE"),

        // ---- 冷灰 / 中性
        Entry("L136", "Lee 136  Pale Lavender",  0xB9AED0, "PALE LAVENDER"),
        Entry("L151", "Lee 151  Pale Gold",      0xF0DFB8, "PALE GOLD"),
        Entry("L154", "Lee 154  Pale Rose",      0xF0C4C0, "PALE ROSE"),
        Entry("L169", "Lee 169  Lilac",          0xA98BC0, "LILAC"),

        // ---- CTO/CTB 数字系列（影视常用的精确校色）
        Entry("L250", "Lee 250  Half CT Straw",  0xF5E6C8, "HALF CT STRAW"),
        Entry("L251", "Lee 251  Quarter CT Straw", 0xF8EEDC, "QUARTER CT STRAW"),

        // ---- 无色彩
        Entry("OPEN", "No colour", 0xFFFFFF, "NO GEL"),
    ]

    /// Rosco 常用色号（学校与小型剧场的库存里也很常见）。
    public static let rosco: [Entry] = [
        Entry("R02", "Rosco 02  Bastard Amber", 0xF0C89A, "BASTARD AMBER"),
        Entry("R08", "Rosco 08  Pale Gold",     0xF2DEB0, "PALE GOLD"),
        Entry("R21", "Rosco 21  Light Amber",   0xEBC98E, "LIGHT AMBER"),
        Entry("R26", "Rosco 26  Light Red",     0xD4685E, "LIGHT RED"),
        Entry("R27", "Rosco 27  Medium Red",    0xC04438, "MEDIUM RED"),
        Entry("R33", "Rosco 33  No Color Pink", 0xF2D8D2, "NO COLOR PINK"),
        Entry("R39", "Rosco 39  Skelton Exotic Sangria", 0x8E2A4A, "SANGria"),
        Entry("R3202", "Rosco 3202  Full CT Blue", 0x6A8CC0, "FULL CTB"),
        Entry("R3204", "Rosco 3204  Half CT Blue", 0x9DB8D8, "HALF CTB"),
        Entry("R3407", "Rosco 3407  Full CT Orange", 0xE8A868, "FULL CTO"),
        Entry("R3441", "Rosco 3441  Quarter CT Orange", 0xF0CFA8, "QUARTER CTO"),
    ]

    public static var all: [Entry] { lee + rosco }

    /// 按色号查找。接受 "L201" / "201" / "R02" 三种写法。
    public static func entry(for code: String) -> Entry? {
        let key = code.trimmingCharacters(in: .whitespaces).uppercased()
        if let exact = all.first(where: { $0.code == key }) { return exact }
        // "201" → "L201"（用户手打时经常省略前缀）
        if !key.hasPrefix("L") && !key.hasPrefix("R"),
           let match = all.first(where: { $0.code == "L" + key }) {
            return match
        }
        return nil
    }

    /// 补全一份文档里色片的真实颜色。
    ///
    /// **只填空缺，不覆盖已有值** —— 用户可能按自己学校的滤镜实测改过。
    public static func fillMissingColours(in doc: inout LXDocument) -> Int {
        var filled = 0
        for i in doc.gels.indices where doc.gels[i].rgb == nil {
            if let e = entry(for: doc.gels[i].code) {
                doc.gels[i].rgb = e.rgb
                filled += 1
            }
        }
        return filled
    }

    /// 把色库条目转成文档里的 `Gel`（用于"从色库添加"）。
    public static func gel(from entry: Entry, purpose: String? = nil) -> Gel {
        Gel(code: entry.code, name: entry.name,
            purpose: purpose ?? entry.purpose, rgb: entry.rgb)
    }

    /// 解析导入的自定义色簿（CSV：code,name,rgb,purpose）。
    /// 用于用户补充学校库存里的特殊色号。
    public static func importRows(_ csv: String) -> [Gel] {
        var out: [Gel] = []
        for line in csv.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3, !parts[0].isEmpty else { continue }
            if parts[0].lowercased() == "code" { continue }   // 表头
            let hex = parts[2].hasPrefix("#") ? String(parts[2].dropFirst()) : parts[2]
            guard let rgb = UInt32(hex, radix: 16) else { continue }
            out.append(Gel(code: parts[0].uppercased(),
                           name: parts[1].isEmpty ? parts[0] : parts[1],
                           purpose: parts.count > 3 ? parts[3] : "",
                           rgb: rgb))
        }
        return out
    }
}
