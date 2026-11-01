import Foundation
import Yams

/// 一个灯光场景（设计状态）。
///
/// **这不是"另一套灯"，而是同一套灯换一种组织方式。**
/// 设计任务书要求"两个形成对比的场景"——对比应当来自
/// 色片与强度的重新分配，而不是另起一批灯位。
///
/// 数据来自旧管线的 `scenes.yaml`：
///   · `gel_override`：某色片在这个场景里换成另一个色片
///   · `levels`：每个构件（吊杆/BOOM/SET）的强度百分比
///   · `default_level`：未列出的构件用的默认值
public struct LightingState: Codable, Equatable, Sendable, Identifiable {
    /// 内部键（"kitchen" / "boston"）。
    public var id: String
    /// 幕次标签（"ACT 1"）。
    public var act: String
    /// 场景名（"KITCHEN - NIGHT"）。
    public var name: String
    /// 设计意图，一句话。
    public var concept: String
    /// 色片替换表：原色号 → 本场景用的色号。
    public var gelOverride: [String: String]
    /// 各构件强度（0–100）。
    public var levels: [String: Double]
    /// 未列出的构件用这个强度。
    public var defaultLevel: Double

    public init(id: String, act: String = "", name: String,
                concept: String = "", gelOverride: [String: String] = [:],
                levels: [String: Double] = [:], defaultLevel: Double = 0) {
        self.id = id
        self.act = act
        self.name = name
        self.concept = concept
        self.gelOverride = gelOverride
        self.levels = levels
        self.defaultLevel = defaultLevel
    }

    enum CodingKeys: String, CodingKey {
        case id, act, name, concept
        case gelOverride = "gel_override"
        case levels
        case defaultLevel = "default_level"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // `id` 允许缺失：真正的 id 是 `scenes:` 字典的键，
        // `LightingStateSet` 解码后会覆盖这一项。
        //
        // 早先这里强制要求 `id` 存在，于是手写的 scenes.yaml
        // （按文档"键就是 id"来写）直接报 keyNotFound，
        // 而报错信息里根本看不出问题在哪。
        let rawID = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        id = rawID

        // `act` 缺省时，把文件里的 `id` 当作幕次标签。
        //
        // 真实数据把所有幕次写在 `id:` 里（`id: ACT 1`），
        // 而场景 id 来自字典键 —— 于是那句 `ACT 1` **被静默丢弃**，
        // 场景横幅上永远只剩场景名，看不到是第几幕。
        // 这不是猜测：`id` 字段在那种写法下除了幕次没有别的含义。
        if let a = try c.decodeIfPresent(String.self, forKey: .act), !a.isEmpty {
            act = a
        } else {
            act = rawID
        }
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        concept = try c.decodeIfPresent(String.self, forKey: .concept) ?? ""
        gelOverride = try c.decodeIfPresent([String: String].self, forKey: .gelOverride) ?? [:]
        levels = try c.decodeIfPresent([String: Double].self, forKey: .levels) ?? [:]
        defaultLevel = try c.decodeIfPresent(Double.self, forKey: .defaultLevel) ?? 0
    }

    // MARK: - 查询

    /// 某台灯在本场景里实际用的色片。
    public func gel(for fixture: Fixture) -> String? {
        guard let base = fixture.gel else { return nil }
        return gelOverride[base] ?? base
    }

    /// 某根构件的强度（0–100）。未列出就用 `defaultLevel`。
    ///
    /// 特别地：`SET` 是一个**虚拟构件**，代表台上的实物灯
    /// （冰箱、台灯）—— 它们不属于任何吊杆，但同样要算强度。
    ///
    /// ## 为什么需要归一化查找
    ///
    /// `scenes.yaml` 用的是短键（`FOH` / `LX1`），
    /// 而 `rig.yaml` 的构件名是 `FOH LX` / `LX 1`。
    /// 直接 `levels[id]` 会**全部查不到 → 一律 0 → 整个场景全黑**。
    ///
    /// 旧管线的 `levels` 字段从来没人读，所以这个错配一直没暴露。
    public func level(forPosition id: String) -> Double {
        if let exact = levels[id] { return exact }

        // 归一化：去掉空格、连字符，转大写。
        func norm(_ s: String) -> String {
            s.uppercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "")
        }
        let target = norm(id)
        for (key, value) in levels where norm(key) == target {
            return value
        }

