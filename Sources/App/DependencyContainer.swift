/// 文件说明：DependencyContainer，负责应用级依赖装配与对象创建。
import Foundation
import SwiftData

/// DependencyContainer：集中装配应用运行所需依赖并提供工厂方法。
@Observable
final class DependencyContainer {
    let modelContainer: ModelContainer
    let store: SwiftDataStore
    let sshManager: SSHSessionManager
    let keychainService: KeychainService
    let aiService: AIProxyService
    let toolRegistry: ToolRegistry

    /// 初始化依赖容器，并装配应用运行所需组件。
    init() {
        // SwiftData
        let schema = Schema([
            ServerModel.self,
            ConversationModel.self,
            MessageModel.self,
            ServerGroupModel.self,
        ])
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false
        )

        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        self.store = SwiftDataStore(modelContainer: modelContainer)

        // Tool Registry
        self.toolRegistry = ToolRegistry(tools: [
            ExecuteSSHCommandTool(),
            ReadFileTool(),
            WriteFileTool(),
            ListDirectoryTool(),
            GetSystemInfoTool(),
            GetProcessListTool(),
            GetNetworkStatusTool(),
            ManageServiceTool(),
            SFTPReadFileTool(),
            SFTPWriteFileTool(),
        ])

        // Services
        self.sshManager = SSHSessionManager()
        self.keychainService = KeychainService()
        self.aiService = AIProxyService(keychainService: keychainService, toolRegistry: toolRegistry)
    }

    /// makeChatViewModel：构建聊天页面所需的视图模型实例。
    func makeChatViewModel(for server: Server, conversationID: UUID? = nil) -> ChatViewModel {
        ChatViewModel(
            server: server,
            conversationID: conversationID,
            store: store,
            sshManager: sshManager,
            aiService: aiService,
            toolRegistry: toolRegistry,
            keychainService: keychainService
        )
    }

    /// makeServerListViewModel：构建服务器列表页面的视图模型实例。
    func makeServerListViewModel() -> ServerListViewModel {
        ServerListViewModel(store: store)
    }
}
