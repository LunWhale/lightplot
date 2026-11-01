import SwiftUI
import LightPlotCore
import Combine

/// 编辑器视图模型。
///
/// 职责边界很硬：
///   · 持有 `EditorState`（唯一的真相）
///   · 把 UI 坐标换算成图纸坐标（**唯一**做这层换算的地方）
///   · 派生只读数据给视图用（`sheet`、`issues`）
///
/// 它**不**实现任何编辑逻辑 —— 那是 `Editor.reduce` 的事。
@MainActor
public final class EditorModel: ObservableObject {

    @Published public private(set) var state: EditorState
    /// 场景集（来自同目录的 scenes.yaml）。空 = 没有场景数据。
    @Published public private(set) var states = LightingStateSet()
    /// 当前查看的场景。nil = 基础图（用文档原本的色片）。
    @Published public private(set) var activeStateID: String?

    @Published public private(set) var sheet: PlanSheet
    @Published public private(set) var section: SectionSheet
    /// 当前显示哪一页。两页共用同一个文档与撤销栈。
    @Published public var page: SheetPage = .plan
    @Published public var showBeams = true
    @Published public var shiftPressed = false

    private var canvasSize = Vec2(900, 640)
    private var userAdjustedView = false

    /// 用户是否手动接管了视角（缩放/平移过）。
    /// 没有接管时，画布每帧按自己的真实尺寸做自动适配 —— 这是布局稳健的关键。
    public var userHasAdjustedView: Bool { userAdjustedView }
    /// 由视图层注入的导出入口（iOS 要用 share sheet，macOS 要用 NSSavePanel）。
    /// 模型本身不依赖任何 UI 框架 —— 这样 `exportPDF()` 才能被测试直接调用。
    public var requestExportHandler: (() -> Void)?

    /// 当前文档的保存位置。nil = 还没存过（新文档）。
    @Published public private(set) var documentURL: URL?

    /// 是否与磁盘上的版本不同。标题栏靠它显示"已编辑"。
    @Published public private(set) var isDirty = false

    /// 画布真实尺寸（由 Canvas 在绘制时回报）。诊断与测试用。
    public var debugCanvasSize: Vec2 { canvasSize }

    /// 拖动时的吸附预览。
    ///
    /// **纯视图状态，不进文档、不进撤销栈。**
    /// 没有它，用户拖动构件端点时只能猜"会不会吸上"——
    /// 而吸附是这套编辑器最核心的交互，看不见就没有意义。
    @Published public private(set) var snapPreview: SnapPreview?

    public struct SnapPreview: Equatable {
        /// 吸附点（图纸 mm）。
        public let point: Vec2
        public let kind: SnapResult.SnapKind
        /// 鼠标原始位置（图纸 mm）—— 用来画"原始位置 → 吸附位置"的引线。
        public let raw: Vec2
    }

    /// 在拖动过程中更新吸附预览。
    public func updateSnapPreview(at paperPoint: Vec2, excluding: String? = nil,
                                  excludingFixture: Int? = nil) {
        let r = Snapper.snap(paperPoint, doc: state.doc, layout: state.layout,
                             viewport: viewport, options: SnapOptions(),
                             excludingPosition: excluding,
                             excludingFixture: excludingFixture)
        if let kind = r.kind, r.point.distance(to: paperPoint) > 0.01 {
            snapPreview = SnapPreview(point: r.point, kind: kind, raw: paperPoint)
        } else {
            snapPreview = nil
        }
    }

    public func clearSnapPreview() {
        if snapPreview != nil { snapPreview = nil }
    }
    public private(set) var rootSize = Vec2.zero
    public func noteRootSize(_ s: Vec2) {
        if abs(s.x - rootSize.x) > 0.5 || abs(s.y - rootSize.y) > 0.5 {
            rootSize = s
        }
    }
    public var debugViewport: String {
        let vp = viewport
        return String(format: "%.2f R%.0fx%.0f", vp.zoom, rootSize.x, rootSize.y)
    }

    public init(doc: LXDocument) {
        let s = EditorState(doc: doc)
        self.state = s
        self.sheet = PlanSheet(doc: s.doc, layout: s.layout)
        self.section = SectionSheet(fitting: s.doc)
    }

