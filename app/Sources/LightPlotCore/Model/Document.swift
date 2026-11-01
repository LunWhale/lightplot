import Foundation

// MARK: - 顶层文档

/// 一份灯光设计文档 —— 对应旧管线的 `data/rig.yaml`。
///
/// **设计原则：宽松解码，严格校验。**
///
/// 旧管线的 `qc.py` 是"数据不全就 raise"，这在批处理里正确（宁可不出图），
/// 但在编辑器里是灾难：用户拖了一半的文档打不开，就没法继续改。
///
/// 所以这里把几乎所有字段都做成 optional，让半成品文档永远能加载、能编辑，
/// 再由 `Lint` 用**可定位的错误码**告诉用户缺什么。
/// 校验的严格程度不降低，只是从"拒绝加载"改成"标红提示"。
public struct LXDocument: Codable, Equatable, Sendable {

    public struct Meta: Codable, Equatable, Sendable {
        /// `study`（不出瓦数/DMX）或 `industry`（出）。
        public var profile: String
        public var show: String
        public var playwright: String
        public var venue: String
        public var sheetTitle: String
        public var sheetNo: Int
        public var sheetNoSection: Int
        public var sheetOf: Int
        /// 比例分母。默认 1:25。
        public var scale: Double
        public var date: String
        public var revision: String
        public var revNote: String
        /// 图签字段。**不许在代码里写死** —— 换项目就错。
        public var director: String
        public var designer: String

        public init(profile: String = "study",
                    show: String = "UNTITLED",
                    playwright: String = "",
                    venue: String = "",
                    sheetTitle: String = "LX PLAN",
                    sheetNo: Int = 1,
                    sheetNoSection: Int = 2,
                    sheetOf: Int = 2,
                    scale: Double = 25,
                    date: String = "",
                    revision: String = "V1",
                    revNote: String = "FIRST ISSUE",
                    director: String = "I DON'T KNOW",
                    designer: String = "") {
            self.profile = profile
            self.show = show
            self.playwright = playwright
            self.venue = venue
            self.sheetTitle = sheetTitle
            self.sheetNo = sheetNo
            self.sheetNoSection = sheetNoSection
            self.sheetOf = sheetOf
            self.scale = scale
            self.date = date
            self.revision = revision
            self.revNote = revNote
            self.director = director
            self.designer = designer
        }

        enum CodingKeys: String, CodingKey {
            case profile, show, playwright, venue
            case sheetTitle = "sheet_title"
            case sheetNo = "sheet_no"
            case sheetNoSection = "sheet_no_section"
            case sheetOf = "sheet_of"
            case scale, date, revision
            case revNote = "rev_note"
            case director, designer
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Meta()
            profile = try c.decodeIfPresent(String.self, forKey: .profile) ?? d.profile
            show = try c.decodeIfPresent(String.self, forKey: .show) ?? d.show
            playwright = try c.decodeIfPresent(String.self, forKey: .playwright) ?? d.playwright
            venue = try c.decodeIfPresent(String.self, forKey: .venue) ?? d.venue
            sheetTitle = try c.decodeIfPresent(String.self, forKey: .sheetTitle) ?? d.sheetTitle
            sheetNo = try c.decodeIfPresent(Int.self, forKey: .sheetNo) ?? d.sheetNo
            sheetNoSection = try c.decodeIfPresent(Int.self, forKey: .sheetNoSection) ?? d.sheetNoSection
            sheetOf = try c.decodeIfPresent(Int.self, forKey: .sheetOf) ?? d.sheetOf
            scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
            date = try c.decodeIfPresent(String.self, forKey: .date) ?? d.date
            revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? d.revision
            revNote = try c.decodeIfPresent(String.self, forKey: .revNote) ?? d.revNote
            director = try c.decodeIfPresent(String.self, forKey: .director) ?? d.director
            designer = try c.decodeIfPresent(String.self, forKey: .designer) ?? d.designer
        }
    }

    public struct Stage: Codable, Equatable, Sendable {
        public var width: Double
        public var depth: Double
        /// 台面相对 ±0 的高度。
        public var datum: Double
        public var gridHeight: Double
        public var prosceniumHeight: Double
        public var prosceniumX: Double
        public var audienceRows: Int
        public var audienceRowDepth: Double
        public var audienceRake: Double

        public init(width: Double = 15000,
                    depth: Double = 9000,
                    datum: Double = 0,
                    gridHeight: Double = 8000,
                    prosceniumHeight: Double = 6500,
                    prosceniumX: Double = -1200,
                    audienceRows: Int = 7,
                    audienceRowDepth: Double = 560,
                    audienceRake: Double = 160) {
            self.width = width
            self.depth = depth
            self.datum = datum
            self.gridHeight = gridHeight
            self.prosceniumHeight = prosceniumHeight
            self.prosceniumX = prosceniumX
            self.audienceRows = audienceRows
            self.audienceRowDepth = audienceRowDepth
            self.audienceRake = audienceRake
        }

