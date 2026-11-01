import Foundation
import CoreText

/// 文字度量协议。
///
/// 排版、白底遮罩、图签自动缩字号，全都要知道"这行字有多宽"。
/// 旧项目曾经用 `h * 0.58 * 1.72` 这种硬凑系数，结果是每张表单独调数字、
/// 换个字体又挤 —— 反复打地鼠的根源。现在直接问字体要 advance width，误差 <1%。
public protocol TextMeasuring: Sendable {
    /// cap / em。Arial 实测 1467/2048 = 0.7163。
    /// 这个值**必须来自字体本身**，不能硬编码 —— 否则 iOS 与 macOS 的字高会悄悄不同。
    var capToEm: Double { get }

    /// 整串文字的 advance 宽度，单位 em。
    func advanceEM(_ s: String) -> Double

    /// 供调试/摘要使用的字体标识。
    var fontIdentifier: String { get }
}

public extension TextMeasuring {

    /// 文字宽度（图纸 mm）。`capMM` = 的 cap 高度，与 `Paper.FontSize` 同一单位。
    func widthMM(_ s: String, capMM: Double) -> Double {
        guard !s.isEmpty else { return 0 }
        return advanceEM(s) * capMM / capToEm
    }

    /// cap 高度 → em 尺寸（同单位）。写进 PDF/Canvas 之前必须过这一步。
    func emSize(forCapMM capMM: Double) -> Double { capMM / capToEm }

    /// em 尺寸 → cap 高度（同单位）。
    func capMM(forEmSize em: Double) -> Double { em * capToEm }

    /// 把 cap 缩到能塞进 `maxWidthMM`，返回新的 cap（不小于 `minCapMM`）。
    ///
    /// 图签字段必须用它 —— 旧项目曾经把标签列宽写死，
    /// 换字体后 `DIRECTOR` 和值就重叠了。
    func fitCapMM(_ s: String, capMM: Double, maxWidthMM: Double,
                  minCapMM: Double = 1.6) -> Double {
        let w = widthMM(s, capMM: capMM)
        guard w > maxWidthMM, w > 0 else { return capMM }
        return max(minCapMM, capMM * maxWidthMM / w * 0.98)
    }

    /// 文字包围盒（图纸 mm，y 向上）。
    ///
    /// 垂直按 cap 上下居中（与绘制时的 middle 对齐一致）。
    /// 旋转 90° 时宽高互换 —— 构件名沿桁架旋转就靠这个。
    func textBox(_ s: String, at origin: Vec2, capMM: Double,
                 align: TextAlign = .center, rotationDegrees: Double = 0,
                 pad: Double = 0) -> Rect {
        let w = widthMM(s, capMM: capMM)
        let h = capMM
        if abs(rotationDegrees.truncatingRemainder(dividingBy: 180)) > 45 {
            return Rect(x0: origin.x - h / 2 - pad, y0: origin.y - w / 2 - pad,
                        x1: origin.x + h / 2 + pad, y1: origin.y + w / 2 + pad)
        }
        let x0: Double
        switch align {
        case .left:  x0 = origin.x
        case .center: x0 = origin.x - w / 2
        case .right: x0 = origin.x - w
        }
        return Rect(x0: x0 - pad, y0: origin.y - h / 2 - pad,
                    x1: x0 + w + pad, y1: origin.y + h / 2 + pad)
    }
}

public enum TextAlign: String, Sendable, Codable, CaseIterable {
    case left, center, right
}

// MARK: - CoreText 实现

/// 基于 CoreText 的真实字度量。macOS 与 iOS 通用。
///
/// 内部固定用一个参考字号（1000pt）建字体、量宽度，再除以 1000 得到 em 归一化值。
/// 这样"字号变大"不会改变度量结果，数值稳定、可缓存、可回归。
public final class CoreTextMeasurement: TextMeasuring, @unchecked Sendable {
    private let font: CTFont
    private let referenceSize: Double
    private var cache: [String: Double] = [:]
    private let lock = NSLock()

    public let capToEm: Double
    public let fontIdentifier: String

    /// 不校验字体是否存在的构造器。
    ///
    /// 只给最后兜底用：CoreText 在找不到名字时会**静默返回系统字体**，
    /// 所以正常路径必须走 `init?(fontName:)` 做名字比对。
    public init(unverifiedFontName: String, size: CGFloat = 1000) {
        let f = CTFontCreateWithName(unverifiedFontName as CFString, size, nil)
        self.font = f
        self.referenceSize = Double(size)
        self.capToEm = Double(CTFontGetCapHeight(f)) / Double(size)
        self.fontIdentifier = CTFontCopyPostScriptName(f) as String
    }