    public enum SheetPage: String, CaseIterable, Sendable {
        case plan, section
        public var title: String {
            switch self {
            case .plan:    return L10n.t("Plan")
            case .section: return L10n.t("Section")
            }
        }
    }

    public convenience init() {
        self.init(doc: LXDocument())
    }

    // MARK: 派生

    /// 当前视口。
    ///
    /// **关键设计：当用户还没有手动接管视角时，每次都从当前画布尺寸现算适配。**
    ///
    /// 早期版本靠"尺寸变化时调用一次 fitToSheet"，结果在 iPad 上会用到
    /// 布局中途的临时尺寸（ZStack 还没有固有高度时约 373pt），
    /// 于是图纸按错误的高度缩小，看起来只占了半边。
    /// 改成派生值之后，无论中间经历多少个临时尺寸，最终渲染一定用最终尺寸。
    public var viewport: Viewport {
        var vp = state.viewport
        vp.sizePoints = canvasSize
        if !userAdjustedView {
            // 与 `fitToSheet()` 用同一组内缩 —— 两者不一致的话，
            // 初始视角会把图纸顶到工具栏底下，用户第一次看到的就是被遮住的图。
            vp = vp.fitted(to: currentPaperFrame, padding: 16,
                           topInset: Self.chromeTopPoints,
                           bottomInset: Self.chromeBottomPoints)
        }
        return vp
    }

    public var zoomPercent: Double { state.viewport.zoom * 100 }

    /// **当前这一页**的绘图比例。
    ///
    /// 平面图用文档比例（通常 1:25），剖面图固定 1:50。
    /// 状态栏早先直接读 `state.layout.scaleDenominator`，
    /// 于是在剖面页上显示 1:25 —— 而那张纸实际上是 1:50。
    /// 读图的人会用这个数字去量距离，所以它必须跟着页面走。
    public var currentScaleDenominator: Double {
        switch page {
        case .plan:    return state.layout.scaleDenominator
        case .section: return section.layout.scaleDenominator
        }
    }

    /// 当前场景（nil = 基础图）。
    public var activeState: LightingState? {
        activeStateID.flatMap { states.state(id: $0) }
    }

    /// 切换场景。会立刻重排平面图（色片跟着变）。
    public func selectState(_ id: String?) {
        guard id != activeStateID else { return }
        activeStateID = id
        rebuildSheet()
    }

    public var hasStates: Bool { !states.isEmpty }

    /// 载入场景文件。与文档一起打开时自动调用。
    public func loadStates(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let set = try? LightingStateCodec.decodeYAML(data) else { return }
        states = set
        activeStateID = nil
        rebuildSheet()
    }

    /// 直接从内存装场景（测试与脚本用）。
    public func loadStatesFromMemory(_ set: LightingStateSet) {
        states = set
        activeStateID = nil
        rebuildSheet()
    }

    /// 当前场景的对比说明（与另一个场景相比。
    public func contrast(with otherID: String) -> LightingStateSet.Contrast? {
        guard let a = activeState, let b = states.state(id: otherID) else { return nil }
        return states.contrast(a, b, doc: state.doc)
    }

    /// 当前页的纸张外框（平面 A1 / 剖面 A3）。
    public var currentPaperFrame: Rect {
        switch page {
        case .plan:    return state.layout.outerFrame
        case .section:
            let p = section.layout.paper
            return Rect(x0: 0, y0: 0, x1: p.widthMM, y1: p.heightMM)
        }
    }

    public func switchPage(_ newPage: SheetPage) {
        guard newPage != page else { return }
        page = newPage
        userAdjustedView = false
        fitToSheet()
    }

    public var windowTitle: String {
        let name = state.doc.meta.show
        let base = name.isEmpty ? L10n.t("Untitled") : name
        return isDirty ? base + " — " + L10n.t("Edited") : base
    }

    public var issues: [LintIssue] { state.issues }

    public var selectionCount: Int { state.selection.count }

    public var addableTypes: [String] { state.doc.types.keys.sorted() }

    public var selectedFixture: Fixture? {
        guard let unit = state.selection.fixtures.first else { return nil }
        return state.doc.fixture(unit: unit)
    }

