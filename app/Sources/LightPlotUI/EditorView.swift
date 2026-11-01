import SwiftUI
import LightPlotCore
import UniformTypeIdentifiers

/// 编辑器主界面。
///
/// 布局结构刻意做得很扁平：**一个顶层 GeometryReader**，里面只有画布。
/// 状态栏与工具栏都是浮层（overlay），不参与画布尺寸的计算。
///
/// 为什么这么在意这一点：早期版本用了嵌套的 GeometryReader + ZStack，
/// 内层拿到的尺寸是 834×161（被兄弟视图的固有高度带的），
/// 于是图纸按 161pt 高去适配，"只占了屏幕上一条"。
/// 画布尺寸必须只由**一个**来源决定，否则这类问题会反复出现且极难定位。
public struct EditorView: View {

    @StateObject private var model: EditorModel
    @State private var dragState: DragState?
    @State private var hoverPosition: String?
    /// 检查器默认**打开**。
///
/// 早先默认关闭，结果是：一个初学用户打开应用，看到一张图纸和几个图标，
/// 根本找不到改剧名、改场地、改灯具的地方 —— 整个应用看起来像个看图器。
/// 对非技术用户，"默认可见"比"界面干净"重要得多。
@State private var showInspector = true
    /// 缩放手势的基准值（每帧相除得到增量）。
    @State private var pinchBase: CGFloat = 1
    /// 缩放的锚点（画布中心）。
    @State private var pinchAnchor = Vec2(0, 0)

    /// iPad 竖屏（<900pt）时检查器是浮层，默认收起 ——
    /// 打开就盖住图纸右侧 1/3，用户会以为图被裁了。
    /// 需要改属性时点工具栏的侧栏按钮，或者点选对象后自动展开。

