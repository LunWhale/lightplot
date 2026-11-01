import Foundation

/// 编辑器内核：`reduce(state, event) -> state`。
///
/// **纯函数**。没有 I/O、没有时间、没有随机数。
/// 同一个 state + 同一个 event 永远得到同一个结果 —— 这是可以字节级回归的前提。
///
/// 每条不变量都有对应的测试（`EditorTests`、`EditorInvariantTests`）：
///   · 灯永不脱杆（构件上的灯，其 `pos` 必须始终指向存在的构件）
///   · 撤销可逆（`undo(do(x)) == x`）
///   · 合并桁架后灯具偏移被重算，没有灯跑到杆外
public enum Editor {

    /// 处理一个事件。返回新状态与可能需要 UI 执行的副作用提示。
    @discardableResult
    public static func reduce(_ state: EditorState,
                              _ event: EditorEvent,
                              snap: SnapOptions = SnapOptions()) -> EditorState {
        var s = state

        switch event {
        // MARK: 选择
        case .select(let sel):
            s.selection = sel

        case .clickEmpty:
            s.selection = .empty

        case .selectAt(let paperPoint, let additive):
            let hit = hitTest(paperPoint, doc: s.doc, layout: s.layout)
            if additive {
                var sel = s.selection
                if case .fixture(let unit) = hit {
                    if sel.fixtures.contains(unit) { sel.fixtures.remove(unit) }
                    else { sel.fixtures.insert(unit) }
                }
                s.selection = sel
            } else {
                switch hit {
                case .fixture(let unit):   s.selection = Selection(fixtures: [unit])
                case .position(let id):    s.selection = Selection(positions: [id])
                case .setPiece(let id):    s.selection = Selection(setPieces: [id])
                case .zone(let id):        s.selection = Selection(zones: [id])
                case .none:                s.selection = .empty
                }
            }

        case .marqueeSelect(let paperRect):
            var sel = Selection()
            let docRect = docRect(from: paperRect, layout: s.layout)
            for (fixture, mount) in Resolver.allMounts(in: s.doc) {
                if let p = mount.worldPoint, docRect.contains(p) { sel.fixtures.insert(fixture.unit) }
            }
            for position in s.doc.positions {
                if let shape = position.shape,
                   docRect.contains(shape.start) && docRect.contains(shape.end) {
                    sel.positions.insert(position.id)
                }
            }
            for piece in s.doc.setPieces {
                switch piece.kind {
                case .rect, .stair:
                    if docRect.intersects(piece.rect) { sel.setPieces.insert(piece.id) }
                case .line:
                    if docRect.contains(Vec2(piece.x0, piece.y0))
                        || docRect.contains(Vec2(piece.x1, piece.y1)) {
                        sel.setPieces.insert(piece.id)
                    }
                }
            }
            for zone in s.doc.zones where docRect.intersects(zone.rect) {
                sel.zones.insert(zone.id)
            }
            s.selection = sel

        // MARK: 构件
        case .movePosition(let id, let delta):
            guard let idx = s.doc.positions.firstIndex(where: { $0.id == id }) else { break }
            s.pushUndo()
            s.doc.positions[idx] = moved(s.doc.positions[idx], by: delta)

        case .setPositionEnd(let id, let which, let paperPoint):
            guard let idx = s.doc.positions.firstIndex(where: { $0.id == id }) else { break }
            let snapped = Snapper.snap(paperPoint, doc: s.doc, layout: s.layout,
                                       viewport: s.viewport, options: snap,
                                       excludingPosition: id)
            let docPoint = round(s.layout.toDocument(snapped.point))
            s.pushUndo()
            // 端点拖动时，挂在杆上的灯不动（它们沿轴固定）——
            // 但杆变短后可能落到杆外，由 Lint 报出来，而不是悄悄移动灯。
            s.doc.positions[idx] = resized(s.doc.positions[idx], which: which, to: docPoint)

        case .addPosition(let position):
            s.pushUndo()
            s.doc.positions.append(position)

        case .mergePositions(let keep, let absorb):
            guard let a = s.doc.position(id: keep),
                  let b = s.doc.position(id: absorb) else { break }
            // 合并必须通过语义判定；不满足条件就**不合并**，
            // 由 `mergeRefusal` 报告原因。静默合并会毁数据。
            if case .merge(let candidate) = Merger.evaluate(a, b, in: s.doc) {
                s.pushUndo()
                Merger.apply(candidate, to: &s.doc)
                s.selection = Selection(positions: [candidate.merged.id])
            }

        case .deletePosition(let id):
            s.pushUndo()
            s.doc.positions.removeAll { $0.id == id }
            // 杆没了，挂在上面的灯会被 Lint 报 fixtureUnknownPosition。
            // 刻意**不自动删除灯具** —— 用户可能只是想改名，删除是不可逆的。
            s.selection.positions.remove(id)

        // MARK: 灯具
        case .addFixture(var fixture, let paperPoint):
            s.pushUndo()
            place(&fixture, near: paperPoint, in: &s, snap: snap)
            if s.doc.fixtures.contains(where: { $0.unit == fixture.unit }) {
                fixture.unit = nextUnit(in: s.doc)
            }
            if fixture.ch == nil { fixture.ch = nextChannel(in: s.doc) }
            if fixture.purpose?.isEmpty ?? true { fixture.purpose = "UNASSIGNED" }
            s.doc.fixtures.append(fixture)
            s.selection = Selection(fixtures: [fixture.unit])

        case .moveFixture(let unit, let paperPoint):
            guard let idx = s.doc.fixtures.firstIndex(where: { $0.unit == unit }) else { break }
            let snapped = Snapper.snap(paperPoint, doc: s.doc, layout: s.layout,
                                       viewport: s.viewport, options: snap,
                                       excludingFixture: unit)
            var fixture = s.doc.fixtures[idx]

            if fixture.isFreeMounted {
                // 台上实物：自由摆放，两个坐标都是世界坐标
                let docPoint = round(s.layout.toDocument(snapped.point))
                fixture.x = docPoint.x
                fixture.y = docPoint.y
            } else if let hit = Snapper.nearestPosition(to: snapped.point, doc: s.doc,
                                                        layout: s.layout,
                                                        viewport: s.viewport) {
                // 锁在杆上：只写沿轴的绝对坐标，**不写另一个轴**。
                // 写两个坐标会让它下次被解释成自由摆放 —— 灯就悄悄脱杆了。
                let docPoint = round(s.layout.toDocument(hit.point))
                if let pos = s.doc.position(id: hit.id), let shape = pos.shape {
                    fixture.pos = hit.id
                    switch shape {
                    case .horizontal: fixture.x = docPoint.x; fixture.y = nil
                    case .vertical:   fixture.y = docPoint.y; fixture.x = nil
                    }
                }
            } else {
                // 离任何杆都太远：保持原样（不制造"飘在空中的灯"）。
                // UI 应当给用户震动/提示反馈。
                break
            }

            s.pushUndo()
            s.doc.fixtures[idx] = fixture

        case .setFixtureAim(let unit, let aim):
            guard let idx = s.doc.fixtures.firstIndex(where: { $0.unit == unit }) else { break }
            s.pushUndo()
            s.doc.fixtures[idx].aim = normalizedAngle(aim)

        case .deleteFixture(let unit):
            s.pushUndo()
            s.doc.fixtures.removeAll { $0.unit == unit }
            s.selection.fixtures.remove(unit)

        case .setFixtureGel(let unit, let gel):
            guard let idx = s.doc.fixtures.firstIndex(where: { $0.unit == unit }) else { break }
            s.pushUndo()
            s.doc.fixtures[idx].gel = gel

        case .setFixtureChannel(let unit, let ch):
            guard let idx = s.doc.fixtures.firstIndex(where: { $0.unit == unit }) else { break }
            s.pushUndo()
            s.doc.fixtures[idx].ch = ch

        case .setFixturePurpose(let unit, let purpose):
            guard let idx = s.doc.fixtures.firstIndex(where: { $0.unit == unit }) else { break }
            s.pushUndo()
            s.doc.fixtures[idx].purpose = purpose

        // MARK: 版面
        case .setScale(let scale):
            guard scale.isFinite, scale >= 1 else { break }
            s.pushUndo()
            s.doc.meta.scale = scale
            s.layout = SheetLayout(paper: s.layout.paper,
                                   scaleDenominator: scale,
                                   originOnSheet: s.layout.originOnSheet)

        case .setPaper(let paper):
            s.pushUndo()
            s.layout = SheetLayout.fitted(to: s.doc.contentBounds,
                                          paper: paper,
                                          scaleDenominator: s.layout.scaleDenominator)

        case .setOrigin(let origin):
            s.pushUndo()
            s.layout.originOnSheet = origin

        case .autoFitOrigin:
            s.pushUndo()
            s.layout = SheetLayout.fitted(to: s.doc.contentBounds,
                                          paper: s.layout.paper,
                                          scaleDenominator: s.layout.scaleDenominator)

        // MARK: 文档与场地

        case ._setMeta(let rawField, let value):
            guard let field = MetaField(rawValue: rawField) else { break }
            s.pushUndo()
            // 图上文字必须 ASCII —— 在这里就拦，而不是等到导出时才炸。
            // 用户可能在 iPad 上自然地输入中文，那时给的是"无法输入"的即时反馈。
            let sanitized = EventSanitizer.ascii(value)
            switch field {
            case .show:       s.doc.meta.show = sanitized
            case .playwright: s.doc.meta.playwright = sanitized
            case .venue:      s.doc.meta.venue = sanitized
            case .sheetTitle: s.doc.meta.sheetTitle = sanitized
            case .date:       s.doc.meta.date = sanitized
            case .revision:   s.doc.meta.revision = sanitized
            case .revNote:    s.doc.meta.revNote = sanitized
            case .director:   s.doc.meta.director = sanitized
            case .designer:   s.doc.meta.designer = sanitized
            }
            s.relayoutIfNeeded()

        case ._setStage(let rawField, let value):
            guard let field = StageField(rawValue: rawField) else { break }
            guard value.isFinite else { break }
            s.pushUndo()
            switch field {
            case .width:            s.doc.stage.width = max(1000, value)
            case .depth:            s.doc.stage.depth = max(1000, value)
            case .gridHeight:       s.doc.stage.gridHeight = max(2000, value)
            case .prosceniumHeight: s.doc.stage.prosceniumHeight = max(0, value)
            case .prosceniumX:      s.doc.stage.prosceniumX = value
            case .audienceRows:     s.doc.stage.audienceRows = Int(value.clamped(to: 0...40))
            case .audienceRowDepth: s.doc.stage.audienceRowDepth = max(300, value)
            case .audienceRake:     s.doc.stage.audienceRake = max(0, value)
            }
            s.relayoutIfNeeded()

        // MARK: 构件详情

        case .setPositionTrim(let id, let trim):
            guard let idx = s.doc.positions.firstIndex(where: { $0.id == id }) else { break }
            s.pushUndo()
            s.doc.positions[idx].trim = max(0, trim)

        case .setPositionID(let old, let new):
            let clean = EventSanitizer.ascii(new).uppercased()
            guard !clean.isEmpty, clean != old,
                  s.doc.position(id: clean) == nil else { break }
            guard let idx = s.doc.positions.firstIndex(where: { $0.id == old }) else { break }
            s.pushUndo()
            s.doc.positions[idx].id = clean
            // 挂在这根杆上的灯必须跟着改 —— 否则它们会立刻变成"未知位置"。
            for i in s.doc.fixtures.indices where s.doc.fixtures[i].pos == old {
                s.doc.fixtures[i].pos = clean
            }
            s.selection.positions = [clean]

        case .setPositionType(let id, let type):
            guard let idx = s.doc.positions.firstIndex(where: { $0.id == id }) else { break }
            s.pushUndo()
            s.doc.positions[idx].type = type

        // MARK: 布景与光区

        case .addSetPiece(let piece):
            s.pushUndo()
            s.doc.setPieces.append(piece)

        case .deleteSetPiece(let id):
            s.pushUndo()
            s.doc.setPieces.removeAll { $0.id == id }
            s.selection.setPieces.remove(id)

        case .moveSetPiece(let id, let delta):
            guard let idx = s.doc.setPieces.firstIndex(where: { $0.id == id }) else { break }
            var piece = s.doc.setPieces[idx]
            let oldID = piece.id
            s.pushUndo()
            piece.x0 += delta.x; piece.y0 += delta.y
            // 楼梯是"外接矩形 + 级数"，只推下沿即可保持进深
            if piece.kind == .stair {
                piece.y1 += delta.y
            } else {
                piece.x1 += delta.x; piece.y1 += delta.y
            }
            s.doc.setPieces[idx] = piece
            // id 由坐标派生，移动后要更新选择集，否则选择会失效
            if s.selection.setPieces.remove(oldID) != nil {
                s.selection.setPieces.insert(piece.id)
            }

        case .setSetPieceHeight(let id, let height):
            guard let idx = s.doc.setPieces.firstIndex(where: { $0.id == id }) else { break }
            s.pushUndo()
            s.doc.setPieces[idx].height = max(0, height)

        case .addZone(let zone):
            s.pushUndo()
            s.doc.zones.removeAll { $0.id == zone.id }
            s.doc.zones.append(zone)

        case .deleteZone(let id):
            s.pushUndo()
            s.doc.zones.removeAll { $0.id == id }
            s.selection.zones.remove(id)

        // MARK: 撤销
        case .undo:
            guard let previous = s.undoStack.popLast() else { break }
            s.redoStack.append((s.doc, s.layout))
            s.doc = previous.0
            s.layout = previous.1
            s.selection = .empty

        case .redo:
            guard let next = s.redoStack.popLast() else { break }
            s.undoStack.append((s.doc, s.layout))
            s.doc = next.0
            s.layout = next.1
            s.selection = .empty
        }

        return s
    }