    public var selectedPosition: Position? {
        guard let id = state.selection.positions.first else { return nil }
        return state.doc.position(id: id)
    }

    public var selectedSetPiece: SetPiece? {
        guard let id = state.selection.setPieces.first else { return nil }
        return state.doc.setPieces.first { $0.id == id }
    }

    public var selectedZone: Zone? {
        guard let id = state.selection.zones.first else { return nil }
        return state.doc.zone(id: id)
    }

    public func typeLabel(_ key: String) -> String {
        state.doc.types[key]?.label ?? key
    }

    // MARK: 坐标换算（唯一入口）

    /// 画布尺寸变化。
    ///
    /// 首次布局与旋转设备时都要重新适配 —— 否则竖屏下图纸会跑出屏幕。
    /// 但用户已经手动缩放/平移过之后就不再自动重置，那会抢走控制权。
    public func setCanvasSize(_ size: Vec2) {
        guard size.x > 1, size.y > 1 else { return }
        let changed = abs(size.x - canvasSize.x) > 0.5 || abs(size.y - canvasSize.y) > 0.5
        guard changed else { return }
        canvasSize = size
        // 尺寸变化本身不改 state.viewport —— 适配由 `viewport` 派生计算。
        // 但需要让 SwiftUI 重绘，所以发一个无变化的通知。
        objectWillChange.send()
    }

    /// 屏幕点 → 图纸 mm。
    public func paperPoint(_ view: Vec2) -> Vec2 { viewport.toSheet(view) }

    /// 屏幕点 → 文档 mm（真实尺寸）。
    public func documentPoint(_ view: Vec2) -> Vec2 {
        state.layout.toDocument(paperPoint(view))
    }

    /// 图纸 mm → 屏幕点。
    public func toView(_ docPoint: Vec2) -> Vec2 {
        viewport.toView(state.layout.toSheet(docPoint))
    }

    public func hit(_ paper: Vec2) -> Editor.Hit? {
        Editor.hitTest(paper, doc: state.doc, layout: state.layout)
    }

    public func hitPosition(at view: Vec2, size: CGSize) -> String? {
        switch Editor.hitTest(paperPoint(view), doc: state.doc, layout: state.layout) {
        case .position(let id): return id
        default: return nil
        }
    }

    public func fixtureAnchor(_ unit: Int) -> Vec2? {
        guard let f = state.doc.fixture(unit: unit),
              let w = state.doc.worldPoint(of: f) else { return nil }
        return state.layout.toSheet(w)
    }

    // MARK: 事件分发

    public func dispatch(_ event: EditorEvent) {
        apply(Editor.reduce(state, event))
    }

    public func dispatch(batch: [EditorEvent]) {
        apply(Editor.reduce(state, batch: batch))
    }

    private func apply(_ next: EditorState) {
        let docChanged = next.doc != state.doc || next.layout != state.layout
        state = next
        if docChanged {
            rebuildSheet()
            isDirty = true
        }
    }

    // MARK: 保存 / 打开

    /// 保存到指定位置（`.lpx` = 稳定 JSON）。
    @discardableResult
    public func save(to url: URL) -> Bool {
        var out = url
        if out.pathExtension.isEmpty { out.appendPathExtension("lpx") }
        do {
            let data = try DocumentCodec.encodeJSON(state.doc)
            try data.write(to: out, options: .atomic)
            documentURL = out
            isDirty = false
            return true
        } catch {
            return false
        }
    }

    /// 保存到当前位置；没存过则返回 false（调用方应弹出保存面板）。
    @discardableResult
    public func saveInPlace() -> Bool {
        guard let url = documentURL else { return false }
        return save(to: url)
    }

