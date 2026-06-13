/// 文件说明：ChatViewModelTaskFlow，承载消息发送、中断、观察者与交互决策流程。
import Foundation

extension ChatViewModel {
    /// 发送消息：用户消息立即持久化，AI 任务通过 enqueueTask 委托给 TaskExecutionCoordinator。
    func sendMessage() {
        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty || !attachments.isEmpty else { return }

        // 直连模式：消息走 ACP（通过 DirectSessionCoordinator）
        if directSessionCoordinator.hasActiveSession {
            inputText = ""
            clearAttachments()
            error = nil
            directSessionCoordinator.sendPrompt(trimmedText)
            return
        }

        // 构建消息内容：新附件信息追加到文本中
        var messageContent = trimmedText
        let newAttachments = attachments
        if !newAttachments.isEmpty {
            // 将新选择的附件移入 pending 池（跨消息保持可用）
            pendingAttachments.append(contentsOf: newAttachments)
            let fileList = newAttachments.map { "\($0.fileName) (\($0.formattedSize))" }.joined(separator: ", ")
            // 附件标签发给 AI，不做本地化
            let attachedLabel = "Attached files"
            if messageContent.isEmpty {
                messageContent = "[\(attachedLabel): \(fileList)]"
            } else {
                messageContent += "\n\n[\(attachedLabel): \(fileList)]"
            }
        }

        inputText = ""
        clearAttachments()
        error = nil

        // 添加用户消息
        let userMsg = Message(role: .user, content: messageContent)
        messages.append(userMsg)

        // 标记消息为排队状态（若当前有活跃任务，消息进入排队）
        let isQueuing = isProcessing || taskCoordinator.hasActiveTask(for: serverID)
        if isQueuing {
            markAsQueued(userMsg.id)
        } else {
            // 无活跃任务，立即进入处理状态
            isProcessing = true
            // 添加 loading 指示器
            let loadingMsg = Message(id: UUID(), role: .assistant, content: "", isLoading: true)
            messages.append(loadingMsg)
            // 重置流式状态
            activeReasoningText = ""
            activeContentText = ""
            isStreaming = true
            isReasoningActive = false
        }

        // AI 任务需要完整对话历史，分页模式下先加载全部
        let capturedAttachments = pendingAttachments
        let userMsgID = userMsg.id
        // 与 markAsQueued 同一 MainActor turn 内登记「等待入队」，
        // 防止兜底自愈在入队完成前误摘排队标记（→ 撤回拦截误判 → 消息静默丢失）
        pendingEnqueueMessageIDs.insert(userMsgID)
        deferredEnqueueTask = Task { [weak self] in
            guard let self else { return }
            // 所有退出路径（取消/加载失败/撤回拦截/入队完成）统一注销等待标记
            defer { self.pendingEnqueueMessageIDs.remove(userMsgID) }
            let loaded = await self.ensureFullHistoryLoaded()
            guard !Task.isCancelled else { return }
            guard loaded else {
                self.error = String(localized: "Failed to load complete chat history", bundle: LanguageSettings.currentBundle)
                // 只在本次发送拥有 UI 控制权时重置（排队模式下 UI 属于活跃任务）
                if !isQueuing {
                    self.isProcessing = false
                    self.removeLoadingMessages()
                    self.clearTransientStreamingState()
                    self.detachObserver()
                } else {
                    self.queuedMessageIDs.remove(userMsgID)
                }
                self.deferredEnqueueTask = nil
                return
            }
            // 排队消息在 enqueue 前已被撤回 → 不再入队（堵住「撤回早于入队」的窗口）。
            // 条件必须带 isQueuing：非排队的首发消息从不进入 queuedMessageIDs，不能被误拦。
            if isQueuing && !self.queuedMessageIDs.contains(userMsgID) {
                self.deferredEnqueueTask = nil
                return
            }
            self.taskCoordinator.enqueueTask(
                taskID: userMsgID,
                serverID: self.serverID,
                text: messageContent,
                server: self.server,
                messages: self.messages,
                attachments: capturedAttachments
            )
            self.deferredEnqueueTask = nil
        }

        // 持久化用户消息（句柄入表，撤回时可等待写入完成后再删除）
        let persistTask = Task { [weak self, store, sid = serverID] in
            do {
                try await store.addMessage(userMsg, toServer: sid)
            } catch {
                print("[ChatVM] Failed to persist user message: \(error)")
            }
            self?.messagePersistTasks.removeValue(forKey: userMsgID)
        }
        messagePersistTasks[userMsgID] = persistTask

        if !isQueuing {
            // 注册 observer 以接收实时状态推送
            attachObserver()
        }
    }

