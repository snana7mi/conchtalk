/// 文件说明：SubagentParser，解析 AGENT.md 的 frontmatter 与 body 为 SubagentDefinition。
import Foundation

/// SubagentParser：
/// 将带 YAML frontmatter 的 AGENT.md 解析为 SubagentDefinition。
/// 支持字段：name（必填）、description（必填）、tools（逗号分隔，可选）、metadata（嵌套，可选）。
nonisolated enum SubagentParser {
    static func parse(_ text: String) -> SubagentDefinition? {
        let lines = text.components(separatedBy: "\n")

        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
        let afterFirst = lines.index(after: first)
        guard afterFirst < lines.count,
              let second = lines[afterFirst...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }

        let fmLines = Array(lines[afterFirst..<second])
        let parsed = parseFrontmatter(fmLines)

        guard let name = parsed.fields["name"], !name.isEmpty,
              let description = parsed.fields["description"], !description.isEmpty,
              isValidName(name) else {
            return nil
        }

        let tools = (parsed.fields["tools"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let bodyStart = lines.index(after: second)
        let systemPrompt = bodyStart < lines.count
            ? lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            : ""

        return SubagentDefinition(
            name: name,
            description: description,
            allowedTools: tools,
            metadata: parsed.metadata,
            systemPrompt: systemPrompt
        )
    }

    private static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-"))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        guard !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else { return false }
        return true
    }

    private struct FrontmatterResult {
        var fields: [String: String] = [:]
        var metadata: [String: String] = [:]
    }

    private static func parseFrontmatter(_ lines: [String]) -> FrontmatterResult {
        var result = FrontmatterResult()
        var currentKey: String?
        var multilineValue: [String]?
        var inMetadata = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 多行折叠值（>- / > / | 语法）：累积后续缩进行
            if let key = currentKey, multilineValue != nil {
                if !trimmed.isEmpty && (line.hasPrefix("  ") || line.hasPrefix("\t")) {
                    multilineValue?.append(trimmed)
                    continue
                } else {
                    // 多行结束，按空格合并
                    result.fields[key] = multilineValue?.joined(separator: " ") ?? ""
                    currentKey = nil
                    multilineValue = nil
                }
            }

            // metadata 嵌套键值对
            if inMetadata {
                if line.hasPrefix("  ") || line.hasPrefix("\t") {
                    if let colon = trimmed.range(of: ":") {
                        let key = String(trimmed[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                        let value = String(trimmed[colon.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        if !key.isEmpty && !value.isEmpty { result.metadata[key] = value }
                    }
                    continue
                } else {
                    inMetadata = false
                }
            }

            // 顶层键值对
            if let colon = trimmed.range(of: ":") {
                let key = String(trimmed[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
                let raw = String(trimmed[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
                if key == "metadata" {
                    inMetadata = true
                    currentKey = nil
                    continue
                }
                if raw == ">-" || raw == ">" || raw == "|" {
                    // YAML 多行折叠语法，开始累积后续缩进行
                    currentKey = key
                    multilineValue = []
                } else if raw.isEmpty {
                    // 块级键（值可能在后续行或为空）
                    currentKey = key
                } else {
                    result.fields[key] = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
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