    /// 打开文档。支持 `.lpx`（JSON）与 `.yaml`（旧管线格式）。
    public func open(url: URL) throws {
        let data = try Data(contentsOf: url)
        var doc: LXDocument
        switch url.pathExtension.lowercased() {
        case "yaml", "yml":
            doc = try DocumentCodec.decodeYAML(data)
        case "lpx":
            doc = try DocumentCodec.decodeJSON(data)
        default:
            // 未知扩展名：先试 JSON 再试 YAML
            if let asJSON = try? DocumentCodec.decodeJSON(data) {
                doc = asJSON
            } else {
                doc = try DocumentCodec.decodeYAML(data)
            }
        }
        // 补全色片真实颜色（只填空缺）—— 打开的旧数据立即可读
        _ = GelLibrary.fillMissingColours(in: &doc)

        state = EditorState(doc: doc)
        section = SectionSheet(fitting: doc)
        rebuildSheet()
        // 同目录若有 scenes.yaml，自动载入 —— 用户不该被迫手动再开一次。
        let sibling = url.deletingLastPathComponent().appendingPathComponent("scenes.yaml")
        if FileManager.default.fileExists(atPath: sibling.path) {
            loadStates(from: sibling)
        } else {
            states = LightingStateSet()
            activeStateID = nil
        }

        // 只有 .lpx 才算"已保存的文件"；
        // 从 yaml 打开后再存不会覆盖原文件（旧管线的注释与排版都在里面）。
        documentURL = url.pathExtension.lowercased() == "lpx" ? url : nil
        isDirty = false
        userAdjustedView = false
    }

    /// 换一份新文档。
    public func replaceDocument(_ doc: LXDocument) {
        var d = doc
        _ = GelLibrary.fillMissingColours(in: &d)
        state = EditorState(doc: d)
        section = SectionSheet(fitting: d)
        rebuildSheet()
        documentURL = nil
        isDirty = false
        userAdjustedView = false
    }

    /// 重建指令列表。文档或版面变了才需要重建 ——
    /// 纯缩放不必重建（画布直接按 viewport 变换），所以这里刻意不监听 viewport。
    private func rebuildSheet() {
        sheet = PlanSheet(doc: state.doc, layout: state.layout,
                          lightingState: activeState)
        // 剖面图每次跟着文档一起重建 —— 它与平面图必须永远描述同一份数据。
        section = SectionSheet(fitting: state.doc)
    }

    // MARK: 交互

    public func handleTap(at view: Vec2, size: CGSize) {
        let p = paperPoint(view)
        dispatch(.selectAt(p, additive: shiftPressed))
    }

    public func handleDoubleClick(at view: Vec2, size: CGSize) {
        // 双击灯具 = 选中并进入 aim 编辑（检查器里会出现角度滑杆）
        let p = paperPoint(view)
        if case .fixture(let unit)? = hit(p) {
            dispatch(.select(.init(fixtures: [unit])))
        }
    }

    public func zoom(by factor: Double, around view: Vec2) {
        var s = state
        var vp = viewport
        vp.sizePoints = canvasSize
        vp = vp.zoomed(by: factor, around: view)
        s.viewport = vp
        state = s
        userAdjustedView = true
    }

    public func pan(by delta: Vec2) {
        var s = state
        var vp = viewport
        vp.sizePoints = canvasSize
        s.viewport = vp.panned(by: delta)
        state = s
        userAdjustedView = true
    }

    /// 把整张图纸放进画布。
    ///
    /// `fitted` 用 min(sx, sy)，所以在竖屏（画布高窄）时按高度缩，
    /// 整张横版图纸必然完整可见 —— 这正是我们要的：
    /// **宁可字小，也不能把图裁掉一半。** 用户想看清细节就双指放大。
    /// 回到"自动适配"。之后视口随画布尺寸自动重算。
    /// 画布上下被浮层遮住的点数（工具栏 / 状态栏）。
    ///
    /// 与 `EditorView` 里那两个浮层的实际高度对应。写在这里而不是
    /// 视图里，是因为**适配算法需要它**：不预留就会把图纸顶到工具栏底下。
    public static let chromeTopPoints: Double = 56
    public static let chromeBottomPoints: Double = 44

    public func fitToSheet() {
        var s = state
        var vp = state.viewport
        vp.sizePoints = canvasSize
        s.viewport = vp.fitted(to: currentPaperFrame, padding: 16,
                               topInset: Self.chromeTopPoints,
                               bottomInset: Self.chromeBottomPoints)
        state = s
        userAdjustedView = false
    }

