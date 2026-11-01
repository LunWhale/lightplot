import Foundation

/// 文字避让：把互相压住的标注丢掉，并**如实报告丢了多少**。
///
/// ## 为什么需要
///
/// 图纸"装得下"不等于"读得出来"。例：A0 上以 1:100 画 15m 舞台，
/// 舞台只有 150mm 宽，32 台灯的标注块（通道圈 + 色片号 + 灯号，
/// 每块约 15mm）根本放不下 —— 结果是一团重叠的黑块。
///
/// 这类图最危险，因为它**看起来像是出图成功了**：
/// —— 页面尺寸对、灯数对、文件也不空。
/// 只有把字真正量出来，才知道读不了。
///
/// ## 优先级
///
/// 越重要的越先占位；后来者若与已占位者重叠，就丢弃自己。
/// 顺序（高 → 低）：
///
/// | 层 | 内容 | 丢掉后果 |
/// |---|---|---|
/// | `TB_TEXT` / `TITLEBLK` / `NOTES` / `DIM` | 图签、说明、尺寸 | 不可丢 |
/// | `BORDER` / `GRIDTEXT` | 分区刻度 | 不可丢 |
/// | `LEGEND` | 图例 | 不可丢（执行依据） |
/// | `ZONE` | 表演区名 | 可丢（边界线还在） |
/// | `SET` | 布景名 | 可丢（形状还在） |
/// | `STAGE` / `DIM` | 台面标注 | 优先保留 |
/// | `FIXTURE_TXT` / `MARK` | 灯号、色片、通道 | **丢了要说话** |
///
/// 最后两档是"核心信息"：如果它们被丢掉，`PlanSheet` 必须在图上
/// 印一行说明，告诉读图人这张纸读不了、该换更大的比例。
public enum TextFitter {

    /// 一次避让结果。
    public struct Result: Sendable {
        public var ops: [DrawOp]
        /// 被丢弃的文字数，按层统计。
        public var dropped: [String: Int]
        /// 是否丢了核心信息（灯号 / 色片 / 通道）。
        public var lostEssentialLabels: Bool {
            dropped["FIXTURE_TXT", default: 0] > 0 || dropped["MARK", default: 0] > 0
        }
        public var totalDropped: Int { dropped.values.reduce(0, +) }
    }

    /// 不可丢弃的层（图签、说明、边框、图例）。
    static let protectedLayers: Set<String> = [
        "TB_TEXT", "TITLEBLK", "NOTES", "BORDER", "GRIDTEXT", "LEGEND", "LEGEND_SYM",
    ]

    /// 核心信息的层 —— 丢了就要在图上说明。
    static let essentialLayers: Set<String> = ["FIXTURE_TXT", "MARK"]

    /// 优先级：数字越大越先占位。
    static func priority(of layer: String?) -> Int {
        guard let layer else { return 60 }
        switch layer {
        case "TB_TEXT", "TITLEBLK", "NOTES", "BORDER", "GRIDTEXT", "LEGEND", "LEGEND_SYM":
            return 1000
        case "STAGE", "ZONE":
            return 500
        case "SET", "SET_DASH":
            return 400
        // **色片号必须比标高优先。**
        //
        // 标高（`+6500`）在剖面图的构件表里有完整一份，
        // 而色片号只在这张图上 —— 丢了色片号，装片的人就会装错。
        // 早先 DIM 排在 FIXTURE_TXT 之上，于是两者相撞时
        // 被丢掉的是色片（实测 A1@1:50 的 'L119'）。
        case "FIXTURE_TXT":
            return 330
        case "MARK":
            return 320
        // 构件名（TRUSS / PIPE 图层上的文字）让位于灯具标注。
        //
        // 依据：杆本身画在图上，自己的标高与构件表里也有名字；
        // 而通道号**只出现在这一处** —— 丢了就没法排线。
        // 实测《The Visit》数据里，SET EDGE 上的一台实物灯放在 y=2000，
        // 正好压住 LX 1 的构件名，于是通道号 91 被丢掉了。
        case "TRUSS", "PIPE":
            return 310
        case "DIM":
            return 300
        default:
            return 600
        }
    }

    /// 对一组绘制指令做文字避让。
    ///
    /// 非文字指令原样保留，顺序不变 —— 绘制层次（谁压谁）不能改。
    /// 只有被丢弃的文字从数组里移除，所以图例、桁架、符号的相对次序不受影响。
    public static func run(_ ops: [DrawOp]) -> Result {
        // 收集所有文字，按优先级降序、同优先级按原顺序稳定排序。
        struct Item {
            let index: Int
            let priority: Int
            let layer: String
            let box: Rect
            let text: String
        }

        var items: [Item] = []
        items.reserveCapacity(ops.count / 3)
        for (i, op) in ops.enumerated() {
            guard case .text(let t) = op else { continue }
            let raw = t.string
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let box = t.family.measuring.textBox(raw, at: t.origin, capMM: t.capMM,
                                                 align: t.align,
                                                 rotationDegrees: t.rotationDegrees)
            items.append(Item(index: i, priority: priority(of: t.layer),
                              layer: t.layer ?? "", box: box, text: raw))
        }

        // 稳定排序：优先级高在前，相同优先级保持绘制顺序。
        let ordered = items.enumerated().sorted { a, b in
            if a.element.priority != b.element.priority {
                return a.element.priority > b.element.priority
            }
            return a.offset < b.offset
        }.map(\.element)

        var accepted: [Rect] = []
        accepted.reserveCapacity(ordered.count)
        var keep = Set<Int>()
        var dropped: [String: Int] = [:]

        for item in ordered {
            // 完全相同的字符串不判冲突。
            //
            // 图上有意重复的字（例如同一个色片号在多处印出）是正当的；
            // 早先的版面检查就因为这条规则误报过。
            var clash = false
            for other in accepted where clash == false {
                if item.box.overlapsStrictly(other, pad: 0.15) { clash = true }
            }
            if clash, !protectedLayers.contains(item.layer) {
                dropped[item.layer, default: 0] += 1
                continue
            }
            accepted.append(item.box)
            keep.insert(item.index)
        }

        // 重建：按**原始下标**过滤。
        //
        // 早先用一个递增的 textIndex 去索引 `items`，但 `items` 里
        // 跳过了空白文字 —— 两个序列长度不同，于是越界崩溃。
        // 下标必须从原始 ops 来，不能另开计数。
        var out: [DrawOp] = []
        out.reserveCapacity(ops.count)
        for (i, op) in ops.enumerated() {
            guard case .text = op else {
                out.append(op)
                continue
            }
            if keep.contains(i) { out.append(op) }
        }
        return Result(ops: out, dropped: dropped)
    }
}
