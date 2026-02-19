/// 文件说明：ShellEscape，提供命令参数转义能力以避免 Shell 注入风险。
import Foundation

/// 对字符串做单引号转义，确保其可安全拼接到 Shell 命令中。
/// - Parameter string: 原始参数字符串。
/// - Returns: 已转义后的安全字符串字面量。
func shellEscape(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
