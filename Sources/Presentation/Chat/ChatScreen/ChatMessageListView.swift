/// 文件说明：ChatMessageListView，承载聊天消息区渲染、滚动跟随与直连模式覆盖层。
import SwiftUI

enum BubbleGesturePhase: Equatable {
    case idle
    case pulling(progress: CGFloat)
    case armed
    case retracting(from: CGFloat)
    case burst
}

/// 将高频流式状态读取下沉，避免整个消息列表跟着流式 token 一起重绘。
private struct StreamingMessageBubbleView: View {
    let message: Message
    let viewModel: ChatViewModel
    let userAvatarImage: Image?
    let agentType: AgentType?
    let presentationState: DirectModePresentationState

    var body: some View {
        MessageBubbleView(
            message: message,
            liveContentText: viewModel.activeContentText.isEmpty ? nil : viewModel.activeContentText,
            liveToolOutput: viewModel.liveToolOutput,
            agentStreamEvents: viewModel.agentStreamEvents,
            isAgentExecuting: viewModel.isAgentExecuting,
            serverIconImage: viewModel.serverIconImage,
            userAvatarImage: userAvatarImage,
            agentType: agentType,
            modeColors: presentationState.modeColors,
            presentationState: presentationState
        )
    }
}

/// 将实时推理内容的观察范围限制在单独子视图内。
private struct StreamingThinkingBubbleView: View {
    let viewModel: ChatViewModel

    var body: some View {
        if !viewModel.activeReasoningText.isEmpty {
            HStack {
                ThinkingBubbleView(
                    reasoningContent: viewModel.activeReasoningText,
                    isLiveStreaming: viewModel.isReasoningActive
                )
                Spacer(minLength: 60)
            }
        }
    }
}

/// 仅监听滚动触发器并在靠近底部时跟随滚动。
private struct ScrollTriggerView: View {
    let viewModel: ChatViewModel
    @Binding var scrollPosition: ScrollPosition
    let isNearBottom: Bool
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: viewModel.streamingScrollTrigger) {
                guard isNearBottom else { return }
                debounceTask?.cancel()
                debounceTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, isNearBottom else { return }
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
    }
}

/// 精简后的直连模式背景，仅保留品牌色渐变和柔光，删除未被复用的复杂纹理视图。
private struct DirectModeBackground: View {
    let agentType: AgentType

    var body: some View {
        ZStack {
            LinearGradient(
                colors: Theme.directMode(for: agentType).agentAvatarGradient,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [.white.opacity(0.18), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 280
            )
        }
        .ignoresSafeArea()
    }
}

/// 精简后的代理连接遮罩，保留连接状态反馈，移除装饰性较强的独立文件实现。
private struct AgentConnectingOverlay: View {
    let agentType: AgentType
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            DirectModeBackground(agentType: agentType)
                .opacity(0.9)

            VStack(spacing: 16) {
                agentIcon
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.white)
                    .scaleEffect(isPulsing ? 1.08 : 0.94)
                    .opacity(isPulsing ? 1 : 0.65)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: isPulsing)

                Text(String(localized: "Connecting to \(agentType.displayName)…", bundle: LanguageSettings.currentBundle))
                    .font(.headline)
                    .foregroundStyle(.white)

                Text(String(localized: "Starting agent, please wait", bundle: LanguageSettings.currentBundle))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(24)
        }
        .onAppear { isPulsing = true }
    }

    @ViewBuilder
    private var agentIcon: some View {
        if let symbol = agentType.systemIcon {
            Image(systemName: symbol)
        } else if let emoji = agentType.iconEmoji {
            Text(emoji)
        }
    }
}

enum BubbleGestureEvent {
    case geometryChanged
    case dragEnded
    case animationCompleted
}

struct BubbleGestureReducer {
    private static let displayThreshold: CGFloat = 5
    private static let armedThreshold: CGFloat = BubblePullInteraction.armedOverscrollPoints

    struct State {
        let phase: BubbleGesturePhase
        let shouldFireReadyHaptic: Bool
        let shouldTriggerContextBreak: Bool
    }

