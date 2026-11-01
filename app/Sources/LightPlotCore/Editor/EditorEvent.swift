import Foundation

/// 编辑器事件。
///
/// **所有输入必须先变成事件，再由 `reduce` 纯函数处理。**
/// 视图层只做 `render(state)`，不许持有业务状态。
///
/// 这条纪律有三个直接好处：
///   1. 拖拽、吸附、合并、旋转全部可在无窗口环境下断言
///   2. 撤销/重做是"保存 reduce 的输入序列"，不需要手工 diff
///   3. 同一串事件跑两次必须得到同一个文档 —— 可字节级回归
public enum EditorEvent: Equatable, Sendable {
    // 选择
    case select(Selection)
    case selectAt(Vec2, additive: Bool)        // 图纸坐标
    case clickEmpty
    case marqueeSelect(Rect)

    // 构件
    case movePosition(id: String, by: Vec2)    // 文档 mm 位移
    case setPositionEnd(id: String, which: EndPoint, to: Vec2)
    case addPosition(Position)
    case deletePosition(id: String)
    /// 把 b 并入 a（保留 a 的 id 与位置轴）。由 `Merger.evaluate` 判定是否允许。
    case mergePositions(keep: String, absorb: String)

    // 灯具
    case addFixture(Fixture, at: Vec2)         // 图纸坐标；吸附由 reduce 完成
    case moveFixture(unit: Int, to: Vec2)      // 图纸坐标
    case setFixtureAim(unit: Int, aim: Double)
    case deleteFixture(unit: Int)

    // 色片与表格
    case setFixtureGel(unit: Int, gel: String)
    case setFixtureChannel(unit: Int, ch: Int)
    case setFixturePurpose(unit: Int, purpose: String)

    // 版面
    case setScale(Double)
    /// 换纸幅。内容装不下时由 `capacity` 给出建议，而不是静默缩放。
    case setPaper(PaperSize)
    case setOrigin(Vec2)
    case autoFitOrigin

    // 文档与场地
    case _setMeta(String, String)
    case _setStage(String, Double)

    // 构件详情
    case setPositionTrim(id: String, trim: Double)
    case setPositionID(old: String, new: String)
    case setPositionType(id: String, type: PositionType)

    // 布景与光区
    case addSetPiece(SetPiece)
    case deleteSetPiece(id: String)
    case setSetPieceHeight(id: String, height: Double)
    /// 拖动布景。`SetPiece.id` 由坐标派生，所以移动后 id 会变，
    /// 选择集必须跟着更新（否则用户拖一次就失去选中）。
    case moveSetPiece(id: String, by: Vec2)
    case addZone(Zone)
    case deleteZone(id: String)

    // 撤销
    case undo
    case redo

    public enum EndPoint: String, Sendable, Equatable {
        case start, end
    }
}

/// 选择集。
///
/// 用"类型 + 标识"而不是对象引用：文档是值类型，引用会失效。
public struct Selection: Equatable, Sendable {
    public var positions: Set<String>
    public var fixtures: Set<Int>
    public var zones: Set<String>
    /// 布景构件的标识（`SetPiece.id` 是坐标派生的字符串）。
    public var setPieces: Set<String>

    public init(positions: Set<String> = [], fixtures: Set<Int> = [],
                zones: Set<String> = [], setPieces: Set<String> = []) {
        self.positions = positions
        self.fixtures = fixtures
        self.zones = zones
        self.setPieces = setPieces
    }

    public static let empty = Selection()

    public var isEmpty: Bool {
        positions.isEmpty && fixtures.isEmpty && zones.isEmpty && setPieces.isEmpty
    }

    public var count: Int {
        positions.count + fixtures.count + zones.count + setPieces.count
    }
}

/// 编辑器状态。
public struct EditorState: Sendable {
    public var doc: LXDocument
    /// 平面图的版面：纸幅、比例、图框原点。
    public var layout: SheetLayout
    public var viewport: Viewport
    public var selection: Selection

