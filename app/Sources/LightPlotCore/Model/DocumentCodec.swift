import Foundation
import Yams

/// 文档的读写。
///
/// **为什么是 YAML 而不是 JSON**：
/// 旧管线的全部数据都是 YAML（`rig.yaml` / `scenes.yaml` / `cues.yaml`）。
/// 保留同一格式意味着两件事同时成立：
///   1. 应用打开旧项目不需要迁移步骤
///   2. 应用存盘后，Python 管线仍然能直接渲染同一份文件 —— 这是交付兜底
///
/// 代价是编码顺序与注释：YAML 编码会丢掉注释。所以：
///   · 应用首次打开旧文件时**不覆盖原文件**，另存为 `.lpx`
///   · 只有在用户明确"导出给 CLI"时才写回 YAML
public enum DocumentCodec {

    public enum CodecError: Error, LocalizedError {
        case empty
        case decode(String)
        case encode(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "The file is empty."
            case .decode(let m): return "Cannot read the document: \(m)"
            case .encode(let m): return "Cannot write the document: \(m)"
            }
        }
    }

    // MARK: YAML

    public static func decodeYAML(_ data: Data) throws -> LXDocument {
        guard !data.isEmpty else { throw CodecError.empty }
        let decoder = YAMLDecoder()
        do {
            return try decoder.decode(LXDocument.self, from: data)
        } catch {
            throw CodecError.decode(String(describing: error))
        }
    }

    public static func decodeYAML(_ string: String) throws -> LXDocument {
        try decodeYAML(Data(string.utf8))
    }

    public static func encodeYAML(_ doc: LXDocument) throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        do {
            return try encoder.encode(doc)
        } catch {
            throw CodecError.encode(String(describing: error))
        }
    }

    // MARK: JSON（应用自己的原生格式）

    public static func decodeJSON(_ data: Data) throws -> LXDocument {
        do {
            return try JSONDecoder().decode(LXDocument.self, from: data)
        } catch {
            throw CodecError.decode(String(describing: error))
        }
    }

    /// 稳定 JSON：键有序、缩进两格、末尾换行。
    ///
    /// 稳定性不是为了好看 —— 是为了让"同一份文档 → 同一个字节序列"成立。
    /// 有了它，回归测试可以直接 `cmp`，而不是逐字段比较。
    public static func encodeJSON(_ doc: LXDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(doc)
            data.append(0x0A)
            return data
        } catch {
            throw CodecError.encode(String(describing: error))
        }
    }
}
