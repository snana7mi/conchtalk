/// 文件说明：ChatViewModelConnection，承载聊天页面连接、重连与生命周期。
import Foundation

extension ChatViewModel {
    func appendAIContextMessage(_ content: String) async {
        let message = Message(
            role: .system,
            content: content,
            systemMessageType: .aiContext
        )
        messages.append(message)
        try? await store.addMessage(message, toServer: serverID)
    }

    private func canProbeCurrentConnection() async -> Bool {
        guard let client = await MainActor.run(body: { sshManager.getClient(for: server.id) }) else {
            return false
        }
        do {
            _ = try await client.execute(command: "echo __probe__", timeout: 5)
            return true
        } catch {
            return false
        }
    }

    /// 检查是否已有可复用的连接（用户离开后重新进入对话时跳过连接流程）。
    /// SSH 模式探测 exec channel。
    func checkExistingConnection() async -> Bool {
        let alive = await canProbeCurrentConnection()
        if alive {
            isConnected = true
            return true
        }
        return false
    }

    /// 建立到当前服务器的 SSH 连接，并把结果写入会话消息流。
    func connect(isReconnection: Bool = false) async {
        // currentUser 尚未加载时回退到本地缓存的 tier，避免 session restore 期间误判
        let tier = authService.currentUser?.tier
            ?? UserDefaults.standard.string(forKey: "AuthService.cachedTier")
            ?? "free"

        // UI 层连接限制检查
        if tier != "paid" {
            let otherActiveIDs = sshManager.activeConnectionIDs.subtracting([server.id])
            if !otherActiveIDs.isEmpty {
                showPaywall = true
                return
            }
        }

        do {
            var password: String? = nil
            if case .password = server.authMethod {
                password = try keychainService.getPassword(forServer: server.id)
            }
            try await sshManager.ensureConnected(to: server, password: password, keychainService: keychainService, userTier: tier)
            isConnected = true
            HapticFeedback.connectionSuccess()
            if isReconnection {
                appendSystemMessage(
                    String(localized: "SSH connection restored", bundle: LanguageSettings.currentBundle),
                    type: .reconnected
                )
            } else {
                appendSystemMessage(
                    String(localized: "SSH connection established", bundle: LanguageSettings.currentBundle),
                    type: .connected
                )
            }
        } catch {
            isConnected = false
            self.error = String(localized: "Connection failed: \(error.localizedDescription)", bundle: LanguageSettings.currentBundle)
            let errorMsg = Message(role: .system, content: String(localized: "Connection failed: \(error.localizedDescription)", bundle: LanguageSettings.currentBundle), systemMessageType: .connectionFailed)
            messages.append(errorMsg)
            try? await store.addMessage(errorMsg, toServer: serverID)
        }
    }

    /// 健康检查：检测意外断线并自动重连，返回检测结果。
    func performHealthCheck() async {
        let alive = await canProbeCurrentConnection()
        guard !alive else { return }
        _ = await attemptInPlaceReconnect(recordLostMessage: true)
    }

    /// 前台恢复时的探测式健康检查：验证连接，不依赖可能过时的 isConnected flag。
    /// 后台挂起期间 keep-alive 冻结，flag 不会更新，因此需要主动探测。
    func performForegroundResumeCheck() async {
        let alive = await canProbeCurrentConnection()
        if isConnected && !alive {
            sshManager.clearReconnectState(for: server.id)
            await attemptInPlaceReconnect(recordLostMessage: true)
        }
    }