    /// 批量处理（一次手势 = 一串事件）。只压一次撤销点。
    @discardableResult
    public static func reduce(_ state: EditorState,
                              batch: [EditorEvent],
                              snap: SnapOptions = SnapOptions()) -> EditorState {
        guard !batch.isEmpty else { return state }
        var s = state
        s.pushUndo()
        // 批内不再各自压栈：临时把栈清空，最后恢复一次
        let saved = s.undoStack
        for e in batch { s = reduce(s, e, snap: snap) }
        s.undoStack = saved
        return s
    }

    // MARK: - 命中选择

    public enum Hit: Equatable, Sendable {
        case fixture(Int)
        case position(String)
        case setPiece(String)
        case zone(String)
    }

    /// 命中测试。**灯具优先于构件**：灯在杆上方，用户想抓的是灯。
    public static func hitTest(_ paperPoint: Vec2, doc: LXDocument,
                               layout: SheetLayout,
                               fixtureRadius: Double = 8) -> Hit? {
        // 灯
        var bestFixture: (unit: Int, d: Double)?
        for (fixture, mount) in Resolver.allMounts(in: doc) {
            guard let w = mount.worldPoint else { continue }
            let p = layout.toSheet(w)
            let d = p.distance(to: paperPoint)
            guard d <= fixtureRadius else { continue }
            if bestFixture == nil || d < bestFixture!.d { bestFixture = (fixture.unit, d) }
        }
        if let bestFixture { return .fixture(bestFixture.unit) }

        // 构件（容差 = 构件半高 + 2mm，所以点在桁架厚度的任何位置都算命中）
        var bestPosition: (id: String, d: Double)?
        for position in doc.positions {
            guard let shape = position.shape else { continue }
            let a = layout.toSheet(shape.start)
            let b = layout.toSheet(shape.end)
            let (_, foot) = paperPoint.projected(onto: a, b)
            let d = paperPoint.distance(to: foot)
            let tol = position.halfHeightOnSheet(scale: layout.scaleDenominator) + 2.0
            guard d <= tol else { continue }
            if bestPosition == nil || d < bestPosition!.d { bestPosition = (position.id, d) }
        }
        if let bestPosition { return .position(bestPosition.id) }

        // 布景：矩形/楼梯命中内部，线按距离判定
        for piece in doc.setPieces {
            switch piece.kind {
            case .rect, .stair:
                let r = layout.sheetRect(forDocumentRect: piece.rect)
                if r.inset(by: -1.5).contains(paperPoint) { return .setPiece(piece.id) }
            case .line:
                let a = layout.toSheet(Vec2(piece.x0, piece.y0))
                let b = layout.toSheet(Vec2(piece.x1, piece.y1))
                let (_, foot) = paperPoint.projected(onto: a, b)
                if paperPoint.distance(to: foot) <= 2.5 { return .setPiece(piece.id) }
            }
        }

        // 光区框（通常最大，放最后 —— 否则它会盖住里面所有东西）
        for zone in doc.zones {
            let r = layout.sheetRect(forDocumentRect: zone.rect)
            if r.contains(paperPoint) { return .zone(zone.id) }
        }
        return nil
    }