    static func reduce(
        phase: BubbleGesturePhase,
        isDragging: Bool,
        isNearBottom: Bool,
        overscroll: CGFloat,
        canTrigger: Bool,
        event: BubbleGestureEvent
    ) -> State {
        guard canTrigger else {
            return State(
                phase: .idle,
                shouldFireReadyHaptic: false,
                shouldTriggerContextBreak: false
            )
        }

        let nextPhase: BubbleGesturePhase

        switch event {
        case .geometryChanged:
            nextPhase = geometryPhase(
                currentPhase: phase,
                isDragging: isDragging,
                isNearBottom: isNearBottom,
                overscroll: overscroll
            )
        case .dragEnded:
            nextPhase = dragEndedPhase(from: phase)
        case .animationCompleted:
            nextPhase = animationCompletedPhase(from: phase)
        }

        let didEnterArmed = phase != .armed && nextPhase == .armed
        let shouldFireReadyHaptic = event == .geometryChanged && didEnterArmed
        let shouldTriggerContextBreak = event == .dragEnded && phase == .armed && nextPhase == .burst

        return State(
            phase: nextPhase,
            shouldFireReadyHaptic: shouldFireReadyHaptic,
            shouldTriggerContextBreak: shouldTriggerContextBreak
        )
    }

    static func gestureEnabled(
        canTriggerContextBreak: Bool,
        isKeyboardVisible: Bool
    ) -> Bool {
        canTriggerContextBreak && !isKeyboardVisible
    }

    private static func geometryPhase(
        currentPhase: BubbleGesturePhase,
        isDragging: Bool,
        isNearBottom: Bool,
        overscroll: CGFloat
    ) -> BubbleGesturePhase {
        switch currentPhase {
        case .retracting, .burst:
            return currentPhase
        default:
            break
        }

        // 松手瞬间 isDragging 可能已 false，但 dragEnded 尚未处理；保留 armed 以免误清成 idle 导致无法 burst
        if currentPhase == .armed, !isDragging {
            return .armed
        }

        guard isDragging, isNearBottom, overscroll > displayThreshold else {
            return .idle
        }

        if overscroll >= armedThreshold {
            return .armed
        }

        let normalizedProgress = min(max(overscroll / armedThreshold, 0), 1)
        return .pulling(progress: normalizedProgress)
    }

    private static func dragEndedPhase(from phase: BubbleGesturePhase) -> BubbleGesturePhase {
        switch phase {
        case .pulling(let progress):
            return .retracting(from: progress)
        case .armed:
            return .burst
        default:
            return .idle
        }
    }

    private static func animationCompletedPhase(from phase: BubbleGesturePhase) -> BubbleGesturePhase {
        switch phase {
        case .retracting, .burst:
            return .idle
        default:
            return phase
        }
    }
}

struct ChatMessageListView: View {
    let viewModel: ChatViewModel
    let userAvatarImage: Image?
    @Binding var isNearBottom: Bool
    /// 点击服务器头像时的回调
    var onServerAvatarTap: (() -> Void)? = nil

    private static let bubbleRetractDuration: Double = 0.2
    private static let bubbleBurstDuration: TimeInterval = BubblePullInteraction.membraneBurstDuration

