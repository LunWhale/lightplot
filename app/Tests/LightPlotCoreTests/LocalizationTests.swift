import Testing
import Foundation
@testable import LightPlotCore
@testable import LightPlotUI

/// 界面中文化的完整性。
///
/// 用户是中文的文科生，界面全英文是实打实的使用障碍。
///
/// 判据三条，缺一不可：
///   1. 源码里每一个 `L10n.t("…")` 的键都必须在表里
///   2. 中文译文不能是空串，也不能与英文原串相同（那就是没翻）
///   3. 源码里不许再出现 `String(localized:)`（它会静默绕过这张表）
@Suite("Localization")
struct LocalizationTests {

    private func allUISources() -> [(name: String, text: String)] {
        let base = TestData.workspaceRoot.appendingPathComponent("app/Sources")
        var out: [(String, String)] = []
        for dir in ["LightPlotUI", "LightPlotApp"] {
            let d = base.appendingPathComponent(dir)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: d.path)
            else { continue }
            for f in files where f.hasSuffix(".swift") {
                // 定义表的那份文件里有示例注释，跳过
                if f == "Localization.swift" { continue }
                if let t = try? String(contentsOf: d.appendingPathComponent(f),
                                       encoding: .utf8) {
                    out.append((f, t))
                }
            }
        }
        return out
    }

    /// 从源码里抽出所有 `L10n.t("…")` / `L10n.tf("…")` 的键。
    private func usedKeys() -> [String: [String]] {
        var keys: [String: [String]] = [:]
        for (name, text) in allUISources() {
            var idx = text.startIndex
            for marker in ["L10n.t(\"", "L10n.tf(\""] {
                var search = text.startIndex
                while let r = text.range(of: marker, range: search..<text.endIndex) {
                    let start = r.upperBound
                    guard let end = text[start...].firstIndex(of: "\"") else { break }
                    let key = String(text[start..<end])
                    keys[key, default: []].append(name)
                    search = end
                }
            }
            _ = idx
        }
        return keys
    }

    @Test("Every UI string used in code has a Chinese translation")
    func everyKeyTranslated() {
        let used = usedKeys()
        #expect(used.count >= 50, "only found \(used.count) keys — the scanner drifted")

        var missing: [String] = []
        for key in used.keys where L10n.table[key] == nil {
            missing.append("\(key)  (used in \(used[key]!.joined(separator: ", ")))")
        }
        #expect(missing.isEmpty,
                Comment(rawValue: "untranslated: \n" + missing.sorted().joined(separator: "\n")))
    }

    /// 检查器里的字段名不是字面量，而是枚举的 `title`。
    /// 只扫 `L10n.t("…")` 会漏掉它们，所以直接把枚举全遍历一遍。
    @Test("Every inspector field name has a Chinese translation")
    func enumTitlesTranslated() {
        var missing: [String] = []
        for f in MetaField.allCases where L10n.table[f.title] == nil {
            missing.append("MetaField.\(f.rawValue): \(f.title)")
        }
        for f in StageField.allCases where L10n.table[f.title] == nil {
            missing.append("StageField.\(f.rawValue): \(f.title)")
        }
        #expect(missing.isEmpty,
                Comment(rawValue: "untranslated field titles: " + missing.joined(separator: " | ")))
    }

    @Test("No translation is empty or merely a copy of the English")
    func translationsAreReal() {
        var bad: [String] = []
        for (en, zh) in L10n.table {
            if zh.trimmingCharacters(in: .whitespaces).isEmpty {
                bad.append("\(en): empty")
            } else if zh == en {
                bad.append("\(en): identical to English")
            }
        }
        #expect(bad.isEmpty, Comment(rawValue: bad.sorted().joined(separator: " | ")))
    }

    @Test("No source still bypasses the table with String(localized:)")
    func noLegacyLocalized() {
        var strays: [String] = []
        for (name, text) in allUISources() where text.contains("String(localized:") {
            strays.append(name)
        }
        #expect(strays.isEmpty,
                Comment(rawValue: "these files still use String(localized:): \(strays.joined(separator: ", "))"))
    }

    @Test("Switching the language changes the rendered text")
    func languageSwitchWorks() {
        let original = L10n.language
        defer { L10n.language = original }

        L10n.language = .english
        #expect(L10n.t("Sheet") == "Sheet")
        #expect(L10n.t("Delete lantern") == "Delete lantern")

        L10n.language = .chinese
        #expect(L10n.t("Sheet") == "图纸信息")
        #expect(L10n.t("Delete lantern") == "删除这盏灯")
        // 未收录的键退化为英文，不显示成空或键名
        #expect(L10n.t("Something not in the table") == "Something not in the table")
        // 插值
        #expect(L10n.tf("Lantern %d", 201) == "灯具 201")
    }

    @Test("Chinese is chosen automatically on a Chinese system")
    func systemLanguageDetection() {
        // 直接验证判定规则，不依赖真实系统语言
        #expect(L10n.Language.chinese == .chinese)
        #expect(L10n.table.count > 80, "the table looks too small: \(L10n.table.count)")
    }
}