    /// 撤销栈：保存的是文档与版面的快照。
    /// 文档只有几百个实体，快照比"逆操作"简单且不会出错。
    var undoStack: [(LXDocument, SheetLayout)] = []
    var redoStack: [(LXDocument, SheetLayout)] = []

    /// 撤销栈深度。
    ///
    /// 200 对一次真实的设计会话太浅 —— 调一版灯光就有几百次操作，
    /// 用户会发现"想撤回到半小时前"已经撤不动了。
    /// 1000 步在内存上可以接受（每步是一份文档快照，
    /// 本项目文档约 3–8KB，1000 步约 8MB），
    /// 换来的是一整个工作日的历史。
    public static let maxUndoDepth = 1000

    public init(doc: LXDocument, layout: SheetLayout? = nil,
                viewport: Viewport = Viewport()) {
        self.doc = doc
        let l = layout ?? SheetLayout.fitted(to: doc.contentBounds,
                                             paper: .a1,
                                             scaleDenominator: doc.meta.scale)
        self.layout = l
        self.viewport = viewport.fitted(to: l.outerFrame, padding: 12)
        self.selection = .empty
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public var issues: [LintIssue] { Lint.check(doc) }

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }
}

/// 吸附结果。
public struct SnapResult: Equatable, Sendable {
    public var point: Vec2
    public var kind: SnapKind?
    public var distance: Double

    public enum SnapKind: String, Sendable, Equatable {
        case endpoint      // 构件端点
        case collinear     // 共线延长线上
        case grid          // 网格
        case axis          // 与另一构件同 x 或同 y
        case fixtureSlot   // 构件上的灯具位置

        /// 吸附指示器上显示的文字。
        public var label: String {
            switch self {
            case .endpoint:    return "END"
            case .collinear:   return "ON BAR"
            case .grid:        return "GRID"
            case .axis:        return "ALIGNED"
            case .fixtureSlot: return "LANTERN"
            }
        }
    }
}

/// 吸附配置。
public struct SnapOptions: Sendable, Equatable {
    /// 吸附半径（图纸 mm）。屏幕上约 8pt 时最好用。
    public var radius: Double
    public var gridStep: Double
    public var enabled: Bool

    public init(radius: Double = 4.0, gridStep: Double = 250, enabled: Bool = true) {
        self.radius = radius
        self.gridStep = gridStep
        self.enabled = enabled
    }
}

// MARK: - 文档级编辑

/// 文档设置字段。
///
/// 做成枚举而不是"给整个 meta 赋值"，是为了让撤销粒度合理：
/// 改一次标题只压一个撤销点，而不是把整份 meta 快照一次。
public enum MetaField: String, Sendable, CaseIterable {
    case show, playwright, venue, sheetTitle
    case date, revision, revNote, director, designer

    public var title: String {
        switch self {
        case .show:       return "Show"
        case .playwright: return "Playwright"
        case .venue:      return "Venue"
        case .sheetTitle: return "Sheet title"
        case .date:       return "Date"
        case .revision:   return "Revision"
        case .revNote:    return "Revision note"
        case .director:   return "Director"
        case .designer:   return "Designer"
        }
    }
}

/// 场地字段。
public enum StageField: String, Sendable, CaseIterable {
    case width, depth, gridHeight, prosceniumHeight, prosceniumX
    case audienceRows, audienceRowDepth, audienceRake

    public var title: String {
        switch self {
        case .width:             return "Stage width"
        case .depth:             return "Stage depth"
        case .gridHeight:        return "Grid height"
        case .prosceniumHeight:  return "Proscenium height"
        case .prosceniumX:       return "Plaster line"
        case .audienceRows:      return "Audience rows"
        case .audienceRowDepth:  return "Row depth"
        case .audienceRake:      return "Rake per row"
        }
    }

    public var isCount: Bool { self == .audienceRows }
}

extension EditorEvent {
    /// 类型安全的构造入口。
    public static func setMeta(_ field: MetaField, _ value: String) -> EditorEvent {
        ._setMeta(field.rawValue, value)
    }
    public static func setStage(_ field: StageField, _ value: Double) -> EditorEvent {
        ._setStage(field.rawValue, value)
    }
}
