/// 文件说明：AgentPickerCoordinator，管理 Agent 选择器和目录浏览器的状态与交互逻辑。
import SwiftUI

/// AgentPickerOption：agent 选择 alert 中的一个选项。
struct AgentPickerOption {
    let label: String
    let action: AgentPickerAction
}

/// AgentPickerAction：选项对应的动作。
enum AgentPickerAction {
    /// 选择了一个 agent（进入确认步骤）。
    case selectAgent(AgentInfo)
    /// 确认接入选中的 agent，cwd 为工作目录（可为 nil）。
    case confirmConnection(AgentInfo, cwd: String?)
    /// 取消。
    case cancel
}

/// AgentPickerCoordinator：
/// 负责 Agent 选择弹窗和目录浏览器的状态管理与交互逻辑，
/// 从 ChatViewModel 中提取以降低其复杂度。
@Observable
final class AgentPickerCoordinator {
    // MARK: - Agent 选择器状态

    /// Agent 选择 alert 显示状态。
    var showAgentPicker: Bool = false
    /// Agent 选择 alert 标题。
    var title: String = ""
    /// Agent 选择 alert 警告信息（可选，仅特定 agent 显示）。
    var message: String?
    /// Agent 选择 alert 选项。
    var options: [AgentPickerOption] = []
    /// 缓存的可用代理列表。
    var cachedAvailableAgents: [AgentInfo] = []

    /// Agent 选择步骤中已选中的 agent（两步选择用）。
    private var selectedAgent: AgentInfo?

    // MARK: - 目录浏览器状态

    /// 目录浏览 Sheet 显示状态。
    var showDirectoryBrowser: Bool = false
    /// 当前浏览的目录路径。
    var browserPath: String = ""
    /// 当前路径下的目录列表。
    var browserEntries: [String] = []
    /// 目录浏览器加载状态。
    var browserLoading: Bool = false
    /// 等待选择路径的 agent。
    private var pendingAgent: AgentInfo?
    /// 防止 requestAgentPicker 并发执行的守卫标志。
    private var isPickerRequestInFlight: Bool = false

    // MARK: - 依赖

    private let sshManager: SSHSessionManager
    private let server: Server
    private let taskCoordinator: TaskExecutionCoordinator
    private var serverID: UUID { server.id }
    /// 系统消息回调，参数为 (text, type)。
    @ObservationIgnored private var onSystemMessage: (_ text: String, _ type: Message.SystemMessageType) -> Void
    /// 用户确认接入后调用，参数为 (agent, cwd)。同步闭包，内部自行启动 Task。
    @ObservationIgnored private var onConfirmConnection: (AgentInfo, String?) -> Void

    init(
        sshManager: SSHSessionManager,
        server: Server,
        taskCoordinator: TaskExecutionCoordinator,
        onSystemMessage: @escaping (_ text: String, _ type: Message.SystemMessageType) -> Void = { _, _ in },
        onConfirmConnection: @escaping (AgentInfo, String?) -> Void = { _, _ in }
    ) {
        self.sshManager = sshManager
        self.server = server
        self.taskCoordinator = taskCoordinator
        self.onSystemMessage = onSystemMessage
        self.onConfirmConnection = onConfirmConnection
    }

    /// 初始化后绑定回调（解决 init 中无法捕获 self 的问题）。
    func bind(
        onSystemMessage: @escaping (_ text: String, _ type: Message.SystemMessageType) -> Void,
        onConfirmConnection: @escaping (AgentInfo, String?) -> Void
    ) {
        self.onSystemMessage = onSystemMessage
        self.onConfirmConnection = onConfirmConnection
    }

    // MARK: - Agent 选择流程