        enum CodingKeys: String, CodingKey {
            case width, depth, datum
            case gridHeight = "grid_height"
            case prosceniumHeight = "proscenium_height"
            case prosceniumX = "proscenium_x"
            case audienceRows = "audience_rows"
            case audienceRowDepth = "audience_row_depth"
            case audienceRake = "audience_rake"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Stage()
            width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
            depth = try c.decodeIfPresent(Double.self, forKey: .depth) ?? d.depth
            datum = try c.decodeIfPresent(Double.self, forKey: .datum) ?? d.datum
            gridHeight = try c.decodeIfPresent(Double.self, forKey: .gridHeight) ?? d.gridHeight
            prosceniumHeight = try c.decodeIfPresent(Double.self, forKey: .prosceniumHeight) ?? d.prosceniumHeight
            prosceniumX = try c.decodeIfPresent(Double.self, forKey: .prosceniumX) ?? d.prosceniumX
            audienceRows = try c.decodeIfPresent(Int.self, forKey: .audienceRows) ?? d.audienceRows
            audienceRowDepth = try c.decodeIfPresent(Double.self, forKey: .audienceRowDepth) ?? d.audienceRowDepth
            audienceRake = try c.decodeIfPresent(Double.self, forKey: .audienceRake) ?? d.audienceRake
        }
    }

    public var meta: Meta
    public var stage: Stage
    public var positions: [Position]
    /// 布景构件。YAML 里的键是 `set`（`set` 在 Swift 里是上下文关键字，用别名避免歧义）。
    public var setPieces: [SetPiece]
    public var zones: [Zone]
    public var fixtures: [Fixture]
    public var gels: [Gel]
    public var types: [String: FixtureType]

    public init(meta: Meta = Meta(),
                stage: Stage = Stage(),
                positions: [Position] = [],
                setPieces: [SetPiece] = [],
                zones: [Zone] = [],
                fixtures: [Fixture] = [],
                gels: [Gel] = [],
                types: [String: FixtureType] = [:]) {
        self.meta = meta
        self.stage = stage
        self.positions = positions
        self.setPieces = setPieces
        self.zones = zones
        self.fixtures = fixtures
        self.gels = gels
        self.types = types
    }

    enum CodingKeys: String, CodingKey {
        case meta, stage, positions
        case setPieces = "set"
        case zones, fixtures, gels, types
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meta = try c.decodeIfPresent(Meta.self, forKey: .meta) ?? Meta()
        stage = try c.decodeIfPresent(Stage.self, forKey: .stage) ?? Stage()
        positions = try c.decodeIfPresent([Position].self, forKey: .positions) ?? []
        setPieces = try c.decodeIfPresent([SetPiece].self, forKey: .setPieces) ?? []
        zones = try c.decodeIfPresent([Zone].self, forKey: .zones) ?? []
        fixtures = try c.decodeIfPresent([Fixture].self, forKey: .fixtures) ?? []
        gels = try c.decodeIfPresent([Gel].self, forKey: .gels) ?? []
        types = try c.decodeIfPresent([String: FixtureType].self, forKey: .types) ?? [:]
    }

    public var scaleDenominator: Double { meta.scale }

    /// 场地外接矩形（文档 mm）。含观众席与少量余量。
    ///
    /// 观众席紧贴台口（第一排中心距台沿半个排距）。这是**版面约束**决定的：
    /// A1 在 1:25 下的可用高度只有约 546mm，即 13.6m；
    /// 台深 9m + 7 排 × 560mm = 12.9m，加走道与标注刚好放得下。
    /// 真实场地若更深，`Lint` 会报 `document.doesNotFitSheet`，而不是悄悄裁掉。
    public var stageBounds: Rect {
        let halfW = stage.width / 2
        let audienceDepth = Double(stage.audienceRows) * stage.audienceRowDepth
        return Rect(x0: -halfW, y0: -(audienceDepth + 500),
                    x1: halfW, y1: stage.depth)
    }

    /// 灯具的世界坐标（文档 mm）。见 `Resolve.swift`。
    public func worldPoint(of fixture: Fixture) -> Vec2? {
        Resolver.worldPoint(of: fixture, in: self)
    }

    public func position(id: String) -> Position? {
        positions.first { $0.id == id }
    }

    public func zone(id: String) -> Zone? {
        zones.first { $0.id == id }
    }

    public func gel(code: String) -> Gel? {
        gels.first { $0.code == code }
    }

    public func fixture(unit: Int) -> Fixture? {
        fixtures.first { $0.unit == unit }
    }
}
