import Testing
import Foundation
@testable import LightPlotCore

/// 图上印的比例行必须与实际渲染的比例、实际的纸张**完全一致**。
///
/// 这条守的是一类特别危险的缺陷：图看起来正常，但标注的比例是错的。
/// 早先平面图硬编码 "ON A1" 且读 `doc.meta.scale`，
/// 于是打到 A3@1:50 的图上印着 "1:25 ON A1" ——
/// **一张印错比例的图比没有图更危险，装灯的人会照它量。**
@Suite("Stated scale")
struct ScaleStatedTests {

    /// 每一档纸张 × 每一个常用比例，图上写的都必须对。
    @Test("The stated scale matches the sheet and the scale actually used")
    func statedScaleIsTrue() throws {
        let doc = try TestData.realDocument()

        let papers: [PaperSize] = PaperSize.all
        let scales: [Double] = [100, 50, 25, 20, 10]

        for paper in papers {
            for scale in scales {
                let sheet = PlanSheet(fitting: doc, paper: paper, scale: scale,
                                      lightingState: nil)
                let stated = sheet.ops.compactMap { op -> String? in
                    if case .text(let t) = op, t.string.hasPrefix("SCALE 1:") {
                        return t.string
                    }
                    return nil
                }
                // 装不下时不出比例行（改出提示页），这条循环只覆盖能装下的情形
                guard sheet.contentFitsSheet else { continue }
                #expect(!stated.isEmpty,
                        "\(paper.name)@1:\(Int(scale)): no scale line at all")
                let line = stated.joined(separator: " ")
                #expect(line.contains("1:\(Int(scale))"),
                        "\(paper.name): says '\(line)', actual scale is 1:\(Int(scale))")
                #expect(line.contains(paper.name),
                        "\(paper.name): says '\(line)', actual paper is \(paper.name)")
            }
        }
    }

    /// **每一条**提到比例的文字都必须说真话，包括图签格里那句。
    ///
    /// 这条是补漏：早先的检查只查以 "SCALE 1:" 开头的说明行，
    /// 而图签格里还有一句 "SCALE: 1:25 @ A1" —— 它同样硬编码。
    /// 实测在 A4@1:100 的图上，说明行正确、图签格却仍写 "1:25 @ A1"。
    /// 判据改成："任何包含 `1:` 的文字，其中的数字必须是当前比例"。
    @Test("No line anywhere may state a scale other than the real one")
    func everyScaleMentionIsTrue() throws {
        let doc = try TestData.realDocument()
        for paper in [PaperSize.a0, .a1, .a2, PaperSize(standard: .a4, orientation: .landscape)] {
            for scale in [100.0, 50, 25] {
                let sheet = PlanSheet(fitting: doc, paper: paper, scale: scale,
                                      lightingState: nil)
                guard sheet.contentFitsSheet else { continue }
                let label = "\(paper.name)@1:\(Int(scale))"

                for op in sheet.ops {
                    guard case .text(let t) = op else { continue }
                    // 只检查"比例陈述"：含 "1:" 且不含这些非比例意义的词
                    // 只检查"比例陈述"，不检查"建议用别的比例"那句话。
                    guard t.string.contains("SCALE"), t.string.contains("1:")
                    else { continue }
                    // 抽出所有 1:N 里的 N
                    var found: [Int] = []
                    let chars = Array(t.string)
                    var i = 0
                    while i + 1 < chars.count {
                        if chars[i] == "1", chars[i + 1] == ":" {
                            var j = i + 2
                            var digits = ""
                            while j < chars.count, chars[j].isNumber {
                                digits.append(chars[j]); j += 1
                            }
                            if let n = Int(digits) { found.append(n) }
                            i = j
                        } else { i += 1 }
                    }
                    for n in found {
                        #expect(n == Int(scale),
                                "\(label): '\(t.string)' claims 1:\(n)")
                    }
                }
            }
        }
    }

    /// 纸张名必须由实际尺寸推出 —— 换朝向也是同一个幅面名。
    @Test("Paper names come from the actual dimensions")
    func paperNames() {
        for std in PaperSize.PaperStandard.allCases {
            let land = PaperSize(standard: std, orientation: .landscape)
            let port = PaperSize(standard: std, orientation: .portrait)
            #expect(land.name == port.name,
                    "\(std): landscape and portrait must share a name")
            #expect(!land.name.isEmpty)
            // 幅面名要么是全大写（A1 / A0），要么是专有名词的原样写法
            // （Letter / Tabloid）—— 只要稳定且唯一即可。
            #expect(land.name.uppercased() == std.rawValue.uppercased(),
                    "\(std): got '\(land.name)'")
        }
        // 非标准尺寸不能冒充标准幅面
        let custom = PaperSize(widthMM: 1000, heightMM: 700)
        #expect(custom.name == "1000x700", "got '\(custom.name)'")
        #expect(custom.standard == nil)
    }

    /// 剖面图同样不能撒谎。
    @Test("Section sheets state their real paper and scale")
    func sectionStatedScale() throws {
        let doc = try TestData.realDocument()
        for (paper, scale) in [(PaperSize.a3, 50.0), (PaperSize.a1, 50.0),
                               (PaperSize.a2, 100.0)] {
            let sheet = SectionSheet(fitting: doc, paper: paper, scale: scale,
                                     lightingState: nil)
            guard sheet.contentFitsSheet else { continue }
            let lines = sheet.ops.compactMap { op -> String? in
                if case .text(let t) = op, t.string.contains("SCALE 1:") {
                    return t.string
                }
                return nil
            }
            let joined = lines.joined(separator: " | ")
            #expect(joined.contains("1:\(Int(scale))"),
                    "\(paper.name): '\(joined)' claims the wrong scale")
            #expect(joined.contains(paper.name),
                    "\(paper.name): '\(joined)' claims the wrong paper")
        }
    }

    /// 溢出提示页也必须点名是哪张纸 —— 否则用户不知道该改什么。
    @Test("Overflow notices name the sheet that failed")
    func overflowNamesSheet() throws {
        let doc = try TestData.realDocument()
        // 真实数据 16.5×13.4m，A3@1:50 装不下（能装 15.5×12.4m）
        let sheet = PlanSheet(fitting: doc, paper: .a3, scale: 50, lightingState: nil)
        #expect(!sheet.contentFitsSheet)
        let text = sheet.ops.compactMap { op -> String? in
            if case .text(let t) = op { return t.string }
            return nil
        }.joined(separator: " ")
        #expect(text.contains("ON A3 AT 1:50"))
        #expect(text.contains("A3 holds"))
        // 也必须说清实际内容多大，否则用户不知道差多少
        #expect(text.contains("Content is"))
    }
}