    /// 用一个具体字体名建度量。名字解析失败返回 nil ——
    /// 调用方（`FontLibrary`）负责按优先级回退，而不是静默用系统默认字体。
    public init?(fontName: String, size: CGFloat = 1000) {
        guard let verified = Self.resolve(fontName, size: size) else { return nil }
        self.font = verified.font
        self.referenceSize = Double(size)
        self.capToEm = verified.capToEm
        self.fontIdentifier = verified.identifier
    }

    /// 按名字解析字体，并**确认真的拿到了那个字体**。
    ///
    /// `CTFontCreateWithName` 在找不到名字时**不会失败** —— 它会静默返回
    /// 系统默认字体。所以必须比对解析结果，否则"内置字体没加载上"
    /// 会表现为"悄悄用了 Helvetica"，而排版会跟着悄悄变。
    ///
    /// 名字匹配规则（从宽到严）：
    ///   · 精确 PostScript 名（`ArialMT`、`LiberationSans-Bold`）
    ///   · 族名（`LiberationSans` 覆盖 `LiberationSans-Regular`）
    ///   · 去掉 `-Regular` 后缀后相等（UI 习惯写法）
    static func resolve(_ fontName: String, size: CGFloat)
        -> (font: CTFont, capToEm: Double, identifier: String)? {
        let requested = fontName.lowercased()
        // 先试精确名（可命中 "LiberationSans-Bold"）
        var candidates: [String] = [fontName]
        // 再试族名 + 标准字重（可命中 "LiberationSans" → "LiberationSans-Regular"）
        if !requested.contains("-") {
            candidates.append(fontName + "-Regular")
            candidates.append(fontName)
        }

        for name in candidates {
            let f = CTFontCreateWithName(name as CFString, size, nil)
            let actual = (CTFontCopyPostScriptName(f) as String)
            let family = (CTFontCopyFamilyName(f) as String)
            let actualLower = actual.lowercased()
            let familyLower = family.lowercased()

            let requestedBase = requested.hasSuffix("-regular")
                ? String(requested.dropLast("-regular".count))
                : requested

            let matches = actualLower == requested
                || familyLower == requested
                || actualLower == requestedBase
                || familyLower == requestedBase
                || actualLower.hasPrefix(requestedBase + "-")
                || familyLower.hasPrefix(requestedBase)

            if matches {
                return (f, Double(CTFontGetCapHeight(f)) / Double(size), actual)
            }
        }
        return nil
    }

    public func advanceEM(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        lock.lock()
        if let hit = cache[s] { lock.unlock(); return hit }
        lock.unlock()

        let attr = NSAttributedString(string: s, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        // CTLine 在参考字号下返回**点**；除回参考字号才是 em 归一化值。
        // 漏掉这一步，所有"按字宽排"的逻辑会整体放大 1000 倍 ——
        // 而画面上的字本身看起来正常，所以极难发现。
        let width = CTLineGetTypographicBounds(line, nil, nil, nil) / referenceSize

        lock.lock()
        cache[s] = width
        lock.unlock()
        return width
    }
}

/// 等宽假度量 —— **只给单元测试用**。
///
/// 用它可以把"排版数学"与"字体内容"解耦：
/// 断言 10 个字符在 cap 4mm 下宽度必须是 20mm 之类的精确值。
public struct MonospacedMeasurement: TextMeasuring {
    public let advancePerCharacterEM: Double
    public let capToEm: Double
    public let fontIdentifier: String

    public init(advancePerCharacterEM: Double = 0.5,
                capToEm: Double = Paper.emToCapFallback,
                fontIdentifier: String = "monospaced-mock") {
        self.advancePerCharacterEM = advancePerCharacterEM
        self.capToEm = capToEm
        self.fontIdentifier = fontIdentifier
    }