    // MARK: - 几何变换

    static func moved(_ p: Position, by delta: Vec2) -> Position {
        var out = p
        switch p.kind {
        case .horizontal:
            out.x0 = (p.x0 ?? 0) + delta.x
            out.x1 = (p.x1 ?? 0) + delta.x
            out.y = (p.y ?? 0) + delta.y
        case .vertical:
            out.x = (p.x ?? 0) + delta.x
            out.y0 = (p.y0 ?? 0) + delta.y
            out.y1 = (p.y1 ?? 0) + delta.y
        }
        return out
    }

    /// 杆的最短长度（文档 mm）。10cm —— 再短就不是一根杆了。
    static let minimumPositionLength: Double = 100

    /// 拖动杆端。
    ///
    /// **两端不允许交叉。** 早先直接赋值，把起点拖过终点就会得到
    /// `x0 > x1` 的倒置杆 —— 桁架几何、长度计算、吸附全部失去意义，
    /// 而图上"看起来还是一根线"，不会有人发现。
    ///
    /// 现在的行为：拖到另一端时**停在最短长度**，不会翻转、也不会倒置。
    /// 不选"自动交换两端"是因为那会让用户失去对"哪端是 start"的控制，
    /// 而 ads 吸附与灯具轴坐标都依赖这一点。
    static func resized(_ p: Position, which: EditorEvent.EndPoint, to point: Vec2) -> Position {
        var out = p
        switch p.kind {
        case .horizontal:
            let fixed = (which == .start ? p.x1 : p.x0) ?? 0
            if which == .start {
                out.x0 = min(point.x, fixed - minimumPositionLength)
            } else {
                out.x1 = max(point.x, fixed + minimumPositionLength)
            }
        case .vertical:
            let fixed = (which == .start ? p.y1 : p.y0) ?? 0
            if which == .start {
                out.y0 = min(point.y, fixed - minimumPositionLength)
            } else {
                out.y1 = max(point.y, fixed + minimumPositionLength)
            }
        }
        return out
    }