    /// 请求展示 Agent 选择器，根据服务器能力探测结果决定展示方式。
    func requestAgentPicker(preferredAgentType: String? = nil, cwd: String? = nil, directories: [String]? = nil, homePath: String? = nil) {
        // 防止多次并发调用（observer 在 async 间隙可能重复触发）
        guard !isPickerRequestInFlight else { return }
        isPickerRequestInFlight = true
        Task {
            defer { isPickerRequestInFlight = false }

            // 获取可用代理列表：通过 SSH 探测服务器能力
            let agents: [AgentInfo]
            guard let client = sshManager.getClient(for: server.id) else {
                taskCoordinator.resolveAgentConnection(for: serverID, with: .cancelled)
                return
            }
            let caps = await client.serverCapabilities
            agents = caps.availableAgents
            guard !agents.isEmpty else {
                onSystemMessage(
                    String(localized: "No coding agents available on this server", bundle: LanguageSettings.currentBundle),
                    .error
                )
                // 无可用代理时必须 resolve，否则 continuation 永远挂起
                taskCoordinator.resolveAgentConnection(for: serverID, with: .cancelled)
                return
            }
            cachedAvailableAgents = agents

            // 确定目标 agent
            let targetAgent: AgentInfo?
            if let preferred = preferredAgentType,
               let matchedAgent = agents.first(where: { $0.type.rawValue == preferred }) {
                targetAgent = matchedAgent
            } else if let preferred = preferredAgentType,
                      AgentType(rawValue: preferred) == nil {
                // AI 指定了不支持 ACP 的代理
                taskCoordinator.resolveAgentConnection(for: serverID, with: .unsupported)
                return
            } else if let preferred = preferredAgentType,
                      agents.first(where: { $0.type.rawValue == preferred }) == nil {
                // AI 指定了已知的 ACP 代理但该服务器上未安装
                let agentName = AgentType(rawValue: preferred)?.displayName ?? preferred
                let available = agents.map(\.type.displayName).joined(separator: ", ")
                onSystemMessage(
                    String(localized: "\(agentName) is not available on this server. Available agents: \(available)", bundle: LanguageSettings.currentBundle),
                    .info
                )
                showAgentSelectionAlert(agents: agents)
                return
            } else if agents.count == 1 {
                targetAgent = agents[0]
            } else {
                targetAgent = nil
            }

            // 没有确定的目标 agent，显示选择列表
            guard let agent = targetAgent else {
                showAgentSelectionAlert(agents: agents)
                return
            }

            selectedAgent = agent

            // 非编码代理：直接弹确认框，不需要工作目录
            guard agent.type.isCodingAgent else {
                showAgentConfirmationAlert(for: agent, cwd: nil)
                return
            }

            // 编码代理：必须通过目录浏览器选择工作目录
            pendingAgent = agent
            // AI 提供的 cwd 作为初始浏览路径，否则用 home 目录
            let initialPath: String
            if let cwd, !cwd.isEmpty {
                initialPath = cwd
            } else {
                initialPath = await resolveHomeDirectory()
            }
            browserPath = initialPath
            if let directories, !directories.isEmpty, homePath == initialPath {
                // AI 预取的目录列表与当前路径一致，直接使用
                browserEntries = directories
            } else {
                fetchDirectoryEntries(path: initialPath)
            }
            showDirectoryBrowser = true
        }
    }

    /// 显示 agent 选择 alert（第一步）。
    private func showAgentSelectionAlert(agents: [AgentInfo]) {
        title = String(localized: "Select Agent", bundle: LanguageSettings.currentBundle)
        message = nil
        options = agents.map { agent in
            AgentPickerOption(label: "\(agent.type.displayName) \(agent.version ?? "")", action: .selectAgent(agent))
        }
        showAgentPicker = true
    }