    /// 当前会话原地自动重连，供健康检查和前台恢复共用。
    @discardableResult
    func attemptInPlaceReconnect(recordLostMessage: Bool, failureMessage: String? = nil) async -> Bool {
        guard !isReconnecting else { return false }

        print(
            "[ChatVM] Starting in-place reconnect: " +
            "server=\(server.id.uuidString), " +
            "recordLostMessage=\(recordLostMessage)"
        )
        isReconnecting = true
        isConnected = false
        defer { isReconnecting = false }

        if recordLostMessage {
            appendSystemMessage(
                String(localized: "Connection lost unexpectedly", bundle: LanguageSettings.currentBundle),
                type: .connectionLost
            )

            // AI 专用上下文标记：告知 AI SSH 断开，之前的工具调用状态已失效
            await appendAIContextMessage(
                "[Context] SSH connection was lost. All previous tool call states (including pending agent connections) are invalidated. This is a new conversation context — do not reference or continue any previous pending operations. If the user asks to retry something, you must initiate it fresh by calling the appropriate tool."
            )
        }

        var password: String? = nil
        if case .password = server.authMethod {
            password = try? keychainService.getPassword(forServer: server.id)
        }

        await sshManager.reconnectWithBackoff(server: server, password: password, keychainService: keychainService)

        let reconnected = await sshManager.isConnected(serverID: server.id)
        if reconnected {
            print("[ChatVM] In-place reconnect succeeded: server=\(server.id.uuidString)")
            isConnected = true
            HapticFeedback.connectionSuccess()
            appendSystemMessage(
                String(localized: "SSH connection restored", bundle: LanguageSettings.currentBundle),
                type: .reconnected
            )

            // AI 专用上下文标记：告知 AI SSH 已重连，这是一个新的会话上下文
            await appendAIContextMessage(
                "[Context] SSH connection has been re-established. This is a fresh session context. If the user asks to connect to an agent or retry a previous operation, you must call the appropriate tool (e.g. suggest_agent_connection) — do not assume any previous state carries over."
            )
        } else if let failureMessage {
            print("[ChatVM] In-place reconnect failed: server=\(server.id.uuidString)")
            appendSystemMessage(
                failureMessage,
                type: .connectionFailed
            )
        } else {
            print("[ChatVM] In-place reconnect failed without explicit failure message: server=\(server.id.uuidString)")
        }
        return reconnected
    }

    /// 主动断开 SSH 连接并更新本地连接状态，持久化断开消息。
    /// 先取消该服务器所有后台任务，再断开 SSH，与列表页断开语义一致。
    func disconnect() async {
        // 先注销 observer，防止任务取消过程中的通知干扰
        detachObserver()
        removeLoadingMessages()
        clearPendingInteractionState()
        clearTransientStreamingState()
        isProcessing = false

        await taskCoordinator.cancelTasks(forServer: server.id)
        sshManager.clearReconnectState(for: server.id)
        await sshManager.disconnect(from: server.id)
        isConnected = false

        // 重载消息（任务取消期间可能有部分内容落盘）
        await reloadMessagesFromStore()
        let timestamp = Date.now.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(LanguageSettings.currentLocale))
        let msg = Message(role: .system, content: String(localized: "SSH disconnected", bundle: LanguageSettings.currentBundle) + " (\(timestamp))", systemMessageType: .disconnected)
        messages.append(msg)
        try? await store.addMessage(msg, toServer: serverID)
    }

    /// 关闭当前服务器的 AI 任务（关闭按钮点击时调用）。
    func closeSession() async {
        // 取消尚未 enqueue 的延迟任务（ensureFullHistoryLoaded 期间用户断开）
        deferredEnqueueTask?.cancel()
        deferredEnqueueTask = nil

        // 清理直连会话（通过 DirectSessionCoordinator）
        if directSessionCoordinator.hasActiveSession {
            await directSessionCoordinator.disconnect(messages: messages)
        }

        taskCoordinator.cancelTask(for: serverID)
    }

    /// 断开 SSH 连接并清理所有相关资源（断开连接按钮点击时调用）。
    func disconnectAndCleanup() async {
        // 显式取消事件消费任务：结构性弱引用已防泄漏，
        // 此处保证主动断开后不再处理迟到事件（cancel 在下一个事件到达时生效）
        directEventTask?.cancel()
        directEventTask = nil
        // 先清理 AI 任务和直连会话
        await closeSession()
        // 走完整的断开流程（设置 isConnected、插入"SSH 已断开"消息）
        await disconnect()
    }
}