    /// 缩放到"图纸宽度刚好铺满画布"。竖屏下用它来看清左右细节。
    public func fitToWidth() {
        var s = state
        var vp = state.viewport
        vp.sizePoints = canvasSize
        let frame = state.layout.outerFrame
        let zoom = max(0.02, (canvasSize.x - 24) / max(frame.width, 1))
        vp.zoom = min(zoom, 400)
        vp.pan = Vec2(canvasSize.x / 2 - frame.center.x * vp.zoom,
                      canvasSize.y / 2 + frame.center.y * vp.zoom)
        s.viewport = vp
        state = s
        userAdjustedView = true
    }

    public func toggleBeams() { showBeams.toggle() }

    // MARK: 工具栏动作

    public func addFixture(type: String) {
        // 落在选中构件的中心；没有选中构件则落在舞台中部
        let position: Vec2
        if let id = state.selection.positions.first,
           let pos = state.doc.position(id: id), let shape = pos.shape {
            position = state.layout.toSheet(shape.midpoint)
        } else {
            position = state.layout.toSheet(Vec2(0, state.doc.stage.depth / 2))
        }
        let f = Fixture(unit: 0, type: type, aim: 90,
                        gel: type == "led" || type == "mover" || type == "follow" ? "OPEN" : "L201",
                        purpose: "UNASSIGNED",
                        beam: type == "fresnel" ? 45 : (type == "par" ? 25 : 26))
        dispatch(.addFixture(f, at: position))
    }

    public func addBar(type: PositionType) {
        let centre = state.layout.toDocument(
            viewport.toSheet(Vec2(canvasSize.x / 2, canvasSize.y / 2)))
        let half: Double = 4000
        var id = "LX NEW"
        var n = 1
        while state.doc.position(id: id) != nil { n += 1; id = "LX NEW \(n)" }

        let bar = Position(id: id, kind: .horizontal, type: type,
                           x0: centre.x - half, x1: centre.x + half,
                           y: centre.y, trim: 6500)
        dispatch(.addPosition(bar))
    }

    /// 在视野中心附近加一块布景。
    ///
    /// 剖面图需要 `height` 才有意义，所以这里给一个按类型的合理缺省，
    /// 用户随后可以在检查器里改。
    public func addSetPiece(kind: SetPieceKind) {
        let centre = state.layout.toDocument(
            viewport.toSheet(Vec2(canvasSize.x / 2, canvasSize.y / 2)))
        let halfW: Double = kind == .line ? 2000 : 1200
        let halfD: Double = kind == .line ? 40 : 700
        let piece = SetPiece(kind: kind,
                             x0: centre.x - halfW, y0: centre.y - halfD,
                             x1: centre.x + halfW, y1: centre.y + halfD,
                             label: kind == .stair ? "STAIR" : "SET",
                             steps: kind == .stair ? 12 : nil,
                             height: doc_defaultHeight(kind))
        dispatch(.addSetPiece(piece))
    }

    private func doc_defaultHeight(_ kind: SetPieceKind) -> Double {
        switch kind {
        case .stair: return 2400
        case .rect:  return 750
        case .line:  return 2400
        }
    }

    /// 加一个表演区。名字自动递增，避免覆盖已有的。
    public func addZone() {
        let centre = state.layout.toDocument(
            viewport.toSheet(Vec2(canvasSize.x / 2, canvasSize.y / 2)))
        var n = state.doc.zones.count + 1
        var id = "Z\(n)"
        while state.doc.zone(id: id) != nil { n += 1; id = "Z\(n)" }
        dispatch(.addZone(Zone(id: id,
                               x0: centre.x - 2500, y0: centre.y - 2000,
                               x1: centre.x + 2500, y1: centre.y + 2000)))
    }

    /// 删掉当前选中的布景与光区。
    ///
    /// 一次手势删除多项时只压一个撤销点 —— 否则撤销要按很多次。
    public func deleteSelectedExtras() {
        var events: [EditorEvent] = []
        for id in state.selection.setPieces.sorted() {
            events.append(.deleteSetPiece(id: id))
        }
        for id in state.selection.zones.sorted() {
            events.append(.deleteZone(id: id))
        }
        guard !events.isEmpty else { return }
        dispatch(batch: events)
    }

