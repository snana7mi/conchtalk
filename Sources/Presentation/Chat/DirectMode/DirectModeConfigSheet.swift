/// 文件说明：DirectModeConfigSheet，直连模式下的 agent 配置和命令选择 Sheet。

import SwiftUI
@preconcurrency import ACPModel

/// DirectModeConfigSheet：
/// 展示 ACP agent 的 models/modes 选择、config options 和 available commands。
/// 所有内容来自 agent 运行时广播/响应，零硬编码。
struct DirectModeConfigSheet: View {
    let modelsInfo: ModelsInfo?
    let modesInfo: ModesInfo?
    let configOptions: [SessionConfigOption]
    let commands: [AvailableCommand]
    let onSetModel: (String) -> Void
    let onSetMode: (String) -> Void
    let onSetConfig: (SessionConfigId, SessionConfigOptionValue) -> Void
    let onExecuteCommand: (String) -> Void
    /// 代理上报的上下文用量（仅部分 ACP 代理提供）。
    var contextUsage: DirectContextUsage? = nil

    var body: some View {
        NavigationStack {
            List {
                if let contextUsage, let fraction = contextUsage.fraction {
                    usageSection(contextUsage, fraction: fraction)
                }
                if hasConfigSection {
                    configSection
                }
                if !commands.isEmpty {
                    commandSection
                }
            }
            .navigationTitle(String(localized: "Agent Settings", bundle: LanguageSettings.currentBundle))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var hasConfigSection: Bool {
        modelsInfo != nil || modesInfo != nil || !configOptions.isEmpty
    }

    // MARK: - 配置 Section（models + modes + config options）

    @ViewBuilder
    private var configSection: some View {
        Section {
            // Model 选择
            if let models = modelsInfo, models.availableModels.count > 1 {
                Picker(
                    String(localized: "Model", bundle: LanguageSettings.currentBundle),
                    selection: Binding<String>(
                        get: { models.currentModelId },
                        set: { onSetModel($0) }
                    )
                ) {
                    ForEach(models.availableModels, id: \.modelId) { model in
                        Text(model.name).tag(model.modelId)
                    }
                }
            }

            // Mode 选择
            if let modes = modesInfo, modes.availableModes.count > 1 {
                Picker(
                    String(localized: "Mode", bundle: LanguageSettings.currentBundle),
                    selection: Binding<String>(
                        get: { modes.currentModeId },
                        set: { onSetMode($0) }
                    )
                ) {
                    ForEach(modes.availableModes, id: \.id) { mode in
                        Text(mode.name).tag(mode.id)
                    }
                }
            }

            // 通用 config options
            ForEach(configOptions, id: \.id) { option in
                configRow(for: option)
            }
        } header: {
            Text(String(localized: "Configuration", bundle: LanguageSettings.currentBundle))
        }
    }

    @ViewBuilder
    private func configRow(for option: SessionConfigOption) -> some View {
        switch option.kind {
        case .select(let select):
            selectRow(option: option, select: select)
        case .boolean(let boolean):
            booleanRow(option: option, boolean: boolean)
        }
    }

    @ViewBuilder
    private func selectRow(option: SessionConfigOption, select: SessionConfigSelect) -> some View {
        let allOptions = flattenOptions(select.options)
        Picker(option.name, selection: Binding<String>(
            get: { select.currentValue.value },
            set: { newValue in
                onSetConfig(option.id, .select(SessionConfigValueId(newValue)))
            }
        )) {
            ForEach(allOptions, id: \.value.value) { opt in
                Text(opt.name).tag(opt.value.value)
            }
        }
    }

    @ViewBuilder
    private func booleanRow(option: SessionConfigOption, boolean: SessionConfigBoolean) -> some View {
        Toggle(option.name, isOn: Binding<Bool>(
            get: { boolean.currentValue },
            set: { newValue in
                onSetConfig(option.id, .boolean(newValue))
            }
        ))
    }

    /// 将 SessionConfigSelectOptions（ungrouped/grouped）展平为单一列表。
    private func flattenOptions(_ options: SessionConfigSelectOptions) -> [SessionConfigSelectOption] {
        switch options {
        case .ungrouped(let opts):
            return opts
        case .grouped(let groups):
            return groups.flatMap { $0.options }
        }
    }

    // MARK: - 上下文用量 Section

    private func usageSection(_ usage: DirectContextUsage, fraction: Double) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                    .tint(fraction > 0.85 ? .orange : .accentColor)
                Text(verbatim: "\(Int((fraction * 100).rounded()))% · \(DirectContextUsage.compact(usage.used)) / \(DirectContextUsage.compact(usage.size))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(String(localized: "Context Used", bundle: LanguageSettings.currentBundle))
        }
    }

    // MARK: - 命令 Section

    @ViewBuilder
    private var commandSection: some View {
        Section {
            ForEach(commands, id: \.name) { command in
                Button {
                    onExecuteCommand(command.name)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(command.name)")
                            .font(.body.monospaced())
                        if !command.description.isEmpty {
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text(String(localized: "Commands", bundle: LanguageSettings.currentBundle))
        }
    }
}
