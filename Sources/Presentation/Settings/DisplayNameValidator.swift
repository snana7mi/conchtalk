/// 文件说明:DisplayNameValidator,客户端昵称校验(与服务端 sanitizeDisplayName 对齐:trim、非空、≤24 grapheme)。
import Foundation

enum DisplayNameValidator {
    static let maxLength = 24

    /// 校验并归一化昵称:去首尾空白;为空或超长返回 nil,否则返回 trim 后的名字。
    static func validate(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }
}
