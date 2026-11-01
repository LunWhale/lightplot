import Foundation

/// 文件名清洗。
///
/// 剧名可能含斜杠（"A/B"）、冒号（"ACT 1: NIGHT"）——
/// 直接当文件名会创建出意外目录或被系统拒绝。
public enum Stem {
    public static func sanitize(_ s: String) -> String {
        var out = s
        for (bad, good) in [("/", "-"), (":", "-"), ("\\", "-"), ("|", "-")] {
            out = out.replacingOccurrences(of: bad, with: good)
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        // 压掉连续空白，避免 "A  -  B"
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.isEmpty ? "Sheet" : out
    }
}
