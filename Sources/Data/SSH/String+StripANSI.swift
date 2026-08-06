/// 文件说明：String+StripANSI，清理终端 ANSI 转义序列。
import Foundation

nonisolated extension String {
    /// strippingANSIEscapes：移除常见 ANSI 转义序列，保留纯文本内容。
    func strippingANSIEscapes() -> String {
        replacingOccurrences(
            of: #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
    }
}
