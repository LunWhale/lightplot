import Foundation
import LightPlotCore
import LightPlotUI

/// `lpx` —— LightPlot 的命令行入口。
///
/// 为什么一个图形应用需要 CLI：
///   1. **无头验证**：所有几何/排版都能在没有窗口的情况下跑，才能在 CI 里回归
///   2. **差分 oracle**：同一份数据，`lpx` 与旧 Python 管线各出一份摘要，逐行比对
///   3. **交付兜底**：图形界面出问题时，学生仍然能拿到图
///
/// 有意保持极简：只做"读文件 → 做事 → 打印/写文件"，不依赖 AppKit/SwiftUI。

enum Command {
    case digest(String)
    case lint(String, strict: Bool)
    case render(String, String)
    case yaml(String, String)
    case diff(String, String)
    case snapshot(String, String, beams: Bool)
    case section(String, String)
    case scene(String, String, String)
    case csv(String, String, String?)
    case sectionState(String, String, String)
    case verifyOld(String, String)
    case help
    case version
}

func parse(_ args: [String]) -> Command {
    var rest = args
    guard !rest.isEmpty else { return .help }
    let head = rest.removeFirst()
    switch head {
    case "digest":
        guard let f = rest.first else { return .help }
        return .digest(f)
    case "lint":
        guard let f = rest.first else { return .help }
        return .lint(f, strict: rest.contains("--strict"))
    case "render":
        guard rest.count >= 2 else { return .help }
        return .render(rest[0], rest[1])
    case "yaml":
        guard rest.count >= 2 else { return .help }
        return .yaml(rest[0], rest[1])
    case "diff":
        guard rest.count >= 2 else { return .help }
        return .diff(rest[0], rest[1])
    case "section-state":
        guard rest.count >= 3 else { return .help }
        return .sectionState(rest[0], rest[1], rest[2])
    case "verify-old":
        guard rest.count >= 2 else { return .help }
        return .verifyOld(rest[0], rest[1])
    case "csv":
        guard rest.count >= 2 else { return .help }
        return .csv(rest[0], rest[1], rest.count >= 3 ? rest[2] : nil)
    case "scene":
        guard rest.count >= 3 else { return .help }
        return .scene(rest[0], rest[1], rest[2])
    case "section":
        guard rest.count >= 2 else { return .help }
        return .section(rest[0], rest[1])
    case "snapshot":
        guard rest.count >= 2 else { return .help }
        return .snapshot(rest[0], rest[1], beams: !rest.contains("--no-beams"))
    case "--version", "-v", "version":
        return .version
    default:
        return .help
    }
}

func load(_ path: String) throws -> LXDocument {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    // 按扩展名选择解析器；.lpx 是应用自己的 JSON 格式。
    if url.pathExtension.lowercased() == "lpx" {
        return try DocumentCodec.decodeJSON(data)
    }
    return try DocumentCodec.decodeYAML(data)
}

func printHelp() {
    print("""
    lpx — LightPlot command line

    USAGE
      lpx digest <file>            print a stable sheet digest (for diffing)
      lpx lint <file> [--strict]   print validation issues; --strict fails on warnings
      lpx render <file> <out.pdf>  render the plan sheet to a vector PDF
      lpx yaml <file> <out.yaml>   normalise a document to YAML
      lpx section <file> <out.pdf>    render the section sheet (A3 @ 1:50)
      lpx section-state <rig.yaml> <scenes.yaml> <outDir>
                                      render one section PDF per scene state
      lpx csv <rig.yaml> <outDir> [scenes.yaml]
                                      export instrument / channel / gel / scene CSVs
      lpx scene <rig.yaml> <scenes.yaml> <outDir>
                                      render one plan PDF per scene state
      lpx snapshot <file> <out.png>   render the canvas exactly as the app does
      lpx diff <oracle.txt> <candidate.txt>
                                   compare two digests; non-zero exit on
                                   undeclared differences
      lpx verify-old <rig.yaml> <old-out-dir>
                                   compare a document against the frozen PDFs
                                   the Python pipeline produced; non-zero exit
                                   on any lantern, gel, total or paper mismatch
      lpx --reproducible <command>  make the written PDFs byte-identical
                                   across runs (pins dates and doc id)
      lpx --version

    Files ending in .lpx are read as JSON, everything else as YAML.
    """)
}

func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

/// `--reproducible`：把 PDF 里的时间戳与文档 ID 钉成固定值，
/// 使同一份数据两次出图**逐字节相同**。
///
/// 为什么需要：设计师会反复出图对比。如果每次字节都变（只是生成时间变了），
/// 就分不清"图改了"和"又生成了一次"，也没法用 `git diff` 看版本差异。
///
/// 默认关闭 —— 正式交付的图纸里带上真实生成时间是正当信息。
let reproducibleOutput = CommandLine.arguments.contains("--reproducible")

