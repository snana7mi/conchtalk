/// 文件说明：MarkdownParser，轻量 Markdown 文本到 Block 模型的解析器。
import Foundation

/// MarkdownBlock：Markdown 块级元素模型。
enum MarkdownBlock {
    case heading(level: Int, text: String)
    case text(String)
    case unorderedListItem(String)
    case orderedListItem(number: Int, text: String)
    case taskListItem(checked: Bool, text: String)
    case codeBlock(String)
    case table(headers: [String], alignments: [TableAlignment], rows: [[String]])
    case blockquote(String)
    case horizontalRule
}

/// TableAlignment：Markdown 表格列的对齐方式。
/// SwiftUI 相关的映射属性在 MarkdownContentView 中通过 extension 提供。
enum TableAlignment {
    case left, center, right
}

/// MarkdownParser：将 Markdown 文本解析为 MarkdownBlock 数组。
/// 两阶段解析：先按 ``` 拆分代码块，再对文本段做行级解析。
enum MarkdownParser {

    static func parse(_ content: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []

        for segment in splitCodeBlocks(content) {
            switch segment {
            case .codeBlock(let code):
                result.append(.codeBlock(code))
            case .text(let text):
                result.append(contentsOf: parseTextSegment(text))
            default:
                break
            }
        }

        return result
    }

    // MARK: - 代码块拆分

    /// 按 ``` 分隔符拆分代码块。
    private static func splitCodeBlocks(_ content: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        let delimiter = "```"
        var remaining = content[content.startIndex...]
        var insideCode = false

        while let range = remaining.range(of: delimiter) {
            let before = String(remaining[remaining.startIndex..<range.lowerBound])

            if insideCode {
                let code = before.drop(while: { !$0.isNewline })
                let trimmed = code.hasPrefix("\n") ? String(code.dropFirst()) : String(code)
                result.append(.codeBlock(trimmed))
            } else if !before.isEmpty {
                result.append(.text(before))
            }

            insideCode.toggle()
            remaining = remaining[range.upperBound...]
        }

        let tail = String(remaining)
        if insideCode {
            let code = tail.drop(while: { !$0.isNewline })
            let trimmed = code.hasPrefix("\n") ? String(code.dropFirst()) : String(code)
            result.append(.codeBlock(trimmed))
        } else if !tail.isEmpty {
            result.append(.text(tail))
        }

        return result
    }

    // MARK: - 文本段行级解析