    /// 气泡手势阶段
    @State private var bubblePhase: BubbleGesturePhase = .idle
    /// 是否正在拖动
    @GestureState private var isDragging: Bool = false
    /// 回缩动画进度
    @State private var retractingProgress: CGFloat? = nil
    /// 底部实时 rubber-band overscroll，与显示层共用，避免 pulling → armed 时 offset 跳变
    @State private var bubbleLiveOverscroll: CGFloat = 0
    /// 键盘显示期间禁用底部 clear-context 手势，避免收键盘时误触发。
    @State private var isKeyboardVisible: Bool = false
    /// 使用 ScrollPosition 精确控制滚动锚点，避免 defaultScrollAnchor 在键盘弹出时导致布局跳变。
    @State private var scrollPosition = ScrollPosition(edge: .bottom)

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.messageSpacing) {
                // 分页加载触发器
                if viewModel.hasOlderMessages {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .onAppear {
                            Task { await viewModel.loadOlderMessages() }
                        }
                }
                ForEach(viewModel.displayMessages) { message in
                    if message.systemMessageType == .contextBreak {
                        ContextBreakView(timestamp: message.timestamp)
                            .id(message.id)
                    } else {
                        let isBeforeBreak = viewModel.messageIDsBeforeBreak.contains(message.id)

                        if !message.isLoading,
                           let reasoning = message.reasoningContent, !reasoning.isEmpty {
                            HStack {
                                ThinkingBubbleView(
                                    reasoningContent: reasoning,
                                    isLiveStreaming: false
                                )
                                Spacer(minLength: 60)
                            }
                            .opacity(isBeforeBreak ? 0.6 : 1.0)
                            .id("thinking-\(message.id)")
                        }

                        if message.isLoading && viewModel.isProcessing {
                            StreamingThinkingBubbleView(viewModel: viewModel)
                                .id("live-thinking")
                        }

                        if message.isLoading {
                            StreamingMessageBubbleView(
                                message: message,
                                viewModel: viewModel,
                                userAvatarImage: userAvatarImage,
                                agentType: viewModel.directModePresentation.chatMode.agentType,
                                presentationState: viewModel.directModePresentation
                            )
                            .opacity(isBeforeBreak ? 0.6 : 1.0)
                            .id(message.id)
                        } else {
                            let isQueued = viewModel.queuedMessageIDs.contains(message.id)
                            MessageBubbleView(
                                message: message,
                                serverIconImage: viewModel.serverIconImage,
                                userAvatarImage: userAvatarImage,
                                agentType: nil,
                                modeColors: viewModel.directModePresentation.modeColors,
                                presentationState: viewModel.directModePresentation,
                                onServerAvatarTap: onServerAvatarTap
                            )
                            .opacity(isQueued ? 0.5 : (isBeforeBreak ? 0.6 : 1.0))
                            .contextMenu(menuItems: {
                                if isQueued {
                                    Button(role: .destructive) {
                                        viewModel.recallQueuedMessage(message.id)
                                    } label: {
                                        Label(
                                            String(localized: "Recall", bundle: LanguageSettings.currentBundle),
                                            systemImage: "arrow.uturn.backward"
                                        )
                                    }
                                }
                            })
                            .id(message.id)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.screenPadding)
            .padding(.vertical, 8)
        }
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        .simultaneousGesture(
            DragGesture()
                .updating($isDragging) { _, state, _ in
                    state = true
                }
                .onEnded { _ in
                    handleBubbleDragEnded()
                }
        )
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distanceFromBottom = geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height
            return distanceFromBottom < 100
        } action: { _, newValue in
            isNearBottom = newValue
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            let overscroll = geometry.contentOffset.y + geometry.containerSize.height - geometry.contentSize.height
            return overscroll > 0 ? overscroll : 0
        } action: { _, newValue in
            bubbleLiveOverscroll = newValue
            let state = BubbleGestureReducer.reduce(
                phase: bubblePhase,
                isDragging: isDragging,
                isNearBottom: isNearBottom,
                overscroll: newValue,
                canTrigger: BubbleGestureReducer.gestureEnabled(
                    canTriggerContextBreak: viewModel.canTriggerContextBreak,
                    isKeyboardVisible: isKeyboardVisible
                ),
                event: .geometryChanged
            )
            bubblePhase = state.phase

            if state.shouldFireReadyHaptic {
                HapticFeedback.bubbleReady()
            }
        }
        .onChange(of: viewModel.messages.count) { oldCount, _ in
            if viewModel.isPrependingMessages {
                // prepend 时不自动滚动，保持当前位置
                return
            }
            if oldCount == 0 {
                // 首次加载：延迟一帧确保 LazyVStack 布局完成后再滚动
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    scrollPosition.scrollTo(edge: .bottom)
                }
            } else if isNearBottom {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
        .onChange(of: viewModel.canTriggerContextBreak) { _, canTrigger in
            if !BubbleGestureReducer.gestureEnabled(
                canTriggerContextBreak: canTrigger,
                isKeyboardVisible: isKeyboardVisible
            ) {
                bubblePhase = .idle
            }
        }
        .onChange(of: isKeyboardVisible) { _, visible in
            if visible {
                bubblePhase = .idle
            }
        }
        .onChange(of: bubblePhase) { _, newPhase in
            switch newPhase {
            case .retracting(let progress):
                retractingProgress = progress
                withAnimation(.easeOut(duration: Self.bubbleRetractDuration)) {
                    retractingProgress = 0
                }
            default:
                retractingProgress = nil
            }
        }
        .overlay {
            ScrollTriggerView(viewModel: viewModel, scrollPosition: $scrollPosition, isNearBottom: isNearBottom)
        }
        .overlay(alignment: .bottom) {
            if bubblePhase != .idle {
                BubbleBurstView(state: bubbleDisplayState)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .background {
            if case .directAgent(_, let agentType) = viewModel.directModePresentation.chatMode {
                DirectModeBackground(agentType: agentType)
                    .transition(.opacity)
                    .overlay(alignment: .top) {
                        LinearGradient(
                            colors: [
                                viewModel.directModePresentation.modeColors.accentColor.opacity(0.18),
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 180)
                        .allowsHitTesting(false)
                    }
            }
        }
        .overlay {
            if viewModel.directSessionCoordinator.isConnectingToAgent, let agentType = viewModel.directSessionCoordinator.connectingAgentType {
                AgentConnectingOverlay(agentType: agentType)
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: viewModel.directModePresentation)
    }

    private var bubbleDisplayState: BubbleGestureState {
        Self.bubbleDisplayState(
            phase: bubblePhase,
            retractingProgress: retractingProgress,
            liveOverscroll: bubbleLiveOverscroll
        )
    }

    static func bubbleDisplayState(
        phase: BubbleGesturePhase,
        retractingProgress: CGFloat?,
        liveOverscroll: CGFloat = 0
    ) -> BubbleGestureState {
        let armedThreshold: CGFloat = BubblePullInteraction.armedOverscrollPoints
        let visualCap = BubblePullInteraction.visualFullOverscrollPoints
        let displayOffset = min(liveOverscroll, visualCap)
        switch phase {
        case .idle:
            return .idle
        case .pulling:
            return .pulling(offset: displayOffset)
        case .armed:
            return .ready(offset: displayOffset)
        case .retracting(let progress):
            let displayProgress = retractingProgress ?? progress
            return .pulling(offset: displayProgress * armedThreshold)
        case .burst:
            return .burst
        }
    }

    private func handleBubbleDragEnded() {
        let state = BubbleGestureReducer.reduce(
            phase: bubblePhase,
            isDragging: false,
            isNearBottom: isNearBottom,
            overscroll: 0,
            canTrigger: BubbleGestureReducer.gestureEnabled(
                canTriggerContextBreak: viewModel.canTriggerContextBreak,
                isKeyboardVisible: isKeyboardVisible
            ),
            event: .dragEnded
        )
        bubblePhase = state.phase

        let expectedPhase = state.phase
        switch state.phase {
        case .burst:
            if state.shouldTriggerContextBreak {
                Task {
                    await viewModel.triggerContextBreak()
                    scheduleBubbleAnimationCompletion(after: .seconds(Self.bubbleBurstDuration), expectedPhase: expectedPhase)
                }
            } else {
                scheduleBubbleAnimationCompletion(after: .seconds(Self.bubbleBurstDuration), expectedPhase: expectedPhase)
            }
        case .retracting:
            scheduleBubbleAnimationCompletion(after: .seconds(Self.bubbleRetractDuration), expectedPhase: expectedPhase)
        default:
            break
        }
    }

    private func scheduleBubbleAnimationCompletion(after delay: Duration, expectedPhase: BubbleGesturePhase) {
        let targetPhase = expectedPhase
        Task {
            try? await Task.sleep(for: delay)
            guard bubblePhase == targetPhase else { return }
            let state = BubbleGestureReducer.reduce(
                phase: bubblePhase,
                isDragging: false,
                isNearBottom: isNearBottom,
                overscroll: 0,
                canTrigger: BubbleGestureReducer.gestureEnabled(
                    canTriggerContextBreak: viewModel.canTriggerContextBreak,
                    isKeyboardVisible: isKeyboardVisible
                ),
                event: .animationCompleted
            )
            bubblePhase = state.phase
        }
    }
}
