import Foundation

/// 表格导出（CSV）。
///
/// **图纸不能单独交付。** 装灯的人要的是"哪台灯挂哪根杆、装什么色片、
/// 接哪个通道"—— 这些在一张 A1 上挤不下，必须另有清单。
///
/// 设计原则：
///   · 每张表都能在 Excel / Numbers 里直接打开（UTF-8 BOM + CRLF）
///   · 列顺序与旧管线一致，交接时不用重新解释
///   · 分场景导出时，色片列显示**该场景实际用的色片**
public enum ScheduleCSV {

    // MARK: - 灯具表

    /// 灯具表：装灯与调光台的对照表。
    ///
    /// 列：POS,UNIT,TYPE,BEAM,GEL,PURPOSE,CH,WATT
    ///
    /// `WATT` 在 `study` 档位留空 —— 学生作业不出电学参数
    /// （那会让评审把注意力放到瓦数上，而不是光的组织）。
    public static func instrumentSchedule(_ doc: LXDocument,
                                          state: LightingState? = nil,
                                          includeWatt: Bool? = nil) -> String {
        let withWatt = includeWatt ?? (doc.meta.profile == "industry")
        var header = ["POS", "UNIT", "TYPE", "BEAM", "GEL", "PURPOSE", "CH"]
        if withWatt { header.append("WATT") }

        var rows: [String] = [header.joined(separator: ",")]

        for fixture in doc.fixtures.sorted(by: { $0.unit < $1.unit }) {
            let gel = state?.gel(for: fixture) ?? fixture.gelCode
            var cols = [
                fixture.pos ?? "",
                String(fixture.unit),
                doc.types[fixture.type]?.label ?? fixture.type.uppercased(),
                fixture.beam.map { String(Int($0)) } ?? "",
                gel,
                fixture.purpose ?? "",
                fixture.ch.map(String.init) ?? "",
            ]
            if withWatt {
                let watt = doc.types[fixture.type]?.watt
                cols.append(watt.map { String(Int($0)) } ?? "")
            }
            rows.append(cols.map(escape).joined(separator: ","))
        }
        return finish(rows)
    }

    // MARK: - 通道表

    /// 通道表：调光台配接用。
    ///
    /// 列：CH,POS,UNIT,TYPE,GEL,PURPOSE
    ///
    /// 与灯具表相比**按通道排序** —— 配接时是顺着通道号往上推的，
    /// 按灯号排会让人来回跳。
    public static func channelHookup(_ doc: LXDocument,
                                     state: LightingState? = nil) -> String {
        var rows: [String] = [["CH", "POS", "UNIT", "TYPE", "GEL", "PURPOSE"]
            .joined(separator: ",")]

        let sorted = doc.fixtures
            .filter { $0.ch != nil }
            .sorted { ($0.ch ?? 0) < ($1.ch ?? 0) }
        for f in sorted {
            let gel = state?.gel(for: f) ?? f.gelCode
            let cols = [
                f.ch.map(String.init) ?? "",
                f.pos ?? "",
                String(f.unit),
                doc.types[f.type]?.label ?? f.type.uppercased(),
                gel,
                f.purpose ?? "",
            ]
            rows.append(cols.map(escape).joined(separator: ","))
        }
        return finish(rows)
    }

    // MARK: - 色片用量

    /// 色片用量表：买料 / 裁片用。
    ///
    /// 列：GEL,NAME,COUNT,UNITS,SCENE
    ///
    /// 只有**实际点亮**的灯才计数 —— 场景里关掉的灯不需要色片。
    public static func gelUsage(_ doc: LXDocument,
                                state: LightingState? = nil) -> String {
        var rows: [String] = [["GEL", "NAME", "COUNT", "UNITS", "SCENE"]
            .joined(separator: ",")]

        // 按场景实际色片分组
        var byGel: [String: [Int]] = [:]
        for f in doc.fixtures {
            if let st = state, st.level(for: f) <= 0 { continue }
            let code = state?.gel(for: f) ?? f.gelCode
            byGel[code, default: []].append(f.unit)
        }

        for code in byGel.keys.sorted() {
            let units = byGel[code]!.sorted()
            let name = doc.gel(code: code)?.name ?? code
            let cols = [
                code,
                name,
                String(units.count),
                units.map(String.init).joined(separator: " "),
                state?.name ?? "ALL",
            ]
            rows.append(cols.map(escape).joined(separator: ","))
        }
        return finish(rows)
    }

    // MARK: - 场景对照

    /// 场景对照表：每个场景里每根构件的强度。
    ///
    /// 列：POSITION,<场景 1>,<场景 2>,…
    ///
    /// 这是"两个场景对比够不够"的可读版本 —— 一眼看出哪根杆被抽走了。
    public static func stateLevels(_ doc: LXDocument,
                                   states: LightingStateSet) -> String {
        guard !states.isEmpty else { return finish([""]) }
        var header = ["POSITION"] + states.states.map(\.name)
        var rows = [header.map(escape).joined(separator: ",")]

        // 构件 + 虚拟的 SET（台上实物）
        var ids = doc.positions.map(\.id)
        if doc.fixtures.contains(where: { $0.isFreeMounted }) { ids.append("SET") }

        for id in ids.sorted() {
            var cols = [id]
            for st in states.states {
                cols.append(String(Int(st.level(forPosition: id))))
            }
            rows.append(cols.map(escape).joined(separator: ","))
        }
        return finish(rows)
    }

    // MARK: - 组合导出

    /// 一次写出全部表格。
    /// - Returns: 写出的文件路径。
    @discardableResult
    public static func writeAll(_ doc: LXDocument,
                                states: LightingStateSet,
                                to dir: URL,
                                prefix: String = "") -> [URL] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        let stem = prefix.isEmpty ? "" : Stem.sanitize(prefix) + "-"

        func write(_ name: String, _ body: String) {
            let url = dir.appendingPathComponent(stem + name + ".csv")
            if (try? body.write(to: url, atomically: true, encoding: .utf8)) != nil {
                out.append(url)
            }
        }

        write("instrument_schedule", instrumentSchedule(doc))
        write("channel_hookup", channelHookup(doc))
        write("gel_usage", gelUsage(doc))
        if !states.isEmpty {
            write("scene_levels", stateLevels(doc, states: states))
            // 每个场景单独一份灯具表：色片不同，交接时不能混
            for st in states.states {
                write("instrument_\(st.id)", instrumentSchedule(doc, state: st))
            }
        }
        return out
    }

    // MARK: - CSV 细节

    /// 转义。逗号、引号、换行都必须处理，否则 Excel 会错列。
    static func escape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// 收尾：UTF-8 BOM（Excel 认）+ CRLF（Windows/Numbers 都认）。
    ///
    /// 不加 BOM 的话，Excel 会把 UTF-8 当 Latin-1，
    /// 带重音的剧名会变成乱码。
    static func finish(_ rows: [String]) -> String {
        "\u{FEFF}" + rows.joined(separator: "\r\n") + "\r\n"
    }
}