    /// 显示确认接入 alert。
    private func showAgentConfirmationAlert(for agent: AgentInfo, cwd: String? = nil) {
        if let cwd {
            title = String(localized: "Connect to \(agent.type.displayName) in \(cwd)?", bundle: LanguageSettings.currentBundle)
        } else {
            title = String(localized: "Connect to \(agent.type.displayName)?", bundle: LanguageSettings.currentBundle)
        }
        // 特定 agent 的警告信息
        message = AgentWarnings.combinedMessage(for: agent.type)
        options = [
            AgentPickerOption(
                label: String(localized: "Confirm", bundle: LanguageSettings.currentBundle),
                action: .confirmConnection(agent, cwd: cwd)
            ),
        ]
        showAgentPicker = true
    }

    /// 处理 alert 中的选项点击。
    func handleAgentPickerOption(_ option: AgentPickerOption) {
        showAgentPicker = false
        switch option.action {
        case .selectAgent(let agent):
            // 选好 agent，进入确认步骤
            selectedAgent = agent
            // 延迟一帧，避免 alert dismiss 动画冲突
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                // 编码代理需要先选择工作目录
                if agent.type.isCodingAgent {
                    self.pendingAgent = agent
                    let home = await self.resolveHomeDirectory()
                    self.browserPath = home
                    self.fetchDirectoryEntries(path: home)
                    self.showDirectoryBrowser = true
                } else {
                    self.showAgentConfirmationAlert(for: agent, cwd: nil)
                }
            }
        case .confirmConnection(let agent, let cwd):
            // 用户确认接入，通知外部进入直连模式
            taskCoordinator.resolveAgentConnection(for: serverID, with: .confirmed(cwd: cwd))
            onConfirmConnection(agent, cwd)
        case .cancel:
            cancelAgentPicker()
        }
    }

    /// 用户取消了 agent 连接选择弹窗。
    func cancelAgentPicker() {
        showAgentPicker = false
        taskCoordinator.resolveAgentConnection(for: serverID, with: .cancelled)
    }

    // MARK: - 目录浏览器

    /// 通过 SSHSessionManager 获取指定目录下的子目录列表。
    func fetchDirectoryEntries(path: String) {
        browserLoading = true
        Task {
            do {
                let entries = try await sshManager.listDirectory(path: path, serverID: server.id)
                self.browserEntries = entries
                self.browserPath = path
            } catch {
                self.browserPath = path
                self.browserEntries = []
            }
            self.browserLoading = false
        }
    }

    /// 进入目录浏览器中的子目录。
    func browseIntoDirectory(_ name: String) {
        let newPath = browserPath.hasSuffix("/")
            ? browserPath + name
            : browserPath + "/" + name
        fetchDirectoryEntries(path: newPath)
    }

    /// 返回目录浏览器的上级目录。
    func browseParentDirectory() {
        guard browserPath != "/" else { return }
        let parent = (browserPath as NSString).deletingLastPathComponent
        fetchDirectoryEntries(path: parent)
    }

    /// 用户在目录浏览器中确认选择当前路径。
    func confirmDirectorySelection() {
        let selectedPath = browserPath
        let agent = pendingAgent
        showDirectoryBrowser = false
        pendingAgent = nil
        browserEntries = []

        guard let agent else {
            taskCoordinator.resolveAgentConnection(for: serverID, with: .cancelled)
            return
        }
        showAgentConfirmationAlert(for: agent, cwd: selectedPath)
    }

    /// 用户在目录浏览器中选择"自定义路径"。
    func requestCustomPath() {
        showDirectoryBrowser = false
        pendingAgent = nil
        browserEntries = []
        taskCoordinator.resolveAgentConnection(for: serverID, with: .customPath)
    }

    /// 用户取消目录浏览器。
    func cancelDirectoryBrowser() {
        showDirectoryBrowser = false
        pendingAgent = nil
        browserEntries = []
        taskCoordinator.resolveAgentConnection(for: serverID, with: .cancelled)
    }

    /// 通过 SSHSessionManager 探测远端 home 目录。
    func resolveHomeDirectory() async -> String {
        do {
            return try await sshManager.resolveHomeDirectory(serverID: server.id)
        } catch {
            return "/"
        }
    }

}