    /// 注册 TaskExecutionCoordinator 状态观察者，实时接收流式状态推送。
    func attachObserver() {
        var isFirstSync = true
        taskCoordinator.setObserver(for: serverID, emitCurrent: true) { [weak self] state in
            guard let self else { return }
            self.activeReasoningText = state.activeReasoningText
            self.activeContentText = state.activeContentText
            self.liveToolOutput = state.liveToolOutput
            self.agentStreamEvents = state.agentStreamEvents
            self.isAgentExecuting = state.isAgentExecuting
            self.isStreaming = state.isStreaming
            self.isReasoningActive = state.isReasoningActive
            self.isContextCompressing = state.isContextCompressing

            // 任务被 dequeue 开始执行 → 即时摘除排队标记（幂等，Set.remove）
            if let executingID = state.currentTaskID {
                self.markAsExecuting(executingID)
            }

            // 中间消息实时追加（通过 ID 去重，确保每条消息只追加一次）
            if let intermediateMsg = state.latestIntermediateMessage,
               !self.messages.contains(where: { $0.id == intermediateMsg.id }) {
                self.removeLoadingMessages()
                self.messages.append(intermediateMsg)
                // 若非最终回复，为下一轮添加 loading 指示器
                if intermediateMsg.role != .assistant {
                    self.isStreaming = true
                    let loading = Message(id: UUID(), role: .assistant, content: "", isLoading: true)
                    self.messages.append(loading)
                }
            }

            // 首次同步跳过滚动触发，避免抖动
            if isFirstSync {
                isFirstSync = false
            } else {
                self.streamingScrollTrigger &+= 1
            }
            // 审批展示（互斥保护）
            if let toolCall = state.pendingToolCall {
                self.presentConfirmation(toolCall)
            } else if self.showConfirmation {
                self.showConfirmation = false
                self.pendingToolCall = nil
            }

            // Agent 连接模式选择弹窗
            if state.pendingAgentConnection && !self.agentPicker.showAgentPicker && !self.agentPicker.showDirectoryBrowser {
                self.agentPicker.requestAgentPicker(
                    preferredAgentType: state.preferredAgentType,
                    cwd: state.agentCwd,
                    directories: state.agentDirectories,
                    homePath: state.agentHomePath
                )
            } else if !state.pendingAgentConnection && self.agentPicker.showAgentPicker {
                // 超时等原因取消
                self.agentPicker.showAgentPicker = false
            } else if !state.pendingAgentConnection && self.agentPicker.showDirectoryBrowser {
                // 超时等原因取消目录浏览器
                self.agentPicker.cancelDirectoryBrowser()
            }

            // 任务完成通知：isStreaming 变为 false 且无活跃任务
            if !state.isStreaming && !self.taskCoordinator.hasActiveTask(for: self.serverID) {
                Task { [weak self] in
                    await self?.syncAfterTaskCompletion()
                    guard let self else { return }
                    // cleanupTask 的 removeState 会连 observer 一并移除。
                    // 若还有后续任务（运行中 / 排队 / 等待入队），需要重挂 observer，
                    // 否则 drained 任务执行期间 UI 收不到推送、完成后也无人触发兜底同步。
                    // 本分支只在完成推送到达 observer（用户在页面）时进入，离页后不会误挂。
                    if self.taskCoordinator.hasActiveTask(for: self.serverID)
                        || !self.taskCoordinator.taskQueue.isEmpty(for: self.serverID)
                        || !self.pendingEnqueueMessageIDs.isEmpty {
                        self.attachObserver()
                    }
                }
            }
        }
    }

    /// 注销状态观察者（离开页面时调用，任务继续运行）。
    func detachObserver() {
        taskCoordinator.setObserver(for: serverID, callback: nil)
    }

    /// 当观察者收到任务完成信号（流式状态被清理）后，重新加载消息以同步最终状态。
    func syncAfterTaskCompletion() async {
        guard !isSyncingAfterCompletion else { return }
        guard !taskCoordinator.hasActiveTask(for: serverID) else { return }
        isSyncingAfterCompletion = true
        defer { isSyncingAfterCompletion = false }

        // 从 SwiftData 重新加载完整消息
        await reloadMessagesFromStore()

        // 1. 清状态
        removeLoadingMessages()
        isProcessing = false
        clearTransientStreamingState()
        pendingAttachments.removeAll()

        // 2. 兜底自愈：排队标记与「coordinator 队列 ∪ 等待入队集合」求交集，
        //    修剪错过 currentTaskID 推送的残留标记（本方法只经 observer 回调触发；
        //    observer 不在线的残留由 loadMessages 的重进自愈兜底）。
        //    等待入队中的消息尚未进入 coordinator 队列，但并非用户撤回，
        //    绝不能在此被摘——否则入队前拦截会误判撤回、静默丢消息。
        let stillQueuedIDs = Set(taskCoordinator.taskQueue.tasks(for: serverID).map(\.id))
        queuedMessageIDs.formIntersection(stillQueuedIDs.union(pendingEnqueueMessageIDs))
    }

    /// 同意当前待审批工具调用。
    func approveCommand() {
        showConfirmation = false
        pendingToolCall = nil
        taskCoordinator.approveToolCall(for: serverID)
    }

    /// 拒绝当前待审批工具调用。
    func denyCommand() {
        showConfirmation = false
        pendingToolCall = nil
        taskCoordinator.denyToolCall(for: serverID)
    }

    /// 显示审批弹窗。
    func presentConfirmation(_ toolCall: ToolCall) {
        pendingToolCall = toolCall
        showConfirmation = true
    }
}
