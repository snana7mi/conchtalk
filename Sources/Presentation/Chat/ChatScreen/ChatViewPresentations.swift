/// 文件说明：ChatViewPresentations，集中管理聊天页弹窗、Sheet 与文件导入器。
import SwiftUI
import UniformTypeIdentifiers

extension ChatView {
    func applyPresentations<Content: View>(to content: Content) -> some View {
        let withAlerts = applyAlertPresentations(to: content)
        let withSheets = applySheetPresentations(to: withAlerts)
        return applyFileImportPresentations(to: withSheets)
    }

    private func applyAlertPresentations<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showApprovalCard) {
                if let request = viewModel.pendingConfirmationRequest {
                    ApprovalCardView(request: request, deadline: viewModel.confirmationDeadline) { outcome in
                        viewModel.resolveCommand(outcome)
                    }
                    // 必须显式选择，避免下滑误关 = 既不批也不拒；到点 auto-deny 由 coordinator 侧 deadline 驱动。
                    .interactiveDismissDisabled(true)
                }
            }
            .alert(
                String(localized: "Agent Permission Request", bundle: LanguageSettings.currentBundle),
                isPresented: Binding(
                    get: { viewModel.directPermissionRequest != nil },
                    set: { if !$0 {
                        viewModel.directSessionCoordinator.resolvePermission(approved: false)
                        viewModel.directPermissionRequest = nil
                    } }
                )
            ) {
                Button(String(localized: "Allow", bundle: LanguageSettings.currentBundle)) {
                    viewModel.directSessionCoordinator.resolvePermission(approved: true)
                    viewModel.directPermissionRequest = nil
                }
                Button(String(localized: "Deny", bundle: LanguageSettings.currentBundle), role: .cancel) {
                    viewModel.directSessionCoordinator.resolvePermission(approved: false)
                    viewModel.directPermissionRequest = nil
                }
            } message: {
                if let request = viewModel.directPermissionRequest {
                    // 请求描述来自代理原文，不做本地化
                    Text(request.description)
                }
            }
            .alert(
                viewModel.agentPicker.title,
                isPresented: $viewModel.agentPicker.showAgentPicker
            ) {
                ForEach(viewModel.agentPicker.options, id: \.label) { option in
                    Button(option.label) {
                        viewModel.agentPicker.handleAgentPickerOption(option)
                    }
                }
                Button(String(localized: "Cancel", bundle: LanguageSettings.currentBundle), role: .cancel) {
                    viewModel.agentPicker.cancelAgentPicker()
                }
            } message: {
                if let message = viewModel.agentPicker.message {
                    Text(message)
                }
            }
            .sheet(isPresented: $viewModel.showPaywall) {
                PaywallView(viewModel: PaywallViewModel(subscriptionService: subscriptionService))
            }
    }

    private func applySheetPresentations<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showDirectModeConfigSheet) {
                DirectModeConfigSheet(
                    modelsInfo: viewModel.directSessionCoordinator.state.metadata.models,
                    modesInfo: viewModel.directSessionCoordinator.state.metadata.modes,
                    configOptions: viewModel.directSessionCoordinator.state.metadata.configOptions,
                    commands: viewModel.directSessionCoordinator.state.metadata.commands,
                    onSetModel: { modelId in
                        viewModel.directSessionCoordinator.setModel(modelId: modelId)
                    },
                    onSetMode: { modeId in
                        viewModel.directSessionCoordinator.setMode(modeId: modeId)
                    },
                    onSetConfig: { configId, value in
                        viewModel.directSessionCoordinator.setConfigOption(configId: configId, value: value)
                    },
                    onExecuteCommand: { name in
                        viewModel.showDirectModeConfigSheet = false
                        viewModel.inputText = "/\(name)"
                        viewModel.sendMessage()
                    }
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $viewModel.agentPicker.showDirectoryBrowser) {
                DirectoryBrowserSheet(coordinator: viewModel.agentPicker)
            }
            .alert(
                String(localized: "File too large", bundle: LanguageSettings.currentBundle),
                isPresented: Binding(
                    get: { oversizedFileAlert != nil },
                    set: { if !$0 { oversizedFileAlert = nil } }
                )
            ) {
                Button(String(localized: "OK", bundle: LanguageSettings.currentBundle), role: .cancel) {}
            } message: {
                if let files = oversizedFileAlert {
                    let fileNames = files.joined(separator: ", ")
                    Text(
                        "The following files exceed the 50MB limit: \(fileNames)",
                        bundle: LanguageSettings.currentBundle
                    )
                }
            }    }

    private func applyFileImportPresentations<Content: View>(to content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isFilePickerPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    let oversized = viewModel.addAttachments(from: urls)
                    if !oversized.isEmpty {
                        oversizedFileAlert = oversized
                    }
                case .failure:
                    break
                }
            }
    }
}
