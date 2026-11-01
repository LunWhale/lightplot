import Testing
import Foundation
@testable import LightPlotCore

/// 表格导出。
///
/// 图纸不能单独交付：装灯的人要的是"哪台灯挂哪根杆、装什么色片、
/// 接哪个通道"。这些在一张 A1 上挤不下，必须另有清单。
///
/// 第一版完全没有 CSV 导出 —— 而旧管线有三份。
@Suite("Schedule CSV")
struct ScheduleCSVTests {

    private func parse(_ text: String) -> [[String]] {
        text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            }
    }

    @Test("The instrument schedule has one row per lantern")
    func instrumentRows() throws {
        let doc = try TestData.realDocument()
        let csv = ScheduleCSV.instrumentSchedule(doc)
        let rows = parse(csv)
        #expect(rows.first == ["POS", "UNIT", "TYPE", "BEAM", "GEL", "PURPOSE", "CH"])
        #expect(rows.count == 1 + doc.fixtures.count, "expected \(doc.fixtures.count) rows")

        // 每台灯都在
        let units = Set(rows.dropFirst().compactMap { Int($0[1]) })
        #expect(units.count == doc.fixtures.count)
    }

    @Test("The schedule never emits wattage in study profile")
    func noWattInStudy() throws {
        var doc = try TestData.realDocument()
        doc.meta.profile = "study"
        let csv = ScheduleCSV.instrumentSchedule(doc)
        #expect(!csv.contains("WATT"))

        doc.meta.profile = "industry"
        #expect(ScheduleCSV.instrumentSchedule(doc).contains("WATT"))
    }

    @Test("A scene schedule prints the scene's gels")
    func sceneGels() throws {
        let doc = try TestData.realDocument()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
        let set = try LightingStateCodec.decodeYAML(Data(contentsOf: url))
        let kitchen = set.state(id: "kitchen")!

        let base = parse(ScheduleCSV.instrumentSchedule(doc))
        let scen = parse(ScheduleCSV.instrumentSchedule(doc, state: kitchen))

        let baseGels = Set(base.dropFirst().map { $0[4] })
        let scenGels = Set(scen.dropFirst().map { $0[4] })
        #expect(baseGels.contains("L132"))
        #expect(scenGels.contains("L202"))
        #expect(!scenGels.contains("L132"), "scene schedule must not list the base gel")
    }

    @Test("The channel hookup is sorted by channel")
    func hookupSorted() throws {
        let doc = try TestData.realDocument()
        let rows = parse(ScheduleCSV.channelHookup(doc))
        let channels = rows.dropFirst().compactMap { Int($0[0]) }
        #expect(!channels.isEmpty)
        #expect(channels == channels.sorted(), "hookup must read in channel order")
    }

    @Test("Gel usage counts only lanterns that are on")
    func gelUsageCounts() throws {
        let doc = try TestData.realDocument()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
        let set = try LightingStateCodec.decodeYAML(Data(contentsOf: url))
        let kitchen = set.state(id: "kitchen")!

        let rows = parse(ScheduleCSV.gelUsage(doc, state: kitchen))
        // 合计应等于该场景点亮灯数
        let total = rows.dropFirst().compactMap { Int($0[2]) }.reduce(0, +)
        #expect(total == kitchen.litCount(in: doc),
                "gel usage total \(total) != lit count \(kitchen.litCount(in: doc))")
    }

    @Test("The scene level table shows how each bar changes")
    func sceneLevels() throws {
        let doc = try TestData.realDocument()
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
        let set = try LightingStateCodec.decodeYAML(Data(contentsOf: url))

        let rows = parse(ScheduleCSV.stateLevels(doc, states: set))
        #expect(rows[0].count == 1 + set.states.count)
        // BOOM SR 在 boston 45、kitchen 0 —— 一眼看出被抽走
        let boomSR = rows.first { $0[0] == "BOOM SR" }
        #expect(boomSR != nil)
        #expect(boomSR!.contains("0"), "BOOM SR must read 0 in one of the scenes")
    }

    @Test("CSV quoting handles commas and quotes")
    func quoting() {
        #expect(ScheduleCSV.escape("plain") == "plain")
        #expect(ScheduleCSV.escape("a,b") == "\"a,b\"")
        #expect(ScheduleCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(ScheduleCSV.escape("line\nbreak") == "\"line\nbreak\"")
    }

    /// Excel 认 BOM；不加就是乱码。
    @Test("Files start with a UTF-8 BOM so Excel opens them correctly")
    func bom() throws {
        let doc = try TestData.realDocument()
        let csv = ScheduleCSV.instrumentSchedule(doc)
        #expect(csv.hasPrefix("\u{FEFF}"), "BOM missing — Excel would show mojibake")
        #expect(csv.contains("\r\n"), "CRLF keeps Windows and Numbers happy")
    }

    @Test("writeAll produces every table plus one per scene")
    func writeAll() throws {
        var doc = try TestData.realDocument()
        _ = GelLibrary.fillMissingColours(in: &doc)
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("data/scenes.yaml")
        let set = try LightingStateCodec.decodeYAML(Data(contentsOf: url))

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let urls = ScheduleCSV.writeAll(doc, states: set, to: dir, prefix: "TEST")
        #expect(urls.count == 4 + set.states.count)
        for u in urls {
            // BOM 要读**原始字节** —— String(contentsOf:) 会自动剥掉它，
            // 用它检查 BOM 会永远失败。
            let raw = try Data(contentsOf: u)
            #expect(raw.starts(with: [0xEF, 0xBB, 0xBF]),
                    "\(u.lastPathComponent) is missing the UTF-8 BOM")

            let body = try String(contentsOf: u, encoding: .utf8)
            let lines = body.components(separatedBy: "\r\n").filter { !$0.isEmpty }
            #expect(lines.count >= 2, "\(u.lastPathComponent) has only \(lines.count) line(s)")
        }
    }

    @Test("An empty document still produces valid headers")
    func emptyDoc() {
        let doc = LXDocument()
        let csv = ScheduleCSV.instrumentSchedule(doc)
        let rows = parse(csv)
        #expect(rows.count == 1, "header only")
        #expect(rows[0].contains("UNIT"))
    }
}