func finalisePDF(_ path: String) throws {
    guard reproducibleOutput else { return }
    try PDFReproducible.normalise(fileAt: URL(fileURLWithPath: path))
}

// 全局开关要先剥离，否则会被当成子命令
// （`lpx --reproducible render …` 的 args[0] 是 `--reproducible`）。
let args = Array(CommandLine.arguments.dropFirst()).filter { $0 != "--reproducible" }
let command = parse(args)

do {
    switch command {
    case .version:
        print("lpx \(LightPlotVersion.string)")

    case .help:
        printHelp()

    case .digest(let path):
        let doc = try load(path)
        // 摘要必须反映**真实版面**（自动放置后的原点），否则它描述的图和实际出的图不是一张。
        let layout = SheetLayout.fitted(to: doc.contentBounds,
                                        paper: .a1,
                                        scaleDenominator: doc.meta.scale)
        print(SheetDigest.render(doc, layout: layout), terminator: "")

    case .lint(let path, let strict):
        var doc = try load(path)
        // **校验必须看到与实际出图相同的文档。**
        //
        // 早先 `lint` 直接用原文档，而 `render` 会先从内建库补全色片颜色。
        // 两个命令对同一份数据给出不同判断 —— `--strict` 因此把
        // "色片表没写色值" 报成 8 条警告并拒绝出图，
        // 而那 8 个色值根本不需要用户提供（库里就有）。
        // 这种"门禁挡住的其实不是问题"的失败最消耗信任。
        let filled = GelLibrary.fillMissingColours(in: &doc)
        let issues = Lint.check(doc)
        if filled > 0 {
            print("note: \(filled) gel colour(s) taken from the built-in library")
        }
        if issues.isEmpty {
            print("OK — no issues")
        } else {
            for issue in issues {
                print("[\(issue.severity.rawValue.uppercased())] \(issue.code.rawValue)  \(issue.subject)")
                print("        \(issue.message)")
            }
        }
        let errors = issues.filter { $0.severity == .error }.count
        let warnings = issues.filter { $0.severity == .warning }.count
        print("\n\(errors) error(s), \(warnings) warning(s)")
        if errors > 0 || (strict && warnings > 0) { exit(1) }

    case .render(let inPath, let outPath):
        var doc = try load(inPath)
        // 补全色片真实颜色：只填空缺，不覆盖用户自定义值。
        let filled = GelLibrary.fillMissingColours(in: &doc)
        if filled > 0 { print("filled \(filled) gel colour(s) from the built-in library") }
        let sheet = PlanSheet(fitting: doc)
        if !sheet.contentFitsSheet {
            let b = sheet.layout.sheetBounds(of: doc.contentBounds)
            FileHandle.standardError.write(Data("""
            warning: content does not fit the sheet at 1:\(Int(doc.meta.scale))
                     content on paper: \(fmt(b.x0)),\(fmt(b.y0)) -> \(fmt(b.x1)),\(fmt(b.y1))
                     plan area:        \(fmt(SheetLayout.planArea(paper: .a1).x0)),\(fmt(SheetLayout.planArea(paper: .a1).y0)) -> \(fmt(SheetLayout.planArea(paper: .a1).x1)),\(fmt(SheetLayout.planArea(paper: .a1).y1))

            """.utf8))
        }
        try SheetPDF.write(sheet, to: URL(fileURLWithPath: outPath))
        try finalisePDF(outPath)
        print("wrote \(outPath)  ops=\(sheet.ops.count) text=\(sheet.textCount) polys=\(sheet.polygonCount)")

    case .yaml(let inPath, let outPath):
        let doc = try load(inPath)
        let text = try DocumentCodec.encodeYAML(doc)
        try text.write(toFile: outPath, atomically: true, encoding: .utf8)
        print("wrote \(outPath)")

    case .sectionState(let rigPath, let scenePath, let outDir):
        var doc = try load(rigPath)
        _ = GelLibrary.fillMissingColours(in: &doc)
        let set = try LightingStateCodec.decodeYAML(Data(contentsOf: URL(fileURLWithPath: scenePath)))
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for state in set.states {
            let sheet = SectionSheet(fitting: doc, paper: .a3, scale: 50,
                                     lightingState: state)
            let stem = Stem.sanitize("LX_section_\(state.id)").lowercased()
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(stem + ".pdf")
            try SheetPDF.write(sheet, to: url)
            try finalisePDF(url.path)
            print("wrote \(url.path)  lit=\(state.litCount(in: doc))/\(doc.fixtures.count)")
        }

    case .csv(let rigPath, let outDir, let scenePath):
        var doc = try load(rigPath)
        _ = GelLibrary.fillMissingColours(in: &doc)
        var states = LightingStateSet()
        if let scenePath {
            states = (try? LightingStateCodec.decodeYAML(
                Data(contentsOf: URL(fileURLWithPath: scenePath)))) ?? LightingStateSet()
        }
        let urls = ScheduleCSV.writeAll(doc, states: states,
                                        to: URL(fileURLWithPath: outDir),
                                        prefix: doc.meta.show)
        for u in urls { print("wrote \(u.path)") }
        print("\(urls.count) table(s)")

    case .scene(let rigPath, let scenePath, let outDir):
        var doc = try load(rigPath)
        _ = GelLibrary.fillMissingColours(in: &doc)
        let set = try LightingStateCodec.decodeYAML(Data(contentsOf: URL(fileURLWithPath: scenePath)))
        guard !set.isEmpty else {
            print("no scene states found in \(scenePath)"); break
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for state in set.states {
            let sheet = PlanSheet(fitting: doc, paper: .a1, scale: doc.meta.scale,
                                  lightingState: state)
            let stem = Stem.sanitize("LX_plan_\(state.id)").lowercased()
            let url = URL(fileURLWithPath: outDir).appendingPathComponent(stem + ".pdf")
            try SheetPDF.write(sheet, to: url)
            try finalisePDF(url.path)
            print("wrote \(url.path)  ops=\(sheet.ops.count)  lit=\(state.litCount(in: doc))/\(doc.fixtures.count)")
        }

    case .section(let inPath, let outPath):
        var doc = try load(inPath)
        _ = GelLibrary.fillMissingColours(in: &doc)
        let sheet = SectionSheet(fitting: doc)
        if !sheet.contentFitsSheet {
            let b = sheet.layout.toSheet(depth: doc.sectionContentBounds.x0,
                                          height: doc.sectionContentBounds.y0)
            FileHandle.standardError.write(Data("""
            warning: section does not fit A3 at 1:\(Int(sheet.layout.scaleDenominator))
                     (content starts at \(fmt(b.x)),\(fmt(b.y)) on paper)

            """.utf8))
        }
        try SheetPDF.write(sheet, to: URL(fileURLWithPath: outPath))
        let blocked = sheet.sightLines.filter { !$0.seesStageFloor }.count
        print("wrote \(outPath)  ops=\(sheet.ops.count) text=\(sheet.textCount) polys=\(sheet.polygonCount)")
        if !sheet.sightLines.isEmpty {
            print("sightlines: \(blocked) of \(sheet.sightLines.count) rows blocked")
        }

    case .snapshot(let inPath, let outPath, let beams):
        let doc = try load(inPath)
        // 顶层调用需要主线程（SwiftUI 渲染）
        let url = URL(fileURLWithPath: outPath)
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            do {
                try CanvasSnapshot.write(doc: doc, to: url, width: 1800, scale: 2, showBeams: beams)
            } catch { failure = error }
            sem.signal()
        }
        // 主线程就是当前线程时不能 wait；改用 RunLoop 轮询
        while sem.wait(timeout: .now()) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
        if let failure { throw failure }
        print("wrote \(outPath)")

    case .verifyOld(let rig, let oldDir):
        let doc = try DocumentCodec.decodeYAML(Data(contentsOf: URL(fileURLWithPath: rig)))
        // 同目录下有 scenes.yaml 就一并比对场景图（kitchen / boston）。
        let rigURL = URL(fileURLWithPath: rig)
        let scenesURL = rigURL.deletingLastPathComponent()
            .appendingPathComponent("scenes.yaml")
        var states: LightingStateSet?
        if FileManager.default.fileExists(atPath: scenesURL.path) {
            states = try LightingStateCodec.decodeYAML(Data(contentsOf: scenesURL))
        }
        let r = try OldPipelineCheck.run(doc: doc,
                                         oldOutDir: URL(fileURLWithPath: oldDir),
                                         states: states)
        print(r.text)
        if !r.passed { exit(2) }

    case .diff(let a, let b):
        let oracle = try String(contentsOfFile: a, encoding: .utf8)
        let candidate = try String(contentsOfFile: b, encoding: .utf8)
        let report = DifferentialOracle.report(oracle: oracle, candidate: candidate)
        print(report, terminator: "")
        if !DifferentialOracle.undeclaredDifferences(oracle: oracle, candidate: candidate).isEmpty {
            exit(2)
        }
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