    public func advanceEM(_ s: String) -> Double {
        Double(s.count) * advancePerCharacterEM
    }
}

// MARK: - 字体库

/// 字体解析与缓存。
///
/// **确定性要求**：图纸的每一个字宽都依赖这个字体，所以它必须两端一致。
/// 系统字体在不同 iOS/macOS 版本会变 advance width，
/// 后果是所有按字宽算的版式静默错位。因此：
///
///   1. 优先用**随包内置**的字体（见 Resources/Fonts，含 SHA 记录）
///   2. 退到系统 Arial（macOS 有、iOS 没有）
///   3. 再退到 Helvetica（两端都有，但字宽与 Arial 不同）
///
/// 摘要工具会打印实际使用的字体标识，回归测试会比对它。
public enum FontLibrary {

    /// **随包内置的字体**（`Resources/Fonts/`）。
    ///
    /// Liberation Sans 是 SIL OFL 授权的开源字体，设计度量与 Arial 逐字符一致
    /// （73 个常用字符的 advance width 完全相同，实测 MAXDIFF = 0.000）。
    /// 用它替换 Arial 有两个理由：
    ///   1. Arial 是 Monotype 商用字体，**不能随应用分发**
    ///   2. iPad 没有 Arial，会静默退到 Helvetica（字宽完全不同），
    ///      导致同一份文档在 Mac 与 iPad 上的排版不一致
    ///
    /// 已实测：advance width 相同，但 cap/em 不同
    /// （Arial 0.7163 / Liberation 0.6880），所以字高需要按字体实际值换算 ——
    /// 见 `capToEm` 的说明。
    /// **注意**：Liberation 的 PostScript 名不带 `-Regular` 后缀
    /// （常规体就叫 `LiberationSans`，粗体才叫 `LiberationSans-Bold`）。
    /// 写成 `LiberationSans-Regular` 会解析失败并静默退回 Arial ——
    /// 这个坑实测踩过。
    private static let bundledCandidates = [
        "LiberationSans",
    ]

    /// 系统字体回退链。**只在内置字体加载失败时使用。**
    /// 一旦用到这里，摘要里的 `face=` 就会变化，回归测试会立刻发现。
    private static let systemCandidates = [
        "ArialMT",
        "Helvetica",
        "HelveticaNeue",
    ]

    private static var cache: [String: CoreTextMeasurement] = [:]
    private static let lock = NSLock()
    private static var didRegisterBundled = false
    /// 诊断用：实际注册的字体文件（单元测试断言它非空）。
    nonisolated(unsafe) static var registeredURLs: [URL] = []

    /// 正文字体。
    public static var regular: CoreTextMeasurement {
        measurement(forKey: "regular", candidates: bundledCandidates + systemCandidates)
    }

    /// 粗体（图签标题、图纸名）。
    public static var bold: CoreTextMeasurement {
        measurement(forKey: "bold", candidates: [
            "LiberationSans-Bold",
        ] + systemCandidates.map { $0 + "-Bold" } + ["Helvetica-Bold"])
    }

    private static func measurement(forKey key: String,
                                    candidates: [String]) -> CoreTextMeasurement {
        // 双重检查锁定：整段「注册 → 解析 → 写缓存」在锁内完成。
        // 早先注册在锁外，并发调用会出现"某一线程已写缓存、另一线程还没注册"，
        // 于是缓存里留下系统回退字体且永不再更新。这在并行测试下必然复现。
        lock.lock()
        defer { lock.unlock() }

        if let hit = cache[key] { return hit }

        registerBundledFontsLocked()

        for name in candidates {
            if let m = CoreTextMeasurement(fontName: name) {
                cache[key] = m
                return m
            }
        }

        // 兜底：直接问系统要 UI 字体，它必然存在。
        // **不写缓存** —— 兜底结果不该被固化。
        return CoreTextMeasurement(unverifiedFontName: "Helvetica")
    }

    /// 注册内置字体。**调用者必须已持有 `lock`。**
    private static func registerBundledFontsLocked() {
        if didRegisterBundled { return }
        didRegisterBundled = true

        // SPM 的 `.process` 会把 Resources/ 下的内容**打平**到 bundle 根目录
        // （不会保留 Fonts/ 子目录），所以两处都要找。
        var urls = Bundle.module.urls(forResourcesWithExtension: "ttf",
                                      subdirectory: "Fonts") ?? []
        urls += Bundle.module.urls(forResourcesWithExtension: "ttf",
                                   subdirectory: nil) ?? []
        registeredURLs = urls
        for url in urls where url.pathExtension.lowercased() == "ttf" {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            // 重复注册返回 alreadyRegistered —— 忽略，不当失败。
        }
    }
}
