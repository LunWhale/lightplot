import Testing
import Foundation
@testable import LightPlotCore

/// 文档级编辑。
///
/// 这一组守的是"能打开但不能改"这个缺口 ——
/// 一个不能输入真实场地尺寸的绘图工具，解决不了它的核心问题。
@Suite("Document editing")
struct DocumentEditingTests {

    private func state() -> EditorState {
        EditorState(doc: TestData.validDocument())
    }

    // MARK: 文字字段

    @Test("Every metadata field round-trips through the editor")
    func metaFields() {
        var s = state()
        let values: [MetaField: String] = [
            .show: "A NEW SHOW",
            .playwright: "SOMEONE",
            .venue: "THE SPACE",
            .sheetTitle: "LX PLAN REV B",
            .date: "02/02/2027",
            .revision: "V2",
            .revNote: "SECOND ISSUE",
            .director: "A DIRECTOR",
            .designer: "A DESIGNER",
        ]
        for (field, value) in values {
            s = Editor.reduce(s, .setMeta(field, value))
        }
        #expect(s.doc.meta.show == "A NEW SHOW")
        #expect(s.doc.meta.playwright == "SOMEONE")
        #expect(s.doc.meta.venue == "THE SPACE")
        #expect(s.doc.meta.sheetTitle == "LX PLAN REV B")
        #expect(s.doc.meta.date == "02/02/2027")
        #expect(s.doc.meta.revision == "V2")
        #expect(s.doc.meta.revNote == "SECOND ISSUE")
        #expect(s.doc.meta.director == "A DIRECTOR")
        #expect(s.doc.meta.designer == "A DESIGNER")
    }

    @Test("Metadata edits are undoable one field at a time")
    func metaUndoGranularity() {
        var s = state()
        let original = s.doc.meta
        s = Editor.reduce(s, .setMeta(.show, "ONE"))
        s = Editor.reduce(s, .setMeta(.venue, "TWO"))
        s = Editor.reduce(s, .undo)
        #expect(s.doc.meta.venue == original.venue)
        #expect(s.doc.meta.show == "ONE", "only the last field should revert")
        s = Editor.reduce(s, .undo)
        #expect(s.doc.meta.show == original.show)
    }

    /// **关键行为**：中文在编辑时就被替换，而不是等到导出才炸。
    @Test("Non-ASCII input is sanitised at the edit point")
    func asciiEnforced() {
        var s = state()
        s = Editor.reduce(s, .setMeta(.show, "推销员之死"))
        #expect(EventSanitizer.isASCII(s.doc.meta.show))
        #expect(s.doc.meta.show == "?????")

        s = Editor.reduce(s, .setMeta(.designer, "Li ± Wang © 2026"))
        #expect(s.doc.meta.designer == "Li +/- Wang (C) 2026")
        #expect(EventSanitizer.isASCII(s.doc.meta.designer))
    }

    @Test("Editing metadata never introduces a lint error")
    func metaStaysClean() {
        var s = state()
        s = Editor.reduce(s, .setMeta(.show, "MIXED ° and — dashes"))
        let codes = Set(s.issues.map(\.code))
        #expect(!codes.contains(.documentNonASCII))
    }

    // MARK: 场地

    @Test("Every stage field round-trips")
    func stageFields() {
        var s = state()
        let values: [StageField: Double] = [
            .width: 18000, .depth: 11000, .gridHeight: 9000,
            .prosceniumHeight: 7000, .prosceniumX: -1500,
            .audienceRows: 9, .audienceRowDepth: 600, .audienceRake: 220,
        ]
        for (field, value) in values {
            s = Editor.reduce(s, .setStage(field, value))
        }
        #expect(s.doc.stage.width == 18000)
        #expect(s.doc.stage.depth == 11000)
        #expect(s.doc.stage.gridHeight == 9000)
        #expect(s.doc.stage.prosceniumHeight == 7000)
        #expect(s.doc.stage.prosceniumX == -1500)
        #expect(s.doc.stage.audienceRows == 9)
        #expect(s.doc.stage.audienceRowDepth == 600)
        #expect(s.doc.stage.audienceRake == 220)
    }

    @Test("Stage edits are clamped to sane ranges")
    func stageClamping() {
        var s = state()
        s = Editor.reduce(s, .setStage(.width, -500))
        #expect(s.doc.stage.width >= 1000, "a stage cannot have negative width")
        s = Editor.reduce(s, .setStage(.depth, 0))
        #expect(s.doc.stage.depth >= 1000)
        s = Editor.reduce(s, .setStage(.audienceRows, 999))
        #expect(s.doc.stage.audienceRows <= 40)
        s = Editor.reduce(s, .setStage(.audienceRake, -100))
        #expect(s.doc.stage.audienceRake >= 0)
        // 非有限值必须被拒绝，不能污染文档
        let before = s.doc.stage.width
        s = Editor.reduce(s, .setStage(.width, .infinity))
        #expect(s.doc.stage.width == before)
    }

    /// 场地改变后图框必须重算，否则图纸会偏到一边甚至出框。
    @Test("Changing the stage re-centres the sheet")
    func relayout() {
        var s = state()
        let before = s.layout.originOnSheet
        s = Editor.reduce(s, .setStage(.width, 9000))
        s = Editor.reduce(s, .setStage(.depth, 7000))
        #expect(s.layout.originOnSheet != before)
        let sheet = PlanSheet(doc: s.doc, layout: s.layout)
        #expect(sheet.contentFitsSheet, "after shrinking the stage the plan must still fit")
    }

