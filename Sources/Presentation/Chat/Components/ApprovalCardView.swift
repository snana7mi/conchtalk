/// 文件说明：ApprovalCardView，审批弹窗：展示工具/预览/Diff，并提供四态结果与规则编辑。
import SwiftUI

/// ApprovalCardView：
/// 安全门触发确认时弹出的卡片，展示工具说明、目标命令/路径与写操作预览（含行级 Diff），
/// 底部提供「拒绝 / 仅此一次 / 本会话信任 / 始终允许」四态，并允许编辑「始终允许」规则的作用范围。
struct ApprovalCardView: View {
    let request: ConfirmationRequest
    let deadline: Date?
    /// 回传用户选择的四态结果。
    let onResolve: (CommandApproval) -> Void

    @State private var editedRule: ApprovalRule?      // 用户在卡片里可改宽的规则
    @State private var showRuleEditor = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    previewSection
                }
                .padding()
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .navigationTitle(String(localized: "Confirm Action", bundle: LanguageSettings.currentBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .onAppear { editedRule = request.suggestedRule }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.toolCall.explanation).font(.headline)
            Text(targetText).font(Theme.commandFont).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let deadline { Text(deadline, style: .relative).font(.caption2).foregroundStyle(.tertiary) }
        }
    }

    private var targetText: String {
        let args = try? request.toolCall.decodedArguments()
        if request.toolCall.toolName == "execute_ssh_command" { return (args?["command"] as? String) ?? "" }
        return (args?["path"] as? String) ?? request.toolCall.toolName
    }

    @ViewBuilder private var previewSection: some View {
        switch request.preview {
        case .fileDiff(let lines, let summary):
            VStack(alignment: .leading, spacing: 2) {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                ForEach(Array(lines.prefix(400).enumerated()), id: \.offset) { _, line in diffRow(line) }
                if lines.count > 400 { Text("… (\(lines.count - 400) more)").font(.caption2).foregroundStyle(.tertiary) }
            }
        case .newFile(let lc, let bc):
            Label(String(localized: "Creates new file (\(lc) lines, \(bc) bytes)", bundle: LanguageSettings.currentBundle), systemImage: "doc.badge.plus")
        case .append(let tail, let bytes):
            VStack(alignment: .leading) {
                Label(String(localized: "Appends \(bytes) bytes", bundle: LanguageSettings.currentBundle), systemImage: "text.append")
                Text(tail).font(Theme.commandFont).foregroundStyle(.green)
            }
        case .binaryWrite(let bytes):
            Label(String(localized: "Writes binary (\(bytes) bytes) — no diff", bundle: LanguageSettings.currentBundle), systemImage: "doc.zipper")
        case .command(let text):
            Text(text).font(Theme.commandFont).textSelection(.enabled)
        case .unavailable(let reason):
            Label(reason, systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    private func diffRow(_ line: DiffLine) -> some View {
        switch line {
        case .context(let s): return Text(" \(s)").font(Theme.commandFont).foregroundStyle(.primary)
        case .added(let s): return Text("+\(s)").font(Theme.commandFont).foregroundStyle(.green)
        case .removed(let s): return Text("-\(s)").font(Theme.commandFont).foregroundStyle(.red)
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack {
                Button(role: .cancel) { onResolve(.denied) } label: {
                    Text(String(localized: "Deny", bundle: LanguageSettings.currentBundle)).frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button { onResolve(.approvedOnce) } label: {
                    Text(String(localized: "Allow Once", bundle: LanguageSettings.currentBundle)).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }
            if request.canRemember, let rule = editedRule {
                HStack {
                    Button { onResolve(.approvedForSession) } label: {
                        Text(String(localized: "Trust This Session", bundle: LanguageSettings.currentBundle)).frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    Button { onResolve(.approvedAlways(rule)) } label: {
                        Text(String(localized: "Always Allow", bundle: LanguageSettings.currentBundle)).frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                }
                Button { showRuleEditor = true } label: {
                    Label(rule.displayLabel, systemImage: "slider.horizontal.3").font(.caption)
                }
                .sheet(isPresented: $showRuleEditor) {
                    ApprovalRuleEditor(rule: rule) { editedRule = $0 }
                }
            }
        }
        .padding()
        .background(.bar)
    }
}

/// ApprovalRuleEditor：
/// 在「始终允许」前编辑规则作用范围的 Sheet。
/// - 命令规则（commandPrefix）：把 argv token 渲染成可从**尾部**逐个删除的 chip；删一个尾 token →
///   匹配前缀变短、规则变宽（命中更多命令）。至少保留 1 个 token。
/// - 路径规则（pathPrefix）：提供「仅此文件 / 此目录（递归）」开关；递归时前缀取原路径的**父目录**，
///   非递归时回到原始精确路径。
/// 完成回调传出重建了 matcher 与 displayLabel 的新 ApprovalRule（不做任何网络/持久化副作用）。
struct ApprovalRuleEditor: View {
    @Environment(\.dismiss) private var dismiss

    let rule: ApprovalRule
    /// 完成回调：传出编辑后的规则。
    let onDone: (ApprovalRule) -> Void

    // 命令规则：当前保留的尾部可删 token 列表（从完整 argv 起，逐个从尾部删减）。
    @State private var tokens: [String]
    // 路径规则：递归（目录）开关。
    @State private var recursive: Bool
    // 路径规则：原始精确文件路径（用于在非递归时回退）。
    private let originalFilePath: String

    init(rule: ApprovalRule, onDone: @escaping (ApprovalRule) -> Void) {
        self.rule = rule
        self.onDone = onDone
        switch rule.matcher {
        case .commandPrefix(let toks):
            _tokens = State(initialValue: toks)
            _recursive = State(initialValue: false)
            originalFilePath = ""
        case .pathPrefix(let prefix, let rec):
            _tokens = State(initialValue: [])
            _recursive = State(initialValue: rec)
            // 建议规则恒以「精确文件 + 非递归」到达（见 ApprovalMatching.suggestedMatcher），
            // 此处保留入参前缀作为非递归时的精确路径；递归时由父目录派生。
            originalFilePath = prefix
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch rule.matcher {
                case .commandPrefix:
                    commandSection
                case .pathPrefix:
                    pathSection
                }
            }
            .navigationTitle(String(localized: "Edit Rule Scope", bundle: LanguageSettings.currentBundle))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle)) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done", bundle: LanguageSettings.currentBundle)) {
                        onDone(editedRule)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    // MARK: - Command rule editing

    @ViewBuilder private var commandSection: some View {
        Section {
            FlowChips(tokens: tokens) { index in
                // 仅允许删除最后一个 token（从尾部收窄前缀以扩大匹配范围）。
                guard index == tokens.count - 1, tokens.count > 1 else { return }
                tokens.removeLast()
            }
        } header: {
            Text(String(localized: "Command Prefix", bundle: LanguageSettings.currentBundle))
        } footer: {
            Text(String(localized: "Remove trailing tokens to allow more commands. At least one token must remain.", bundle: LanguageSettings.currentBundle))
        }

        Section {
            Label(currentLabel, systemImage: "checkmark.shield")
                .font(Theme.commandFont)
                .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "Will Match", bundle: LanguageSettings.currentBundle))
        }
    }

    // MARK: - Path rule editing

    @ViewBuilder private var pathSection: some View {
        Section {
            Toggle(isOn: $recursive) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "This directory (recursive)", bundle: LanguageSettings.currentBundle))
                    Text(String(localized: "Allow writes anywhere under the parent directory", bundle: LanguageSettings.currentBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(String(localized: "Scope", bundle: LanguageSettings.currentBundle))
        } footer: {
            Text(recursive
                ? String(localized: "Off: allow only this exact file.", bundle: LanguageSettings.currentBundle)
                : String(localized: "On: allow any file under this file's directory.", bundle: LanguageSettings.currentBundle))
        }

        Section {
            Label(currentLabel, systemImage: "checkmark.shield")
                .font(Theme.commandFont)
                .foregroundStyle(.secondary)
        } header: {
            Text(String(localized: "Will Match", bundle: LanguageSettings.currentBundle))
        }
    }

    // MARK: - Derived state

    /// 当前编辑态对应的 matcher。
    private var currentMatcher: ApprovalMatcher {
        switch rule.matcher {
        case .commandPrefix:
            return .commandPrefix(tokens: tokens)
        case .pathPrefix:
            let prefix = recursive ? Self.parentDirectory(of: originalFilePath) : originalFilePath
            return .pathPrefix(prefix: prefix, recursive: recursive)
        }
    }

    /// 当前 matcher 的人类可读标签（复用 Domain 层标签构建，保持一致）。
    private var currentLabel: String {
        ApprovalMatching.suggestedLabel(matcher: currentMatcher, toolName: rule.toolName)
    }

    /// 重建 matcher 与 displayLabel 后的规则（保留 id / serverID / createdAt，刷新 modifiedAt）。
    private var editedRule: ApprovalRule {
        ApprovalRule(
            id: rule.id,
            serverID: rule.serverID,
            toolName: rule.toolName,
            matcher: currentMatcher,
            displayLabel: currentLabel,
            createdAt: rule.createdAt,
            modifiedAt: Date()
        )
    }

    /// 命令规则至少保留 1 个 token；路径规则恒可保存。
    private var canSave: Bool {
        switch rule.matcher {
        case .commandPrefix: return !tokens.isEmpty
        case .pathPrefix: return true
        }
    }

    // MARK: - Path helpers

    /// 取绝对路径的父目录（无父目录时回退到根 `/`）。
    private static func parentDirectory(of path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        if slash == trimmed.startIndex { return "/" }
        return String(trimmed[..<slash])
    }
}

/// FlowChips：把 token 列表渲染成自动换行的 chip 流，点击末尾 chip 上的删除按钮触发回调。
/// 仅末尾 chip 显示删除按钮，前置 chip 为只读，以贯彻「从尾部收窄」语义。
private struct FlowChips: View {
    let tokens: [String]
    let onRemove: (Int) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                chip(token, isLast: index == tokens.count - 1, canRemove: index == tokens.count - 1 && tokens.count > 1) {
                    onRemove(index)
                }
            }
        }
    }

    private func chip(_ token: String, isLast: Bool, canRemove: Bool, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(token).font(Theme.commandFont)
            if canRemove {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Remove last token", bundle: LanguageSettings.currentBundle))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isLast ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08))
        .clipShape(Capsule())
    }
}

/// FlowLayout：简单的自动换行布局，按可用宽度从左到右排布子视图，超出则换行。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, maxWidth: maxWidth)
        if rows.isEmpty { return .zero }
        let height = rows.last.map { $0.y + $0.rowHeight } ?? 0
        let width = rows.map { $0.maxX }.max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = layout(subviews: subviews, maxWidth: bounds.width)
        for row in rows {
            for item in row.items {
                let point = CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y)
                subviews[item.index].place(at: point, anchor: .topLeading, proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                current.maxX = x - spacing
                rows.append(current)
                let nextY = current.y + current.rowHeight + spacing
                current = Row()
                current.y = nextY
                x = 0
            }
            current.items.append((index: index, x: x, size: size))
            current.rowHeight = max(current.rowHeight, size.height)
            x += size.width + spacing
        }
        if !current.items.isEmpty {
            current.maxX = x - spacing
            rows.append(current)
        }
        return rows
    }
}
