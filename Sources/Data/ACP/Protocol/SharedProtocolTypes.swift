/// 文件说明：AnyCodableJSON，轻量级 JSON 值包装，用于解码动态 JSON 结构。

import Foundation

/// AnyCodableJSON：轻量级 JSON 值包装，用于解码动态 JSON 结构。
/// 同时支持 Encodable 以便二次解码到具体类型。
nonisolated enum AnyCodableJSON: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([AnyCodableJSON])
    case object([String: AnyCodableJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // 注意：Bool 必须在 Double 之前解码，否则 true/false 会被解析为 1.0/0.0
        if let s = try? container.decode(String.self) { self = .string(s) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let n = try? container.decode(Double.self) { self = .number(n) }
        else if let arr = try? container.decode([AnyCodableJSON].self) { self = .array(arr) }
        else if let obj = try? container.decode([String: AnyCodableJSON].self) { self = .object(obj) }
        else if container.decodeNil() { self = .null }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        case .array(let arr): try container.encode(arr)
        case .object(let obj): try container.encode(obj)
        }
    }

    /// 便捷属性：提取字符串值，非 string 类型返回 nil。
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
