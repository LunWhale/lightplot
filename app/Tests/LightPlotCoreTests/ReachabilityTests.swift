import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 模型支持的每一个编辑动作，界面上都必须够得着。
///
/// "实现了但用户碰不到"与"没实现"对用户来说是同一件事。
/// 这条测试直接读源码做静态检查 —— 朴素但有效：
/// 新增一个 `EditorEvent` 而忘了接线，这里会立刻变红。
@Suite("UI reachability")
struct ReachabilityTests {

    private func sources(_ dir: String) -> String {
        let base = TestData.workspaceRoot.appendingPathComponent("app/Sources/\(dir)")
        var out = ""
        if let files = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
            for f in files where f.hasSuffix(".swift") {
                out += (try? String(contentsOf: base.appendingPathComponent(f),
                                    encoding: .utf8)) ?? ""
            }
        }
        return out
    }

    @Test("Every user-facing editor event is dispatched from the UI")
    func allEventsReachable() throws {
        let eventSource = try String(
            contentsOf: TestData.workspaceRoot
                .appendingPathComponent("app/Sources/LightPlotCore/Editor/EditorEvent.swift"),
            encoding: .utf8)

        // 抓 `case name(` 形式的事件名；下划线开头的是内部字段写入器
        var names: [String] = []
        for line in eventSource.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("case "), let paren = t.firstIndex(of: "(") else { continue }
            let name = String(t[t.index(t.startIndex, offsetBy: 5)..<paren])
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && !name.hasPrefix("_") { names.append(name) }
        }
        #expect(names.count >= 20, "only found \(names.count) events — the parser drifted")

        let ui = sources("LightPlotUI") + sources("LightPlotApp")
        var unreachable: [String] = []
        for n in Set(names).sorted() where !ui.contains(".\(n)(") {
            unreachable.append(n)
        }
        #expect(unreachable.isEmpty,
                Comment(rawValue: "not reachable from the UI: \(unreachable.joined(separator: ", "))"))
    }
}