    public init(model: EditorModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 900 && geo.size.height >= 600


            let useInspector = showInspector && wide
            let canvasW = max(320, geo.size.width - (useInspector ? 287 : 0))
            let canvasH = max(320, geo.size.height)

            // 所有尺寸都显式给出，不依赖固有尺寸协商。
            //
            // 为什么不用 overlay：overlay 不参与布局，画布仍是整宽 834pt，
            // 图纸按 834 宽度适配后右半边落在检查器底下 ——
            // 实测只看得见图纸的 65%。
            // 为什么显式 frame：HStack 里 Canvas 没有固有尺寸时会被压到最小高度
            // （实测 161pt），整条编辑器变成一个细条。
            HStack(spacing: 0) {
                canvas(size: CGSize(width: canvasW, height: canvasH))
                    .frame(width: canvasW, height: canvasH)

                if useInspector {
                    Rectangle().fill(.black.opacity(0.10)).frame(width: 1, height: canvasH)
                    inspector
                        // 让开浮层工具栏。
                        //
                        // 工具栏是浮在画布之上的，窗口不够宽时会横跨到
                        // 检查器上方 —— 实测 900pt 窗口上，检查器最顶部的
                        // "场景"选择器被整块盖住，而切换场景是主要操作。
                        //
                        // **不用"判断会不会重叠"再决定**：那个判断依赖
                        // 工具栏的实测宽度，而它会随字体、语言、系统版本变。
                        // 无条件留一条固定间距，宽窗口下看起来就是正常留白。
                        .padding(.top, EditorModel.chromeTopPoints)
                        .frame(width: 286, height: canvasH)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .top) { floatingToolbar }
            .overlay(alignment: .bottom) { statusBar }
            .overlay(alignment: .trailing) {
                if showInspector && !wide {
                    narrowInspector(width: geo.size.width)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showInspector)
        }
        #if os(macOS)
        .frame(minWidth: 900, minHeight: 620)
        .toolbar { macToolbar }
        .navigationTitle(model.windowTitle)
        #endif
        .onAppear { model.requestExportHandler = { exportPDF() } }
        #if os(macOS)
        .sheet(isPresented: $showPageSetup) {
            PageSetupPanel(model: model)
        }
        #endif
        #if os(iOS)
        .sheet(item: $shareItem) { url in
            ShareSheet(items: [url])
        }
        #endif
    }

    // MARK: 画布

    @ViewBuilder
    private func canvas(size: CGSize) -> some View {
        let vSize = Vec2(size.width, size.height)
        let _ = (pinchAnchor = Vec2(size.width / 2, size.height / 2))
        if model.page == .section {
            SectionCanvasView(section: model.section,
                              viewport: model.viewport,
                              canvasSize: vSize,
                              autoFit: !model.userHasAdjustedView)
                .contentShape(Rectangle())
                .gesture(canvasGestures)
                .onAppear { model.setCanvasSize(vSize) }
                .onChange(of: size) { _, newValue in
                    model.setCanvasSize(Vec2(newValue.width, newValue.height))
                }
        } else {
        SheetCanvas(sheet: model.sheet,
                    viewport: model.viewport,
                    selection: model.state.selection,
                    showBeams: model.showBeams,
                    hoverPosition: hoverPosition,
                    autoFit: !model.userHasAdjustedView,
                    canvasSize: vSize)
            .contentShape(Rectangle())
            .gesture(canvasGestures)
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverPosition = model.hitPosition(at: Vec2(p.x, p.y), size: size)
                case .ended:
                    hoverPosition = nil
                }
            }
            .onTapGesture(count: 2) { p in
                model.handleDoubleClick(at: Vec2(p.x, p.y), size: size)
            }
            .onTapGesture { p in
                model.handleTap(at: Vec2(p.x, p.y), size: size)
            }
            .background(ScrollWheelCatcher { delta, location, magnify in
                if magnify != 0 {
                    model.zoom(by: 1 + magnify, around: Vec2(location.x, location.y))
                } else {
                    model.pan(by: Vec2(-delta.x, -delta.y))
                }
            })
            #else
            .onTapGesture { p in
                model.handleTap(at: Vec2(p.x, p.y), size: size)
            }
            #endif
            .onAppear { model.setCanvasSize(vSize) }
            .onChange(of: size) { _, newValue in
                model.setCanvasSize(Vec2(newValue.width, newValue.height))
            }
        }
    }

    // MARK: 检查器

    private var inspector: some View {
        InspectorPanel(model: model, showIssues: .constant(false))
            .background(.background)
    }

    private func narrowInspector(width: CGFloat) -> some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showInspector = false }
                }
            InspectorPanel(model: model, showIssues: .constant(false))
                .frame(width: min(340, width * 0.82))
                .background(.regularMaterial)
                .shadow(radius: 16, x: -4)
                .transition(.move(edge: .trailing))
        }
    }

    // MARK: 状态栏

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text("\(Int(model.zoomPercent))%")
            Divider().frame(height: 11)
            Text("1:\(Int(model.currentScaleDenominator))")
            Divider().frame(height: 11)
            HStack(spacing: 4) {
                Image(systemName: model.state.errorCount > 0
                      ? "exclamationmark.triangle.fill"
                      : (model.state.warningCount > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                Text(issueSummary)
            }
            .foregroundStyle(model.state.errorCount > 0
                             ? Color.red
                             : (model.state.warningCount > 0 ? Color.orange : Color.green))
        }
        .font(.system(size: 11, weight: .medium, design: .rounded))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.bottom, 12)
        .allowsHitTesting(false)
    }

    private var issueSummary: String {
        let e = model.state.errorCount, w = model.state.warningCount
        if e == 0 && w == 0 { return L10n.t("All checks pass") }
        if e > 0 { return "\(e) error, \(w) warning" }
        return "\(w) warning"
    }

    // MARK: 浮层工具栏

    /// 浮层工具栏。
    ///
    /// **必须能容忍窄窗口。** 最小窗口是 900pt，而按钮在 12pt 间距下
    /// 需要更宽 —— 早先直接裁掉最右边的"导出"，用户根本点不到。
    ///
    /// 三级降级：
    ///   1. 常规间距
    ///   2. 紧凑间距 + 更窄内边距
    ///   3. 横向可滚动（保证任何宽度下所有按钮都够得着）
    private var floatingToolbar: some View {
        ViewThatFits(in: .horizontal) {
            toolbarBar(spacing: 12, horizontalPadding: 14)
            toolbarBar(spacing: 8, horizontalPadding: 10)
            ScrollView(.horizontal, showsIndicators: false) {
                toolbarBar(spacing: 8, horizontalPadding: 10)
            }
        }
    }

    private func toolbarBar(spacing: CGFloat,
                            horizontalPadding: CGFloat) -> some View {
        HStack(spacing: spacing) {
            toolButton("arrow.uturn.backward", "Undo", enabled: model.state.canUndo) {
                model.dispatch(.undo)
            }
            toolButton("arrow.uturn.forward", "Redo", enabled: model.state.canRedo) {
                model.dispatch(.redo)
            }

            Divider().frame(height: 16)

            Menu {
                ForEach(model.addableTypes, id: \.self) { key in
                    Button(model.typeLabel(key)) { model.addFixture(type: key) }
                }
            } label: {
                Image(systemName: "light.max")
            }
            .disabled(model.state.selection.positions.isEmpty)
            .help("Add a lantern to the selected truss")

            Menu {
                Button { model.addBar(type: .truss) } label: {
                    Label("Truss", systemImage: "rectangle.split.3x1")
                }
                Button { model.addBar(type: .pipe) } label: {
                    Label("Pipe", systemImage: "minus.rectangle")
                }
                Button { model.addBar(type: .line) } label: {
                    Label("Line", systemImage: "line.diagonal")
                }
                Divider()
                Button { model.addSetPiece(kind: .rect) } label: {
                    Label("Set flat", systemImage: "rectangle")
                }
                Button { model.addSetPiece(kind: .stair) } label: {
                    Label("Stair", systemImage: "stairs")
                }
                Button { model.addSetPiece(kind: .line) } label: {
                    Label("Wall", systemImage: "rectangle.portrait")
                }
                Divider()
                Button { model.addZone() } label: {
                    Label("Acting zone", systemImage: "rectangle.dashed")
                }
            } label: {
                Image(systemName: "plus.square.on.square")
            }
            .help("Add a truss, set piece or zone")
            toolButton("arrow.triangle.merge", "Join trusses",
                       enabled: model.state.selection.positions.count == 2) {
                model.mergeSelection()
            }

            toolButton("trash", "Delete selection",
                       enabled: !model.state.selection.isEmpty) {
                deleteSelection()
            }

            Divider().frame(height: 16)

            Picker("", selection: Binding(
                get: { model.page },
                set: { model.switchPage($0) }
            )) {
                ForEach(EditorModel.SheetPage.allCases, id: \.self) { p in
                    Text(p.title).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 120)

            if model.hasStates && model.page == .plan {
                Divider().frame(height: 16)
                Menu {
                    Button {
                        model.selectState(nil)
                    } label: {
                        Label(L10n.t("Base (no scene)"),
                              systemImage: model.activeStateID == nil ? "checkmark" : "")
                    }
                    Divider()
                    ForEach(model.states.states) { st in
                        Button {
                            model.selectState(st.id)
                        } label: {
                            Label("\(st.act.isEmpty ? "" : st.act + " — ")\(st.name)",
                                  systemImage: model.activeStateID == st.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    Label(model.activeState?.name ?? L10n.t("Scene"),
                          systemImage: "theatermasks")
                }
                .help("Show this plan in a scene state")
            }

            Divider().frame(height: 16)

            toolButton(model.showBeams ? "rays" : "circle.dashed", "Beams", enabled: true) {
                model.toggleBeams()
            }
            toolButton("arrow.up.left.and.arrow.down.right", "Fit", enabled: true) {
                model.fitToSheet()
            }
            toolButton("doc.badge.gearshape", "Page Setup", enabled: true) {
                showPageSetup = true
            }

            toolButton("sidebar.right", "Inspector", enabled: true) {
                withAnimation(.easeInOut(duration: 0.2)) { showInspector.toggle() }
            }
            toolButton("square.and.arrow.down", "Save",
                       enabled: model.isDirty) {
                saveDocument()
            }
            Menu {
                Button {
                    exportPDF()
                } label: {
                    Label("Sheet PDF", systemImage: "doc.richtext")
                }
                Button {
                    exportSchedules()
                } label: {
                    Label("Tables (CSV)", systemImage: "tablecells")
                }
                if model.hasStates {
                    Button {
                        exportAllStates()
                    } label: {
                        Label("All scene sheets", systemImage: "square.stack")
                    }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export")
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        .padding(.top, 12)
    }

    private func toolButton(_ symbol: String, _ help: String,
                            enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 20, height: 18)
                .opacity(enabled ? 1 : 0.32)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    // MARK: macOS 原生工具栏

    #if os(macOS)
    @ToolbarContentBuilder
    private var macToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button { model.dispatch(.undo) } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!model.state.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button { model.dispatch(.redo) } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!model.state.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])

            Button("Page Setup…") { showPageSetup = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button { saveDocument() } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!model.isDirty && model.documentURL != nil)

            Button { exportPDF() } label: {
                Label("Export A1 PDF", systemImage: "square.and.arrow.up")
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
        }
    }

    /// 导出表格到用户选定的目录。
    private func exportSchedules() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export tables"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        model.exportSchedules(to: dir)
        #endif
    }

    /// 一次导出基础图 + 全部场景图。
    private func exportAllStates() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Export sheets"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        model.exportAllStates(to: dir)
        #endif
    }

    private func saveDocument() {
        if model.saveInPlace() { return }
        guard let url = FilePanels.chooseSaveDocument(
            suggested: (model.state.doc.meta.show.isEmpty ? "Untitled" : model.state.doc.meta.show) + ".lpx"
        ) else { return }
        model.save(to: url)
    }

    private func exportPDF() {
        // 按当前页导出：剖面页导 A3，平面页导 A1。
        if model.page == .section {
            guard let url = FilePanels.chooseSavePDF(suggested: model.defaultSectionFilename()) else { return }
            model.exportSectionPDF(to: url)
            return
        }
        guard let url = FilePanels.chooseSavePDF(
            suggested: model.state.doc.meta.show.isEmpty
                ? "LX Plan.pdf"
                : "\(model.state.doc.meta.show) LX Plan.pdf"
        ) else { return }
        model.exportPDF(to: url)
    }
    #else
    private func saveDocument() { _ = model.saveInPlace() }
    private func exportPDF() {
        let url = model.page == .section
            ? model.exportSectionPDF()
            : model.exportPDF()
        guard let url else { return }
        shareItem = url
    }

    /// iPad：表格导出到临时目录，然后把**第一个文件**交给分享面板。
    ///
    /// iOS 没有"选一个文件夹"的原生交互（`UIDocumentPicker` 是选文件）。
    /// 所以写进 App 的临时目录，再用系统分享面板让用户存到「文件」。
    /// 与 macOS 的差别只在"选位置"这一步，导出的内容完全一致 ——
    /// 两者都走 `EditorModel.exportSchedules`。
    private func exportSchedules() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightPlot Tables", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        let urls = model.exportSchedules(to: dir)
        shareItem = urls.first
    }

    /// iPad：一次导出所有场景的图纸，同样走分享面板。
    private func exportAllStates() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LightPlot Scenes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
        let urls = model.exportAllStates(to: dir)
        shareItem = urls.first
    }
    #endif

    /// iPad：导出后把文件交给系统分享面板。
    /// 否则用户只知道"导出成功"，却在任何地方都找不到那个 PDF。
    @State private var shareItem: URL? = nil
    /// 页面设置面板（macOS 上是 sheet）。
    @State private var showPageSetup = false

    /// 删除当前选中项。
    ///
    /// 分派到对应的删除事件 —— 每类物件有自己的清理逻辑
    /// （例如删杆时不能连灯一起删，删布景要清选择集）。
    private func deleteSelection() {
        let sel = model.state.selection
        var events: [EditorEvent] = []
        for unit in sel.fixtures.sorted() { events.append(.deleteFixture(unit: unit)) }
        for id in sel.positions.sorted() { events.append(.deletePosition(id: id)) }
        for id in sel.setPieces.sorted() { events.append(.deleteSetPiece(id: id)) }
        for id in sel.zones.sorted() { events.append(.deleteZone(id: id)) }
        guard !events.isEmpty else { return }
        model.dispatch(batch: events)
    }

    // MARK: 手势

    private enum DragState {
        case pan(last: Vec2)
        case moveBar(id: String, lastDoc: Vec2)
        case moveFixture(unit: Int)
        case resizeBar(id: String, end: EditorEvent.EndPoint)
        case moveSetPiece(id: String, lastDoc: Vec2)
        case marquee(origin: Vec2)
    }

    /// 画布手势组合。
    ///
    /// **iPad 必须有双指缩放**：只靠"适应图纸"按钮和拖拽，
    /// 用户没办法看清灯具标注（1:25 图上标注只有 2–3mm 高）。
    /// 同时把一个 MagnificationGesture 和 DragGesture 并行，
    /// 而不是嵌套 —— 嵌套会导致缩放中一松手就丢掉平移。
    private var canvasGestures: some Gesture {
        #if os(iOS)
        SimultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let delta = value / max(pinchBase, 0.0001)
                    pinchBase = value
                    model.zoom(by: delta, around: pinchAnchor)
                }
                .onEnded { _ in pinchBase = 1 },
            canvasDrag
        )
        #else
        canvasDrag
        #endif
    }

    private var canvasDrag: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let p = Vec2(value.location.x, value.location.y)
                let start = Vec2(value.startLocation.x, value.startLocation.y)
                if dragState == nil { dragState = beginDrag(at: start) }

                switch dragState {
                case .pan(let last):
                    model.pan(by: p - last)
                    dragState = .pan(last: p)

                case .moveBar(let id, let lastDoc):
                    model.clearSnapPreview()
                    let nowDoc = model.documentPoint(p)
                    model.dispatch(.movePosition(id: id, by: nowDoc - lastDoc))
                    dragState = .moveBar(id: id, lastDoc: nowDoc)

                case .moveFixture(let unit):
                    model.updateSnapPreview(at: model.paperPoint(p),
                                            excludingFixture: unit)
                    model.dispatch(.moveFixture(unit: unit, to: model.paperPoint(p)))

                case .resizeBar(let id, let end):
                    // 先更新吸附预览（用户要看见"会吸到哪"），再落点
                    model.updateSnapPreview(at: model.paperPoint(p), excluding: id)
                    model.dispatch(.setPositionEnd(id: id, which: end,
                                                   to: model.paperPoint(p)))

                case .moveSetPiece(let id, let lastDoc):
                    let nowDoc = model.documentPoint(p)
                    model.dispatch(.moveSetPiece(id: id, by: nowDoc - lastDoc))
                    // id 由坐标派生，移动后会变 —— 必须跟着更新，否则下一次拖动找不到它
                    dragState = .moveSetPiece(id: model.state.selection.setPieces.first ?? id,
                                              lastDoc: nowDoc)

                case .marquee(let origin):
                    let now = model.paperPoint(p)
                    model.dispatch(.marqueeSelect(Rect(x0: origin.x, y0: origin.y,
                                                       x1: now.x, y1: now.y)))

                case .none:
                    break
                }
            }
            .onEnded { _ in
                model.clearSnapPreview()
                dragState = nil
            }
    }

    private func beginDrag(at start: Vec2) -> DragState {
        let paper = model.paperPoint(start)
        if model.shiftPressed { return .pan(last: start) }

        switch model.hit(paper) {
        case .fixture(let unit):
            return .moveFixture(unit: unit)

        case .position(let id):
            guard let pos = model.state.doc.position(id: id), let shape = pos.shape else {
                return .pan(last: start)
            }
            // 端点 14pt 内 = 拖端点改长度；否则 = 整根平移
            if start.distance(to: model.toView(shape.start)) < 14 {
                return .resizeBar(id: id, end: .start)
            }
            if start.distance(to: model.toView(shape.end)) < 14 {
                return .resizeBar(id: id, end: .end)
            }
            model.dispatch(.select(.init(positions: [id])))
            return .moveBar(id: id, lastDoc: model.documentPoint(start))

        case .setPiece(let id):
            model.dispatch(.select(.init(setPieces: [id])))
            return .moveSetPiece(id: id, lastDoc: model.documentPoint(start))

        case .zone, .none:
            return .marquee(origin: paper)
        }
    }
}

#if os(macOS)
import AppKit

enum FilePanels {
    static func chooseSavePDF(suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [.pdf]
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// 保存文档。默认 `.lpx`（应用自己的稳定 JSON）。
    static func chooseSaveDocument(suggested: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggested
        panel.allowedContentTypes = [UTType(filenameExtension: "lpx") ?? .json]
        return panel.runModal() == .OK ? panel.url : nil
    }
}
#endif
