import Foundation
import SwiftData

@Observable
final class DependencyContainer {
    let modelContainer: ModelContainer
    let store: SwiftDataStore
    let sshManager: SSHSessionManager
    let keychainService: KeychainService
    let aiService: AIProxyService
    let toolRegistry: ToolRegistry

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
        ])

        // Services
        self.sshManager = SSHSessionManager()
        self.keychainService = KeychainService()
        self.aiService = AIProxyService(keychainService: keychainService, toolRegistry: toolRegistry)
    }

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

    func makeServerListViewModel() -> ServerListViewModel {
        ServerListViewModel(store: store)
    }
}
