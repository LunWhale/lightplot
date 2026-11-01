import SwiftUI
import LightPlotCore

/// 检查器：选中什么就显示什么；没有选中时显示文档与场地。
///
/// 这一栏承担了"让工具真的能用"的责任 —— 用户必须能在这里
/// **输入真实场地尺寸**，否则出图再漂亮也是废纸。
public struct InspectorPanel: View {
    @ObservedObject var model: EditorModel

    public init(model: EditorModel, showIssues: Binding<Bool> = .constant(false)) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let f = model.selectedFixture {
                    fixtureSection(f)
                    Divider().padding(.vertical, 10)
                    sheetSection
                } else if let p = model.selectedPosition {
                    positionSection(p)
                    Divider().padding(.vertical, 10)
                    sheetSection
                } else if let piece = model.selectedSetPiece {
                    setPieceSection(piece)
                    Divider().padding(.vertical, 10)
                    sheetSection
                } else if let zone = model.selectedZone {
                    zoneSection(zone)
                    Divider().padding(.vertical, 10)
                    sheetSection
                } else {
                    stateSection
                    sheetSection
                    Divider().padding(.vertical, 10)
                    stageSection
                    Divider().padding(.vertical, 10)
                    selectionHint
                }

                Divider().padding(.vertical, 10)
                issuesSection
            }
            .padding(14)
        }
        .background(.background)
    }

    // MARK: - 图纸 / 演出信息

    private var sheetSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            header(L10n.t("Sheet"))

            field(.show, model.state.doc.meta.show)
            field(.playwright, model.state.doc.meta.playwright)
            field(.venue, model.state.doc.meta.venue)
            field(.director, model.state.doc.meta.director)
            field(.designer, model.state.doc.meta.designer)
            field(.sheetTitle, model.state.doc.meta.sheetTitle)
            field(.date, model.state.doc.meta.date)
            field(.revision, model.state.doc.meta.revision)

            HStack {
                Text(L10n.t("Scale"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { Int(model.state.layout.scaleDenominator) },
                    set: { model.dispatch(.setScale(Double($0))) }
                )) {
                    Text("1:20").tag(20)
                    Text("1:25").tag(25)
                    Text("1:50").tag(50)
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 84)
            }

            HStack {
                Text(L10n.t("Paper"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.state.layout.paper },
                    set: { model.dispatch(.setPaper($0)) }
                )) {
                    ForEach(PaperSize.all, id: \.self) { p in
                        Text(p.name).tag(p)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 84)
            }

            // 明确告诉用户"这张纸能装多大的场地"。
            // 没有这行，用户只能靠"装不下"这条错误反推，不知道该改纸还是改比例。
            let cap = SheetLayout.capacity(paper: model.state.layout.paper,
                                           scale: model.state.layout.scaleDenominator)
            Text(String(format: L10n.t("Fits %.1f x %.1f m at 1:%.0f"),
                        cap.x / 1000, cap.y / 1000,
                        model.state.layout.scaleDenominator))
                .font(.caption2).foregroundStyle(.tertiary)

            if !model.sheet.contentFitsSheet {
                let need = model.state.doc.contentBounds
                VStack(alignment: .leading, spacing: 2) {
                    Label(L10n.t("Does not fit on this sheet"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                    Text(String(format: "Content is %.1f x %.1f m",
                                need.width / 1000, need.height / 1000))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(L10n.t("Use a larger sheet or 1:50."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.dispatch(.autoFitOrigin)
            } label: {
                Label(L10n.t("Centre the plan"), systemImage: "scope")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            // 在纸上微调位置。
            //
            // 「居中」解决常见情形，但它只有一档。当图例或说明栏挤到图面、
            // 想整体挪开 5mm 时没有别的办法 —— 而"比例锁死、只移动图框"
            // 本来就是这套版面的设计原则，所以位置理应是可调的。
            //
            // 只挪图框、**不动比例**，装不下时照样报"装不下"。
            HStack(spacing: 4) {
                Text(L10n.t("Shift on paper"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                ForEach([("arrow.left", -5.0, 0.0), ("arrow.right", 5.0, 0.0),
                         ("arrow.down", 0.0, -5.0), ("arrow.up", 0.0, 5.0)],
                        id: \.0) { icon, dx, dy in
                    Button {
                        let o = model.state.layout.originOnSheet
                        model.dispatch(.setOrigin(Vec2(o.x + dx, o.y + dy)))
                    } label: {
                        Image(systemName: icon).font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }

    /// 输入一个文字字段。
    ///
    /// 用 `TextField` + `.onSubmit` 而不是每键一次 dispatch：
    /// 那样每敲一个字母都会压一个撤销点，撤销一次只退一个字符。
    private func field(_ field: MetaField, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.t(field.title))
                .font(.caption2).foregroundStyle(.secondary)
            TextField(L10n.t(field.title), text: Binding(
                get: { value },
                set: { model.dispatch(.setMeta(field, $0)) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.characters)
            #endif
        }
    }

    // MARK: - 场景

    /// 场景面板：切换 + 对比检查。
    ///
    /// 设计任务书要求"两个形成对比的场景"，而"对比够不够"是个
    /// 可量化的判断 —— 这里直接算给你看，而不是让你自我感觉。
    @ViewBuilder
    private var stateSection: some View {
        if model.hasStates {
            VStack(alignment: .leading, spacing: 8) {
                header(L10n.t("Scene"))

                Picker("", selection: Binding(
                    get: { model.activeStateID ?? "" },
                    set: { model.selectState($0.isEmpty ? nil : $0) }
                )) {
                    Text(L10n.t("Base")).tag("")
                    ForEach(model.states.states) { st in
                        Text(st.act.isEmpty ? st.name : "\(st.act)  \(st.name)").tag(st.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let active = model.activeState {
                    labeledValue(L10n.t("Lit"),
                                 "\(active.litCount(in: model.state.doc)) / \(model.state.doc.fixtures.count)")
                    let gels = active.usedGels(in: model.state.doc).filter { $0 != "OPEN" }
                    labeledValue(L10n.t("Gels"), "\(gels.count)")

                    // 与另一个场景的对比
                    ForEach(model.states.states.filter { $0.id != active.id }, id: \.id) { other in
                        if let c = model.contrast(with: other.id) {
                            contrastRow(other: other, c: c)
                        }
                    }
                } else {
                    Text(L10n.t("Base plan uses the document's own gels."))
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 一个场景的对比摘要。
    private func contrastRow(other: LightingState,
                             c: LightingStateSet.Contrast) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("vs " + other.name)
                .font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Label("\(c.gelDifferences) gel", systemImage: "paintpalette")
                Label("\(c.levelDifferences) level", systemImage: "sun.max")
            }
            .font(.caption2)
            .foregroundStyle(c.isSufficient ? Color.green : Color.orange)
            if !c.isSufficient {
                Text(L10n.t("Contrast may be too weak for two distinct scenes."))
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - 场地

    private var stageSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            header(L10n.t("Stage"))

            numberField(.width, model.state.doc.stage.width, unit: "mm")
            numberField(.depth, model.state.doc.stage.depth, unit: "mm")
            numberField(.gridHeight, model.state.doc.stage.gridHeight, unit: "mm")
            numberField(.prosceniumHeight, model.state.doc.stage.prosceniumHeight, unit: "mm")
            numberField(.prosceniumX, model.state.doc.stage.prosceniumX, unit: "mm")

            Divider().padding(.vertical, 2)

            Text(L10n.t("Audience"))
                .font(.caption.weight(.medium))
            numberField(.audienceRows, Double(model.state.doc.stage.audienceRows), unit: "rows", step: 1)
            numberField(.audienceRowDepth, model.state.doc.stage.audienceRowDepth, unit: "mm")
            numberField(.audienceRake, model.state.doc.stage.audienceRake, unit: "mm/row")

            // 视线检查结果直接显示在这里 —— 改 rake 能立刻看到效果。
            sightlineSummary
        }
    }

    private var sightlineSummary: some View {
        let sights = model.section.sightLines
        let blocked = sights.filter { !$0.seesStageFloor }
        return Group {
            if sights.isEmpty {
                EmptyView()
            } else if blocked.isEmpty {
                Label(L10n.tf("All %d rows see the stage", sights.count),
                      systemImage: "eye.fill")
                    .font(.caption2).foregroundStyle(.green)
            } else {
                let worst = blocked.min { $0.margin < $1.margin }!
                VStack(alignment: .leading, spacing: 1) {
                    Label(L10n.tf("%d of %d rows blocked", blocked.count, sights.count),
                          systemImage: "eye.slash.fill")
                        .font(.caption2).foregroundStyle(.orange)
                    Text(L10n.tf("worst: row %d, %d mm", worst.row + 1, Int(worst.margin)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func numberField(_ field: StageField, _ value: Double,
                             unit: String, step: Double = 100) -> some View {
        HStack(spacing: 6) {
            Text(L10n.t(field.title))
                .font(.caption2).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            TextField("", value: Binding(
                get: { field.isCount ? Double(Int(value)) : value },
                set: { model.dispatch(.setStage(field, $0)) }
            ), format: .number.precision(.fractionLength(0)))
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.trailing)
            Text(unit).font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - 灯具

    private func fixtureSection(_ f: Fixture) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(L10n.tf("Lantern %d", f.unit))

            labeledValue(L10n.t("Type"), model.typeLabel(f.type))
            labeledValue(L10n.t("Position"), f.pos ?? "—")
            if let w = model.state.doc.worldPoint(of: f) {
                labeledValue(L10n.t("Location"),
                             String(format: "%.0f, %.0f", w.x, w.y))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(L10n.t("Aim")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(f.aim ?? 90))°").font(.caption.monospacedDigit())
                }
                Slider(value: Binding(
                    get: { f.aim ?? 90 },
                    set: { model.dispatch(.setFixtureAim(unit: f.unit, aim: $0)) }
                ), in: 0...359, step: 1)
                HStack(spacing: 4) {
                    ForEach([(0.0, "→"), (90.0, "↑"), (180.0, "←"), (270.0, "↓")], id: \.0) { a, g in
                        Button(g) { model.dispatch(.setFixtureAim(unit: f.unit, aim: a)) }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                    Spacer()
                }
            }

            colourField(f)

            HStack {
                Text(L10n.t("Channel")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("", value: Binding(
                    get: { f.ch ?? 0 },
                    set: { model.dispatch(.setFixtureChannel(unit: f.unit, ch: $0)) }
                ), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 64)
                .font(.caption.monospacedDigit())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("Purpose")).font(.caption).foregroundStyle(.secondary)
                TextField(L10n.t("What does it light?"), text: Binding(
                    get: { f.purpose ?? "" },
                    set: { model.dispatch(.setFixturePurpose(unit: f.unit, purpose: $0)) }
                ))
                .textFieldStyle(.roundedBorder).font(.caption)
            }

            if let beam = f.beam {
                labeledValue(L10n.t("Beam"), "\(Int(beam))°")
            }

            Button(role: .destructive) {
                model.dispatch(.deleteFixture(unit: f.unit))
            } label: {
                Label(L10n.t("Delete lantern"), systemImage: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private func swatch(for code: String?) -> some View {
        let rgb = model.state.doc.gel(code: code ?? "")?.rgb
        return Group {
            if let rgb {
                RoundedRectangle(cornerRadius: 3).fill(Color(rgb: rgb))
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: 22, height: 16)
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.black.opacity(0.18)))
    }

    /// 色片字段。
    ///
    /// **场景激活时必须显示"实际生效"的色片，而不是文档里的基础值。**
    /// 早先这里只读 `f.gel` —— 于是 kitchen 场景下图上是 L202、
    /// 检查器却写 L132，用户会以为图错了（或改错了地方）。
    @ViewBuilder
    private func colourField(_ f: Fixture) -> some View {
        let effective = model.activeState?.gel(for: f) ?? f.gel
        let overridden = model.activeState != nil && effective != f.gel

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(L10n.t("Colour"))
                    .font(.caption).foregroundStyle(.secondary)
                if overridden {
                    Text(L10n.t("in scene"))
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }

            HStack(spacing: 6) {
                // 主色块跟随 **picker 的值**（基础色），
                // 否则色块与右侧文字对不上（picker 写 L132、色块却是 L202 的蓝）。
                swatch(for: f.gel)
                Picker("", selection: Binding(
                    get: { f.gel ?? "OPEN" },
                    set: { model.dispatch(.setFixtureGel(unit: f.unit, gel: $0)) }
                )) {
                    ForEach(model.state.doc.gels.sorted(by: { $0.code < $1.code }), id: \.code) {
                        Text("\($0.code)  \($0.name)").tag($0.code)
                    }
                }
                .labelsHidden().pickerStyle(.menu)
            }

            // 覆盖时同时给出**两个色块**：基础（你在编辑的）与生效（图上画的）。
            // 只用文字说明还不够 —— 色片是视觉信息，必须看得见。
            if overridden {
                HStack(spacing: 5) {
                    swatch(for: f.gel)
                    Text(f.gelCode).font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8)).foregroundStyle(.tertiary)
                    swatch(for: effective)
                    Text(effective ?? "-").font(.caption2).foregroundStyle(.secondary)
                }
                Text(L10n.t("The sheet prints the second one."))
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 构件

    private func positionSection(_ p: Position) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(L10n.t("Position"))

            // 名字可改 —— 灯会跟着改
            HStack {
                Text(L10n.t("Name")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("", text: Binding(
                    get: { p.id },
                    set: { if !$0.isEmpty { model.dispatch(.setPositionID(old: p.id, new: $0)) } }
                ))
                .textFieldStyle(.roundedBorder).frame(width: 110).font(.caption)
            }

            HStack {
                Text(L10n.t("Type")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { p.type },
                    set: { model.dispatch(.setPositionType(id: p.id, type: $0)) }
                )) {
                    ForEach(PositionType.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 96)
            }

            if let shape = p.shape {
                labeledValue(L10n.t("Length"),
                             String(format: "%.0f mm", shape.length))
                let cells = max(1, Int((shape.length / Paper.TrussSpec.pitchMM).rounded(.up)))
                labeledValue(L10n.t("Cells"), "\(cells)")
            }

            if p.type != .line {
                HStack {
                    Text(L10n.t("Trim")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("", value: Binding(
                        get: { p.trim ?? 0 },
                        set: { model.dispatch(.setPositionTrim(id: p.id, trim: $0)) }
                    ), format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 78)
                    .font(.caption.monospacedDigit())
                    Text("mm").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            let attached = Resolver.fixtures(on: p.id, in: model.state.doc)
            labeledValue(L10n.t("Lanterns"), "\(attached.count)")

            if model.state.selection.positions.count == 2 {
                Button {
                    model.mergeSelection()
                } label: {
                    Label(L10n.t("Join the two selected trusses"),
                          systemImage: "arrow.triangle.merge").font(.caption)
                }
                .buttonStyle(.borderless)
            }

            Button(role: .destructive) {
                model.dispatch(.deletePosition(id: p.id))
            } label: {
                Label(L10n.t("Delete position"), systemImage: "trash").font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 布景

    private func setPieceSection(_ piece: SetPiece) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(L10n.t("Set piece"))

            labeledValue(L10n.t("Kind"), piece.kind.rawValue.uppercased())

            if let label = piece.label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("Label"))
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(label).font(.caption).textSelection(.enabled)
                }
            }

            if piece.kind != .line {
                let r = piece.rect
                labeledValue(L10n.t("Size"),
                             String(format: "%.0f x %.0f mm", r.width, r.height))
            } else {
                labeledValue(L10n.t("Length"),
                             String(format: "%.0f mm",
                                    Vec2(piece.x0, piece.y0).distance(to: Vec2(piece.x1, piece.y1))))
            }

            // 剖面图需要高度 —— 这是"光打在什么上"的关键
            HStack {
                Text(L10n.t("Height")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("", value: Binding(
                    get: { piece.height ?? model.state.doc.sectionHeight(of: piece) },
                    set: { model.dispatch(.setSetPieceHeight(id: piece.id, height: $0)) }
                ), format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 78)
                .font(.caption.monospacedDigit())
                Text("mm").font(.caption2).foregroundStyle(.tertiary)
            }

            if piece.kind == .stair, let steps = piece.steps {
                labeledValue(L10n.t("Steps"), "\(steps)")
                labeledValue(L10n.t("Tread"),
                             String(format: "%.0f mm", piece.treadDepth))
            }

            Text(L10n.t("Drag it on the canvas to move it."))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive) {
                model.dispatch(.deleteSetPiece(id: piece.id))
            } label: {
                Label(L10n.t("Delete set piece"), systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 光区

    private func zoneSection(_ zone: Zone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(L10n.t("Acting zone"))

            HStack {
                Text(L10n.t("Name")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                TextField("", text: Binding(
                    get: { zone.id },
                    set: {
                        let clean = EventSanitizer.ascii($0).uppercased()
                        guard !clean.isEmpty else { return }
                        var z = zone
                        z.id = clean
                        model.dispatch(.addZone(z))
                    }
                ))
                .textFieldStyle(.roundedBorder).frame(width: 90).font(.caption)
            }

            labeledValue(L10n.t("Size"),
                         String(format: "%.1f x %.1f m",
                                zone.rect.width / 1000, zone.rect.height / 1000))
            labeledValue(L10n.t("Centre"),
                         String(format: "%.1f, %.1f m",
                                zone.center.x / 1000, zone.center.y / 1000))

            let count = model.state.doc.fixtures.filter {
                if let p = $0.purpose, p.contains(zone.id) { return true }
                if let w = model.state.doc.worldPoint(of: $0) { return zone.rect.contains(w) }
                return false
            }.count
            labeledValue(L10n.t("Lanterns inside"), "\(count)")

            Button(role: .destructive) {
                model.dispatch(.deleteZone(id: zone.id))
            } label: {
                Label(L10n.t("Delete zone"), systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - 无选中

    private var selectionHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(L10n.t("Selection"))
            Text(L10n.t("Tap a lantern or a truss to edit it."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.t("Drag a lantern along its bar to slide it. Drag a truss end to resize. Pinch to zoom."))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 校验

    private var issuesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                header(L10n.t("Checks"))
                Spacer()
                Text("\(model.issues.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if model.issues.isEmpty {
                Label(L10n.t("Nothing to report"),
                      systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                ForEach(model.issues.prefix(20)) { issueRow($0) }
                if model.issues.count > 20 {
                    Text("\(model.issues.count - 20) more…")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func issueRow(_ issue: LintIssue) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: issue.severity == .error
                  ? "xmark.circle.fill"
                  : (issue.severity == .warning ? "exclamationmark.circle.fill" : "info.circle"))
                .font(.caption2)
                .foregroundStyle(issue.severity == .error ? Color.red
                                 : (issue.severity == .warning ? Color.orange : Color.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(issue.code.title).font(.caption2.weight(.medium))
                Text(issue.message)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 小部件

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold))
            .textCase(.uppercase).foregroundStyle(.secondary)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.caption)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}