    /// 对非代码文本段按行解析：识别标题、列表、表格、引用、分隔线，
    /// 连续的普通行合并为一个文本块。
    private static func parseTextSegment(_ text: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var pendingText = ""
        var tableLines: [String] = []

        func flushText() {
            if !pendingText.isEmpty {
                result.append(.text(pendingText))
                pendingText = ""
            }
        }

        func flushTable() {
            if let table = parseTable(tableLines) {
                result.append(table)
            } else {
                // 不是有效表格，当普通文本处理
                for line in tableLines {
                    if !pendingText.isEmpty { pendingText += "\n" }
                    pendingText += line
                }
            }
            tableLines = []
        }

        let lines = text.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 检查是否为表格行（以 | 开头或包含 | 分隔的内容）
            let isTableLine = trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 1

            if isTableLine {
                flushText()
                tableLines.append(trimmed)
                continue
            }

            // 非表格行时，先 flush 可能积累的表格行
            if !tableLines.isEmpty {
                flushTable()
            }

            // 分隔线：---、***、___（至少3个，允许空格）
            if isHorizontalRule(trimmed) {
                flushText()
                result.append(.horizontalRule)
            }
            // 标题：# / ## / ### ...
            else if let headingMatch = trimmed.prefixMatch(of: /^(#{1,6})\s+(.+)/) {
                flushText()
                let level = headingMatch.output.1.count
                let headingText = String(headingMatch.output.2)
                result.append(.heading(level: level, text: headingText))
            }
            // 任务列表：- [ ] 或 - [x]
            else if let taskMatch = trimmed.prefixMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.+)/) {
                flushText()
                let checked = taskMatch.output.1 != " "
                result.append(.taskListItem(checked: checked, text: String(taskMatch.output.2)))
            }
            // 无序列表：- / * / + 开头
            else if let listMatch = trimmed.prefixMatch(of: /^[-*+]\s+(.+)/) {
                flushText()
                result.append(.unorderedListItem(String(listMatch.output.1)))
            }
            // 有序列表：1. 2. 等
            else if let orderedMatch = trimmed.prefixMatch(of: /^(\d+)\.\s+(.+)/) {
                flushText()
                let number = Int(orderedMatch.output.1) ?? 1
                result.append(.orderedListItem(number: number, text: String(orderedMatch.output.2)))
            }
            // 引用块：> 开头
            else if let quoteMatch = trimmed.prefixMatch(of: /^>\s?(.*)/) {
                flushText()
                result.append(.blockquote(String(quoteMatch.output.1)))
            }
            // 普通行：累积
            else {
                if !pendingText.isEmpty { pendingText += "\n" }
                pendingText += line
            }
        }

        // 循环结束后 flush 剩余
        if !tableLines.isEmpty { flushTable() }
        flushText()

        // 合并连续的引用块
        result = mergeConsecutiveBlockquotes(result)

        return result
    }

    // MARK: - 辅助方法

    /// 合并连续的 blockquote 为一个。
    private static func mergeConsecutiveBlockquotes(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var pendingQuote = ""

        func flushQuote() {
            if !pendingQuote.isEmpty {
                result.append(.blockquote(pendingQuote))
                pendingQuote = ""
            }
        }

        for block in blocks {
            if case .blockquote(let text) = block {
                if !pendingQuote.isEmpty { pendingQuote += "\n" }
                pendingQuote += text
            } else {
                flushQuote()
                result.append(block)
            }
        }

        flushQuote()
        return result
    }

    /// 判断是否为分隔线（---、***、___，至少3个重复字符）。
    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let stripped = trimmed.replacingOccurrences(of: " ", with: "")
        guard let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    /// 判断是否为表格分隔单元格（:?---+:? 格式）。
    private static func isTableSeparatorCell(_ cell: String) -> Bool {
        let t = cell.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        var chars = t[t.startIndex...]
        if chars.first == ":" { chars = chars.dropFirst() }
        if chars.last == ":" { chars = chars.dropLast() }
        return !chars.isEmpty && chars.allSatisfy { $0 == "-" }
    }

    // MARK: - 表格解析

    /// 解析表格行：至少需要表头行 + 分隔行（+ 可选数据行）。
    private static func parseTable(_ lines: [String]) -> MarkdownBlock? {
        guard lines.count >= 2 else { return nil }

        let parsedRows = lines.map { parseTableRow($0) }

        // 第二行必须是分隔行
        let separatorRow = parsedRows[1]
        let isSeparator = separatorRow.allSatisfy { cell in
            isTableSeparatorCell(cell)
        }
        guard isSeparator else { return nil }

        let headers = parsedRows[0]
        let alignments = parseAlignments(separatorRow)
        let dataRows = Array(parsedRows.dropFirst(2))

        // 确保列数一致（以 header 列数为准，不足补空，多余截断）
        let colCount = headers.count
        let normalizedRows = dataRows.map { row -> [String] in
            if row.count >= colCount {
                return Array(row.prefix(colCount))
            } else {
                return row + Array(repeating: "", count: colCount - row.count)
            }
        }

        return .table(headers: headers, alignments: alignments, rows: normalizedRows)
    }

    /// 拆分表格行中的单元格。
    private static func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// 从分隔行解析对齐方式。
    private static func parseAlignments(_ separatorCells: [String]) -> [TableAlignment] {
        separatorCells.map { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            let left = t.hasPrefix(":")
            let right = t.hasSuffix(":")
            if left && right { return .center }
            if right { return .right }
            return .left
        }
    }

    // MARK: - 内联 Markdown

    /// 使用 SwiftUI 内置的 AttributedString(markdown:) 渲染内联格式。
    static func inlineAttributedString(from text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