        // 再退一步：短键是长名的前缀（"FOH" ↔ "FOH LX"）。
        // 只在**唯一匹配**时才用 —— 多个匹配说明数据有歧义，
        // 宁可退回 defaultLevel，也不要猜错。
        let prefixHits = levels.filter { key, _ in
            let k = norm(key)
            return target.hasPrefix(k) || k.hasPrefix(target)
        }
        if prefixHits.count == 1 { return prefixHits.first!.value }

        return defaultLevel
    }

    /// 一台灯在本场景的强度。按它挂的构件查。
    public func level(for fixture: Fixture) -> Double {
        if fixture.isFreeMounted { return level(forPosition: "SET") }
        guard let pos = fixture.pos else { return defaultLevel }
        return level(forPosition: pos)
    }

    /// 本场景里真正点亮（>0）的灯数。
    public func litCount(in doc: LXDocument) -> Int {
        doc.fixtures.filter { level(for: $0) > 0 }.count
    }

    /// 本场景用到的色片集合（已应用替换）。
    public func usedGels(in doc: LXDocument) -> Set<String> {
        var out = Set<String>()
        for f in doc.fixtures where level(for: f) > 0 {
            if let g = gel(for: f) { out.insert(g) }
        }
        return out
    }
}

/// 场景集。附带"场景如何切换"的说明。
public struct LightingStateSet: Codable, Equatable, Sendable {
    public struct Transition: Codable, Equatable, Sendable {
        public var from: String
        public var to: String
        public var note: String
        public init(from: String, to: String, note: String = "") {
            self.from = from
            self.to = to
            self.note = note
        }
    }

    public var states: [LightingState]
    public var transitions: [Transition]

    public init(states: [LightingState] = [], transitions: [Transition] = []) {
        self.states = states
        self.transitions = transitions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 文件里 scenes 是一个**字典**（key 是场景 id），不是数组
        let dict = try c.decodeIfPresent([String: LightingState].self, forKey: .scenes) ?? [:]
        states = dict.keys.sorted().map { key in
            var s = dict[key]!
            s.id = key
            return s
        }
        transitions = try c.decodeIfPresent([Transition].self, forKey: .transitions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var dict: [String: LightingState] = [:]
        for s in states { dict[s.id] = s }
        try c.encode(dict, forKey: .scenes)
        try c.encode(transitions, forKey: .transitions)
    }

    enum CodingKeys: String, CodingKey {
        case scenes, transitions
    }

    public var isEmpty: Bool { states.isEmpty }

    public func state(id: String) -> LightingState? {
        states.first { $0.id == id }
    }

    // MARK: - 对比检查

    /// 两个场景的对比强度。
    ///
    /// 设计任务书明确要求"两个场景形成对比"。评分看的是
    /// **光的组织方式是否真的不同**，不是"看起来有点不一样"。
    /// 所以这里量化两项：换了几个色片、有几个构件强度差 ≥15。
    public struct Contrast: Equatable, Sendable {
        public let gelDifferences: Int
        public let levelDifferences: Int
        public let gelDetail: [String]
        public let levelDetail: [String]

        /// 是否算"有实质对比"。
        public var isSufficient: Bool {
            gelDifferences >= 2 || levelDifferences >= 2
        }
    }

    public func contrast(_ a: LightingState, _ b: LightingState,
                         doc: LXDocument) -> Contrast {
        // 色片差异：把替换应用后比较每台灯的实际色片
        var gelDiff: [String] = []
        for f in doc.fixtures {
            let ga = a.gel(for: f)
            let gb = b.gel(for: f)
            if ga != gb {
                gelDiff.append("\(f.unit): \(ga ?? "-") → \(gb ?? "-")")
            }
        }

        // 强度差异：按构件比较，差 ≥15 才算"看得出"
        var levelDiff: [String] = []
        let ids = Set(doc.positions.map(\.id)).union(["SET"])
        for id in ids.sorted() {
            let la = a.level(forPosition: id)
            let lb = b.level(forPosition: id)
            if abs(la - lb) >= 15 {
                levelDiff.append("\(id): \(Int(la)) → \(Int(lb))")
            }
        }

        return Contrast(gelDifferences: gelDiff.count,
                        levelDifferences: levelDiff.count,
                        gelDetail: gelDiff,
                        levelDetail: levelDiff)
    }
}

// MARK: - 加载

public enum LightingStateCodec {
    public static func decodeYAML(_ data: Data) throws -> LightingStateSet {
        try YAMLDecoderShim.decode(LightingStateSet.self, from: data)
    }
}

/// 薄封装，避免在上层到处 import Yams。
enum YAMLDecoderShim {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try Yams.YAMLDecoder().decode(type, from: data)
    }
}
