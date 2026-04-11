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

    /// Relay 模式下判断 WebSocket 通道是否存活。
    /// daemon 在线状态由事件流实时推送，不影响连接 banner 显示。
    private func isRelayAlive() async -> Bool {
        guard let relay = relayConnection else { return false }
        return await relay.isConnected
    }

    /// 检查是否已有可复用的连接（用户离开后重新进入对话时跳过连接流程）。
    /// Relay 模式检查 WebSocket 状态，SSH 模式探测 exec channel。
    func checkExistingConnection() async -> Bool {
        if usesRelay {
            // Relay 模式：WebSocket 通道存活即视为已连接
            if await isRelayAlive() {
                isConnected = true
                return true
            }
            return false
        }

        let alive = await canProbeCurrentConnection()
        if alive {
            isConnected = true
            // DLC 自动安装：首次进入聊天页时，SSH 已在 ConchTalkApp 层建立，
            // connect() 不会被调用，因此在此处触发安装。
            await installDLCIfNeeded()
            return true
        }
        return false
    }

    /// DLC 自动安装：检查是否需要安装 daemon，避免重复安装。
    private func installDLCIfNeeded() async {
        print("[DLC] installDLCIfNeeded: server=\(server.id), enabled=\(DLCSettings.isEffectivelyEnabled(for: server.id)), installer=\(dlcInstaller != nil)")
        guard DLCSettings.isEffectivelyEnabled(for: server.id),
              let installer = dlcInstaller else { return }

        // 先检查 daemon 是否已在线，已在线则跳过
        if let service = relayTokenService {
            do {
                let status = try await service.getStatus(serverID: server.id)
                if status.isDaemonOnline {
                    print("[DLC] Daemon already online for server \(server.id), skipping install")
                    return
                }
            } catch {
                // 查询失败（如 404 无 token），继续安装流程
            }
        }

        isDLCInstalling = true
        appendSystemMessage(
            String(localized: "Installing DLC Agent...", bundle: LanguageSettings.currentBundle),
            type: .info
        )
        let result = await installer.install(serverID: server.id, serverName: server.name)
        isDLCInstalling = false
        if result.success {
            appendSystemMessage(
                String(localized: "DLC Agent installed successfully", bundle: LanguageSettings.currentBundle),
                type: .info
            )
        } else {
            dlcInstallError = result.errorMessage ?? "Unknown error"
            showDLCInstallFailed = true
        }
    }

    // MARK: - Relay 连接

    /// 连接 relay 模式（通过 Cloudflare 中转，不直连服务器，无需向用户展示连接状态消息）。
    func connectRelay() async {
        guard let relay = relayConnection else { return }
        guard !isReconnecting else { return }
        // 已连接时直接同步状态，跳过重复连接
        if await relay.isConnected {
            isConnected = true
            return
        }
        isReconnecting = true
        defer { isReconnecting = false }
        do {
            try await relay.connect()
            // isConnected 由事件流 .connected 设置（首次成功接收消息后确认）
        } catch {
            isConnected = false
            self.error = error.localizedDescription
        }
    }

    /// 断开 relay 连接。
    func disconnectRelay() async {
        relayEventTask?.cancel()
        relayEventTask = nil
        await relayConnection?.disconnect()
        isConnected = false
        // 注销 RelaySSHClient
        taskCoordinator.removeRelayClient(for: serverID)
        let timestamp = Date.now.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(LanguageSettings.currentLocale))
        let msg = Message(role: .system, content: String(localized: "Relay disconnected", bundle: LanguageSettings.currentBundle) + " (\(timestamp))", systemMessageType: .disconnected)
        messages.append(msg)
        try? await store.addMessage(msg, toServer: serverID)
    }

    // MARK: - Relay 事件处理

    /// 处理从 relay DO 收到的事件。
    /// 瘦 Relay 模式下，agent loop 事件由 TaskExecutionCoordinator 处理，
    /// 此处仅处理连接/状态事件，并转发工具事件给 RelaySSHClient。
    func handleRelayEvent(_ event: RelayEvent) {
        switch event {
        case .connected:
            isConnected = true

        case .disconnected:
            isConnected = false
            // 连接断开，通知 RelaySSHClient 清理所有 pending calls
            if let client = relaySSHClient {
                Task { await client.handleEvent(event) }
            }

        case .error(let message):
            error = message

        case .daemonStatus(let online):
            // Daemon 状态同步到 isConnected：WebSocket 连接 + daemon 在线才算可用
            if online {
                isConnected = true
            } else {
                isConnected = false
                if let client = relaySSHClient {
                    Task { await client.handleEvent(.disconnected) }
                }
            }

        case .acpStarted, .acpData, .acpClosed, .acpError:
            // ACP 事件由 RelayACPTransport 直接消费，此处忽略
            break

        case .metrics:
            // Metrics 已在 RelayConnection 中缓存，无需 ViewModel 处理
            break

        case .capabilities:
            // capabilities 由 AgentPickerCoordinator 直接从 events 流消费
            break

        case .toolDone, .toolError, .toolProgress:
            // 转发给 RelaySSHClient 处理
            if let client = relaySSHClient {
                Task { await client.handleEvent(event) }
            }

        case .toolResult:
            // 旧 agent loop 事件，瘦 Relay 模式下忽略
            break

        case .assistantText, .toolCall, .approvalRequest, .done:
            // 旧 agent loop 事件，瘦 Relay 模式下不再产生
            break

        case .sync(let bufferedMessages):
            for raw in bufferedMessages {
                guard let data = try? JSONSerialization.data(withJSONObject: raw),
                      let event = RelayMessage.parse(from: data) else { continue }
                handleRelayEvent(event)
            }
        }
    }

    /// 建立到当前服务器的 SSH 连接，并把结果写入会话消息流。
    func connect(isReconnection: Bool = false) async {
        // Relay / DLC 模式走 WebSocket，不走 SSH
        if usesRelay {
            await connectRelay()
            return
        }

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

            // DLC 自动安装流程
            await installDLCIfNeeded()
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
        if usesRelay {
            // Relay 模式：同步 WebSocket 连接状态
            let alive = await isRelayAlive()
            if isConnected && !alive {
                isConnected = false
            } else if !isConnected && alive {
                isConnected = true
            }
            return
        }
        let alive = await canProbeCurrentConnection()
        guard !alive else { return }
        _ = await attemptInPlaceReconnect(recordLostMessage: true)
    }

    /// 前台恢复时的探测式健康检查：验证连接，不依赖可能过时的 isConnected flag。
    /// 后台挂起期间 keep-alive 冻结，flag 不会更新，因此需要主动探测。
    func performForegroundResumeCheck() async {
        if usesRelay {
            // Relay 模式：从后台恢复时同步 WebSocket 状态
            let alive = await isRelayAlive()
            if isConnected && !alive {
                // WebSocket 已断开或 daemon 离线，静默尝试自动重连
                isConnected = false
                await connectRelay()
            } else if !isConnected && alive {
                isConnected = true
            }
            return
        }
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
        // Relay / DLC 模式断开 WebSocket
        if usesRelay {
            await disconnectRelay()
            return
        }

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
        // 先清理 AI 任务和直连会话
        await closeSession()
        // 走完整的断开流程（设置 isConnected、插入"SSH 已断开"消息）
        await disconnect()
    }
}