    static func docRect(from paperRect: Rect, layout: SheetLayout) -> Rect {
        let a = layout.toDocument(Vec2(paperRect.x0, paperRect.y0))
        let b = layout.toDocument(Vec2(paperRect.x1, paperRect.y1))
        return Rect(x0: a.x, y0: a.y, x1: b.x, y1: b.y)
    }

    /// 把灯具放到离 `paperPoint` 最近的构件上；没有构件就放成台上实物。
    static func place(_ fixture: inout Fixture, near paperPoint: Vec2,
                      in state: inout EditorState, snap: SnapOptions) {
        if let hit = Snapper.nearestPosition(to: paperPoint, doc: state.doc,
                                            layout: state.layout,
                                            viewport: state.viewport) {
            guard let pos = state.doc.position(id: hit.id), let shape = pos.shape else { return }
            let docPoint = round(state.layout.toDocument(hit.point))
            fixture.pos = hit.id
            switch shape {
            case .horizontal: fixture.x = docPoint.x; fixture.y = nil
            case .vertical:   fixture.y = docPoint.y; fixture.x = nil
            }
            fixture.type = fixture.type.isEmpty ? "profile" : fixture.type
        } else {
            // 离任何构件都太远：退化为**台上实物**（自由摆放）。
            //
            // ★ 关键：必须同时把 type 改成 practical。
            //   `isFreeMounted` 的判据是 `type == "practical"`，
            //   如果只设两个坐标而 type 仍是 fresnel/profile，
            //   它会去找 pos 指向的构件 —— 而 `pos` 是个不存在的名字，
            //   于是立刻变成"未知位置"的孤儿灯。
            let docPoint = round(state.layout.toDocument(paperPoint))
            fixture.x = docPoint.x
            fixture.y = docPoint.y
            // 不保留原来那个指向不存在构件的 pos
            if fixture.pos == nil || state.doc.position(id: fixture.pos!) == nil {
                fixture.pos = nil
            }
            // 非实物类灯具放到空中没有意义 —— 按实物处理
            if fixture.type.isEmpty || fixture.type != "practical" {
                // 保留原始类型信息在 purpose 里，避免用户丢失意图
                if fixture.type.isEmpty {
                    fixture.type = "practical"
                } else if !(fixture.purpose?.contains(fixture.type) ?? false) {
                    let original = fixture.type
                    fixture.type = "practical"
                    fixture.purpose = "FREE MOUNTED \(original.uppercased())"
                }
            }
        }
    }