    @Test("Audience rows change the section sightline count")
    func sectionTracksStage() {
        var s = state()
        s = Editor.reduce(s, .setStage(.audienceRows, 3))
        let sheet = SectionSheet(fitting: s.doc)
        #expect(sheet.sightLines.count == 3)

        s = Editor.reduce(s, .setStage(.audienceRows, 8))
        #expect(SectionSheet(fitting: s.doc).sightLines.count == 8)
    }

    // MARK: 构件详情

    @Test("Renaming a position carries its lanterns")
    func renamePosition() {
        var s = state()
        s = Editor.reduce(s, .setPositionID(old: "LX 1", new: "lx one"))
        // 名字被清洗成大写
        #expect(s.doc.position(id: "LX ONE") != nil)
        // 挂在上面的灯必须跟着改，否则立刻变成未知位置
        #expect(s.doc.fixture(unit: 101)?.pos == "LX ONE")
        #expect(!s.issues.contains { $0.code == .fixtureUnknownPosition })
    }

    @Test("Renaming to an existing id is refused")
    func renameCollision() {
        var s = state()
        let before = s.doc.positions.map(\.id)
        s = Editor.reduce(s, .setPositionID(old: "LX 1", new: "BOOM SL"))
        #expect(s.doc.positions.map(\.id) == before, "collision must not rename")
    }

    @Test("Trim can be edited and clamped")
    func trimEdit() {
        var s = state()
        s = Editor.reduce(s, .setPositionTrim(id: "LX 1", trim: 7200))
        #expect(s.doc.position(id: "LX 1")?.trim == 7200)
        s = Editor.reduce(s, .setPositionTrim(id: "LX 1", trim: -100))
        #expect(s.doc.position(id: "LX 1")?.trim == 0)
    }

    @Test("Position type can change between truss, pipe and line")
    func typeEdit() {
        var s = state()
        s = Editor.reduce(s, .setPositionType(id: "LX 1", type: .pipe))
        #expect(s.doc.position(id: "LX 1")?.type == .pipe)
        s = Editor.reduce(s, .setPositionType(id: "LX 1", type: .truss))
        #expect(s.doc.position(id: "LX 1")?.type == .truss)
    }

    // MARK: 布景与光区

    @Test("Set pieces can be added, given a height and deleted")
    func setPieces() {
        var s = state()
        let piece = SetPiece(kind: .rect, x0: -1000, y0: 4000, x1: 1000, y1: 5000,
                             label: "PLATFORM")
        s = Editor.reduce(s, .addSetPiece(piece))
        #expect(s.doc.setPieces.count == 1)
        // 剖面图需要高度
        s = Editor.reduce(s, .setSetPieceHeight(id: piece.id, height: 1400))
        #expect(s.doc.setPieces[0].height == 1400)

        s = Editor.reduce(s, .deleteSetPiece(id: piece.id))
        #expect(s.doc.setPieces.isEmpty)
    }

    @Test("Zones can be added with the same id replaced, not duplicated")
    func zones() {
        var s = state()
        let z = Zone(id: "K2", x0: 0, y0: 3000, x1: 6000, y1: 8000)
        s = Editor.reduce(s, .addZone(z))
        #expect(s.doc.zones.filter { $0.id == "K2" }.count == 1)
        // 同 id 再添加 = 替换
        var moved = z
        moved.x1 = 7000
        s = Editor.reduce(s, .addZone(moved))
        #expect(s.doc.zones.filter { $0.id == "K2" }.count == 1)
        #expect(s.doc.zone(id: "K2")?.x1 == 7000)

        s = Editor.reduce(s, .deleteZone(id: "K2"))
        #expect(s.doc.zone(id: "K2") == nil)
    }

    // MARK: 综合

    @Test("A realistic edit session keeps the document valid")
    func realisticSession() {
        var s = state()
        // 输入真实条件
        s = Editor.reduce(s, .setMeta(.show, "THE VISIT"))
        s = Editor.reduce(s, .setMeta(.playwright, "DURRENMATT"))
        s = Editor.reduce(s, .setMeta(.venue, "STUDIO"))
        s = Editor.reduce(s, .setStage(.width, 12000))
        s = Editor.reduce(s, .setStage(.depth, 8000))
        s = Editor.reduce(s, .setStage(.audienceRake, 400))
        // 加一根桁架并挂灯
        s = Editor.reduce(s, .addPosition(Position(id: "LX 4", kind: .horizontal,
                                                  type: .truss, x0: -6000, x1: 6000,
                                                  y: 6000, trim: 6000)))
        s = Editor.reduce(s, .addFixture(
            Fixture(unit: 900, type: "profile", aim: 90, gel: "L201",
                    purpose: "NEW", beam: 26),
            at: s.layout.toSheet(Vec2(0, 6000))))

        #expect(s.doc.fixture(unit: 900)?.pos == "LX 4")
        #expect(s.state_isValid)
        // 视线现在应当全部通过（400mm 起坡足够）
        let sights = SectionSheet(fitting: s.doc).sightLines
        let blocked = sights.filter { !$0.seesStageFloor }
        #expect(blocked.isEmpty, "blocked rows: \(blocked.map { "\($0.row + 1):\(Int($0.margin))" })")
    }
}

private extension EditorState {
    /// 文档自洽：无错误，且所有构件上的灯都能解析。
    var state_isValid: Bool {
        guard errorCount == 0 else { return false }
        for f in doc.fixtures where !f.isFreeMounted {
            if Resolver.mount(of: f, in: doc).worldPoint == nil { return false }
        }
        return true
    }
}
