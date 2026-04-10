/// 文件说明：SkillParser，解析 SKILL.md 文件的 frontmatter 和内容，遵循 agentskills.io 规范。
import Foundation

/// SkillParser：
/// 将带 YAML frontmatter 的 Markdown 文件解析为 Skill 实体。
/// 支持字段：name（必填）、description（必填）、compatibility、metadata。
/// description 支持 YAML 多行折叠语法（>-）。
nonisolated enum SkillParser {
    /// 解析单个 SKILL.md 文件内容。
    /// - Parameters:
    ///   - text: 文件完整文本内容
    ///   - directoryURL: skill 所在目录的 URL（用于辅助文件按需加载）
    /// - Returns: 解析出的 Skill，格式错误返回 nil
    static func parse(_ text: String, directoryURL: URL? = nil) -> Skill? {
        let lines = text.components(separatedBy: "\n")

        // 查找 frontmatter 边界（两个 "---"）
        guard let firstDelimiter = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let afterFirst = lines.index(after: firstDelimiter)
        guard let secondDelimiter = lines[afterFirst...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }

        // 解析 frontmatter
        let frontmatterLines = Array(lines[afterFirst..<secondDelimiter])
        let parsed = parseFrontmatter(frontmatterLines)

        // 必需字段校验
        guard let name = parsed.fields["name"], !name.isEmpty,
              let description = parsed.fields["description"], !description.isEmpty else {
            return nil
        }

        // name 格式校验：小写字母、数字、连字符，不能以连字符开头/结尾，不能连续连字符
        guard isValidName(name) else {
            return nil
        }

        let compatibility = parsed.fields["compatibility"]

        // body 是 frontmatter 之后的内容
        let bodyStartIndex = lines.index(after: secondDelimiter)
        let content = lines[bodyStartIndex...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return Skill(
            name: name,
            description: description,
            compatibility: compatibility,
            metadata: parsed.metadata,
            content: content,
            directoryURL: directoryURL
        )
    }

    // MARK: - Name 校验

    /// 校验 skill name 是否符合规范：1-64 字符，小写字母+数字+连字符，
    /// 不能以连字符开头/结尾，不能有连续连字符。
    private static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet.lowercaseLetters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "-"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !name.hasPrefix("-"), !name.hasSuffix("-") else { return false }
        guard !name.contains("--") else { return false }
        return true
    }

    // MARK: - Frontmatter 解析

    private struct FrontmatterResult {
        var fields: [String: String] = [:]
        var metadata: [String: String] = [:]
    }

    /// 解析 frontmatter 行。支持：
    /// - 简单键值对：`key: value`
    /// - YAML 折叠多行（>-）：description 等长文本
    /// - metadata map：嵌套键值对
    private static func parseFrontmatter(_ lines: [String]) -> FrontmatterResult {
        var result = FrontmatterResult()
        var currentKey: String?
        var multilineValue: [String]?
        var inMetadata = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 处理多行折叠值（>- 语法）
            if let key = currentKey, multilineValue != nil {
                if !trimmed.isEmpty && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                    multilineValue?.append(trimmed)
                    continue
                } else {
                    // 多行结束，合并值
                    result.fields[key] = multilineValue?.joined(separator: " ") ?? ""
                    currentKey = nil
                    multilineValue = nil
                }
            }

            // metadata 嵌套键值对
            if inMetadata {
                if line.hasPrefix("  ") || line.hasPrefix("\t") {
                    if let colonRange = trimmed.range(of: ":") {
                        let key = String(trimmed[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let value = String(trimmed[colonRange.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if !key.isEmpty && !value.isEmpty {
                            result.metadata[key] = value
                        }
                    }
                    continue
                } else {
                    inMetadata = false
                }
            }

            // 顶层键值对
            if let colonRange = trimmed.range(of: ":") {
                let key = String(trimmed[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                let rawValue = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)

                if key == "metadata" {
                    inMetadata = true
                    currentKey = nil
                    continue
                }

                if rawValue == ">-" || rawValue == ">" || rawValue == "|" {
                    // YAML 多行语法
                    currentKey = key
                    multilineValue = []
                } else if rawValue.isEmpty {
                    // 可能是 metadata 或其他块级键
                    currentKey = key
                } else {
                    // 普通键值对，去掉可能的引号
                    let cleaned = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    result.fields[key] = cleaned
                    currentKey = key
                }
            }
        }

        // 处理文件末尾的多行值
        if let key = currentKey, let values = multilineValue {
            result.fields[key] = values.joined(separator: " ")
        }

        return result
    }
}
