/// 文件说明：ToolArguments，从工具参数字典里取出布尔、整数与秒数。
import Foundation

/// ToolArguments：
/// 模型传入的 JSON 数字可能是 Int、Double 或 NSNumber。
/// 这里统一解码，并忽略被桥接成数字的布尔值。
enum ToolArguments {
    /// 读取整数。布尔值与非整数浮点返回 nil。
    static func int(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let value = value as? Int { return value }
        if let value = value as? Double {
            guard value.rounded() == value, value <= Double(Int.max), value >= Double(Int.min) else { return nil }
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    /// 读取布尔值。缺失或类型不符时返回默认值。
    static func bool(_ value: Any?, default defaultValue: Bool = false) -> Bool {
        if let value = value as? Bool { return value }
        if value is Int || value is Double { return defaultValue }
        if let value = value as? NSNumber { return value.boolValue }
        return defaultValue
    }

    /// 读取秒数。整数与小数都接受。
    static func timeInterval(_ value: Any?) -> TimeInterval? {
        if value is Bool { return nil }
        if let value = value as? Int { return TimeInterval(value) }
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }
}
