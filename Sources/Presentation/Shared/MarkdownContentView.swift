/// 文件说明：MarkdownContentView，轻量 Markdown 渲染组件（零第三方依赖）。
/// 支持标题、列表（有序/无序/任务）、代码块、表格、引用块、分隔线、
/// 内联格式（粗体、斜体、删除线、行内代码、链接）。
/// 解析逻辑在 MarkdownParser 中，本文件只负责渲染。
import SwiftUI

// MARK: - TableAlignment SwiftUI 映射

/// left→leading, center→center, right→trailing，统一映射。
extension TableAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    var frameAlignment: Alignment {
        switch self {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}

/// 将 Markdown 文本拆分为各种块级元素，分别渲染。
struct MarkdownContentView: View {
    let content: String

    /// 缓存解析结果，避免每次 body 求值都重新解析
    private let blocks: [MarkdownBlock]

    init(content: String) {
        self.content = content
        self.blocks = MarkdownParser.parse(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)
        case .text(let text):
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(MarkdownParser.inlineAttributedString(from: text))
                    .font(Theme.messageFont)
                    .textSelection(.enabled)
            }
        case .unorderedListItem(let text):
            unorderedListItemView(text)
        case .orderedListItem(let number, let text):
            orderedListItemView(number: number, text: text)
        case .taskListItem(let checked, let text):
            taskListItemView(checked: checked, text: text)
        case .codeBlock(let code):
            codeBlockView(code)
        case .table(let headers, let alignments, let rows):
            tableView(headers: headers, alignments: alignments, rows: rows)
        case .blockquote(let text):
            blockquoteView(text)
        case .horizontalRule:
            horizontalRuleView()
        }
    }

    // MARK: - Block Views

    /// 标题渲染：根据级别使用不同字号和粗细。
    private func headingView(level: Int, text: String) -> some View {
        Text(MarkdownParser.inlineAttributedString(from: text))
            .font(Self.headingFont(level: level))
            .fontWeight(.semibold)
            .textSelection(.enabled)
            .padding(.top, level <= 2 ? 4 : 2)
    }

    private static func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }

    /// 无序列表项：圆点 + 内联 markdown 文本。
    private func unorderedListItemView(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\u{2022}")
                .font(Theme.messageFont)
                .foregroundStyle(.secondary)
            Text(MarkdownParser.inlineAttributedString(from: text))
                .font(Theme.messageFont)
                .textSelection(.enabled)
        }
    }

    /// 有序列表项：编号 + 内联 markdown 文本。
    private func orderedListItemView(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(number).")
                .font(Theme.messageFont)
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            Text(MarkdownParser.inlineAttributedString(from: text))
                .font(Theme.messageFont)
                .textSelection(.enabled)
        }
    }

    /// 任务列表项：复选框 + 内联 markdown 文本。
    private func taskListItemView(checked: Bool, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.system(size: 14))
                .foregroundStyle(checked ? Color.accentColor : .secondary)
            Text(MarkdownParser.inlineAttributedString(from: text))
                .font(Theme.messageFont)
                .textSelection(.enabled)
        }
    }

    /// 代码块渲染：等宽字体 + 浅色圆角背景 + 横向滚动。
    private func codeBlockView(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// 表格渲染：Gemini 风格 — 深色表头、交替行色、圆角裁切、无边框线。
    private func tableView(headers: [String], alignments: [TableAlignment], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            let colCount = headers.count

            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                // 表头行
                GridRow {
                    ForEach(0..<colCount, id: \.self) { col in
                        let align = col < alignments.count ? alignments[col] : .left
                        Text(MarkdownParser.inlineAttributedString(from: headers[col]))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.primary)
                            .textSelection(.enabled)
                            .multilineTextAlignment(align.textAlignment)
                            .frame(maxWidth: .infinity, alignment: align.frameAlignment)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .background(Color.primary.opacity(0.12))

                // 数据行
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    GridRow {
                        ForEach(0..<colCount, id: \.self) { col in
                            let align = col < alignments.count ? alignments[col] : .left
                            let cellText = col < row.count ? row[col] : ""
                            Text(MarkdownParser.inlineAttributedString(from: cellText))
                                .font(.subheadline)
                                .textSelection(.enabled)
                                .multilineTextAlignment(align.textAlignment)
                                .frame(maxWidth: .infinity, alignment: align.frameAlignment)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        }
                    }
                    .background(rowIdx % 2 == 0 ? Color.primary.opacity(0.04) : Color.clear)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// 引用块渲染：左侧竖线 + 灰色背景。
    private func blockquoteView(_ text: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3)

            Text(MarkdownParser.inlineAttributedString(from: text))
                .font(Theme.messageFont)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .padding(.vertical, 2)
    }

    /// 分隔线渲染。
    private func horizontalRuleView() -> some View {
        Divider()
            .padding(.vertical, 4)
    }
}
