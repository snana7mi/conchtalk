/// 文件说明：ChatInputBar，负责聊天模块的界面展示与交互流程。
import SwiftUI

/// ChatInputBar：UI 层组件，承载展示与交互职责。
struct ChatInputBar: View {
    @Binding var text: String
    let isConnected: Bool
    var isContextCompressing: Bool = false
    let attachments: [FileAttachment]
    let onSend: () -> Void
    let onPickFile: () -> Void
    let onRemoveAttachment: (FileAttachment) -> Void
    var presentationState: DirectModePresentationState = DirectModePresentationState(
        modeState: .inactive,
        agent: nil,
        themeTokens: .init(paletteKey: "normal", accentKey: "conchtalk", markerStyle: "normal"),
        statusBar: .init(title: .app, status: .inactive, marker: .normal),
        inputBar: .init(mode: .normal, placeholder: .none, isEnabled: false, showsCancel: false),
        isExecuting: false,
        transition: .none
    )
    var isConnectingToAgent: Bool = false
    var hasConfigData: Bool = false
    var onConfigTap: (() -> Void)?
    var onCancelConnect: (() -> Void)?
    var isSpeechAvailable: Bool = false
    var speechState: SpeechRecognitionState = .idle
    var hideAttachments: Bool = false
    var onMicTap: (() -> Void)?

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            if presentationState.isActive, let agentName = presentationState.agentName {
                HStack(spacing: 8) {
                    Label(agentName, systemImage: "bolt.horizontal.circle.fill")
                        .font(.caption.weight(.semibold))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(modeColors.inputBackground.opacity(0.95))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(modeColors.accentColor.opacity(0.2), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(modeColors.accentColor)
                .padding(.horizontal, Theme.screenPadding)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isContextCompressing {
                HStack {
                    Spacer()
                    Label {
                        Text("Compressing context...", bundle: LanguageSettings.currentBundle)
                    } icon: {
                        Image(systemName: "arrow.trianglehead.2.clockwise")
                    }
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.12))
                    .clipShape(Capsule())
                }
                .padding(.horizontal, Theme.screenPadding)
            }

            // 附件预览栏
            if !attachments.isEmpty {
                FileAttachmentBar(
                    attachments: attachments,
                    onRemove: onRemoveAttachment
                )
                .padding(.horizontal, Theme.screenPadding)
            }

            HStack(alignment: .center, spacing: 8) {
                if presentationState.isActive {
                    // 直连模式：config 按钮（替换回形针）
                    Button {
                        onConfigTap?()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 20))
                            .foregroundStyle(hasConfigData ? .secondary : Color.secondary.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasConfigData)
                } else if !hideAttachments {
                    // 正常模式：回形针（文件附件）
                    Button(action: onPickFile) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 20))
                            .foregroundStyle(isConnected ? .secondary : Color.secondary.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isConnected)
                }

                TextField(connectingPlaceholder, text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.trailing, showMicButton || isListening || isFinishing ? 36 : 0)
                    .padding(.vertical, 8)
                    .background(modeColors.inputBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused($isFocused)
                    .disabled(!isConnected || isConnectingToAgent || isListening || isFinishing)
                    .overlay {
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(
                                presentationState.isActive
                                    ? modeColors.accentColor.opacity(0.22)
                                    : .clear,
                                lineWidth: 1
                            )
                    }
                    .onSubmit {
                        if canSend {
                            isFocused = false
                            onSend()
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if showMicButton || isListening || isFinishing {
                            Button {
                                onMicTap?()
                            } label: {
                                ConchRippleView(
                                    isListening: isListening,
                                    isFinishing: isFinishing
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 6)
                        }
                    }

                if isConnectingToAgent {
                    // 连接中：显示终止按钮
                    Button {
                        onCancelConnect?()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 32, height: 32)
                            .background(Color.red)
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                } else {
                    Button {
                        isFocused = false
                        onSend()
                    } label: {
                        Image(systemName: "arrow.up")
                            .fontWeight(.semibold)
                            .frame(width: 32, height: 32)
                            .background(canSend ? modeColors.userBubbleColor : Color.secondary.opacity(0.3))
                            .clipShape(Circle())
                            .foregroundStyle(.white)
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: presentationState)
    }

    private var connectingPlaceholder: String {
        if isConnectingToAgent {
            return String(localized: "Connecting to agent...", bundle: LanguageSettings.currentBundle)
        }
        return presentationState.inputPlaceholderText ?? String(localized: "Type a message...", bundle: LanguageSettings.currentBundle)
    }

    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !attachments.isEmpty
        return (hasText || hasAttachments) && isConnected
    }

    /// 是否显示麦克风按钮：语音可用 && 非直连模式 && 未连接代理中 && 已连接
    private var showMicButton: Bool {
        isSpeechAvailable && !presentationState.isActive && !isConnectingToAgent && isConnected
    }

    /// 是否正在录音
    private var isListening: Bool {
        if case .listening = speechState { return true }
        return false
    }

    /// 是否正在完成识别
    private var isFinishing: Bool {
        if case .finishing = speechState { return true }
        return false
    }

    private var modeColors: Theme.ModeColors {
        presentationState.modeColors
    }

    private var statusText: String {
        switch presentationState.statusBar.status {
        case .connecting:
            return String(localized: "Connecting…", bundle: LanguageSettings.currentBundle)
        case .connected:
            return String(localized: "Ready", bundle: LanguageSettings.currentBundle)
        case .executing:
            return String(localized: "Working…", bundle: LanguageSettings.currentBundle)
        case .disconnecting:
            return String(localized: "Leaving…", bundle: LanguageSettings.currentBundle)
        case .failed:
            return String(localized: "Unavailable", bundle: LanguageSettings.currentBundle)
        case .inactive:
            return String(localized: "Idle", bundle: LanguageSettings.currentBundle)
        }
    }
}