    static func nextUnit(in doc: LXDocument) -> Int {
        (doc.fixtures.map(\.unit).max() ?? 0) + 1
    }

    static func nextChannel(in doc: LXDocument) -> Int {
        (doc.fixtures.compactMap(\.ch).max() ?? 0) + 1
    }

    /// 图纸→文档往返会引入 1e-12 级误差。舞台图纸的精度需求是 1mm，
    /// 这里取 0.01mm，既有余量又不会把 4999.999999998 写进文件。
    static func round(_ p: Vec2) -> Vec2 {
        Vec2((p.x * 100).rounded() / 100, (p.y * 100).rounded() / 100)
    }

    static func normalizedAngle(_ deg: Double) -> Double {
        var a = deg.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        // 吸附到整度，避免拖动产生 89.9999 这种值污染回归
        return a.rounded()
    }
}

// MARK: - 版面联动

extension EditorState {
    /// 文档或场地尺寸变化后，重算图框位置。
    ///
    /// 为什么必须重算：图框原点是为了"让内容居中"算出来的。
    /// 场地从 15m 改成 9m 后，如果原点不动，图纸会偏到一边甚至出框。
    /// 用户手动挪过图框时也重算 —— 因为场地变了，旧的居中位置已经没意义。
    mutating func relayoutIfNeeded() {
        layout = SheetLayout.fitted(to: doc.contentBounds,
                                    paper: layout.paper,
                                    scaleDenominator: layout.scaleDenominator)
    }
}

// MARK: - 撤销栈

extension EditorState {
    mutating func pushUndo() {
        undoStack.append((doc, layout))
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        redoStack.removeAll()
    }
}