    public func mergeSelection() {
        let ids = Array(state.selection.positions)
        guard ids.count == 2 else { return }
        let sorted = ids.sorted()
        dispatch(.mergePositions(keep: sorted[0], absorb: sorted[1]))
    }

    // MARK: 导出

    public enum ExportError: LocalizedError {
        case noDestination
        case writeFailed(String)
        public var errorDescription: String? {
            switch self {
            case .noDestination: return L10n.t("Choose where to save the PDF.")
            case .writeFailed(let m): return m
            }
        }
    }

    /// 导出 A1 PDF。返回写出的路径，失败返回 nil。
    ///
    /// iPad 上的默认目标是 `Documents/`：应用开了 `UIFileSharingEnabled`，
    /// 导出的文件会直接出现在「文件」App 的 LightPlot 文件夹里 ——
    /// 否则用户拿到一个路径却打不开那个文件。
    @discardableResult
    public func exportPDF(to url: URL? = nil) -> URL? {
        let target: URL
        if let url {
            target = url
        } else {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            target = dir.appendingPathComponent(defaultExportFilename())
        }

        var doc = state.doc
        _ = GelLibrary.fillMissingColours(in: &doc)
        // 导出**当前场景**（若在看某个场景）—— 否则导出的图会印错色号。
        let sheet = PlanSheet(fitting: doc, paper: state.layout.paper,
                              scale: state.layout.scaleDenominator,
                              lightingState: activeState)
        do {
            try SheetPDF.write(sheet, to: target)
            lastExportedURL = target
            return target
        } catch {
            return nil
        }
    }

    /// 导出剖面图 PDF（A3 @ 1:50）。
    @discardableResult
    public func exportSectionPDF(to url: URL? = nil) -> URL? {
        let target: URL
        if let url {
            target = url
        } else {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            target = dir.appendingPathComponent(defaultSectionFilename())
        }
        var doc = state.doc
        _ = GelLibrary.fillMissingColours(in: &doc)
        do {
            try SheetPDF.write(SectionSheet(fitting: doc), to: target)
            lastExportedURL = target
            return target
        } catch {
            return nil
        }
    }

    public func defaultSectionFilename() -> String {
        let show = state.doc.meta.show
        let base = show.isEmpty ? "Section" : "\(show) Section"
        let safe = base.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return safe + ".pdf"
    }

    /// 导出的 PDF 文件名。剧名里的斜杠等字符会破坏路径，先清洗。
    public func defaultExportFilename() -> String {
        let show = state.doc.meta.show
        var base = show.isEmpty ? "LX Plan" : "\(show) LX Plan"
        // 场景图带上场景名，否则三张图会互相覆盖
        if let st = activeState {
            base += " " + Stem.sanitize(st.name)
        }
        return Stem.sanitize(base) + ".pdf"
    }

    /// 导出全部 CSV 表格（灯具表 / 通道表 / 色片用量 / 场景对照）。
    @discardableResult
    public func exportSchedules(to dir: URL) -> [URL] {
        var doc = state.doc
        _ = GelLibrary.fillMissingColours(in: &doc)
        return ScheduleCSV.writeAll(doc, states: states, to: dir,
                                    prefix: doc.meta.show)
    }

    /// 一次导出**全部场景**（基础 + 每个状态）。
    /// 返回写出的文件列表。
    @discardableResult
    public func exportAllStates(to dir: URL) -> [URL] {
        var doc = state.doc
        _ = GelLibrary.fillMissingColours(in: &doc)
        var out: [URL] = []
        let show = doc.meta.show.isEmpty ? "LX Plan" : "\(doc.meta.show) LX Plan"

        func write(_ name: String, _ st: LightingState?) {
            let sheet = PlanSheet(fitting: doc, paper: state.layout.paper,
                                  scale: state.layout.scaleDenominator,
                                  lightingState: st)
            let url = dir.appendingPathComponent(Stem.sanitize(name) + ".pdf")
            if (try? SheetPDF.write(sheet, to: url)) != nil { out.append(url) }
        }

        write(show, nil)
        for st in states.states { write("\(show) \(st.name)", st) }
        return out
    }

    /// 最近一次导出的文件位置（供 iPad 的分享面板直接取用）。
    @Published public private(set) var lastExportedURL: URL?
}
