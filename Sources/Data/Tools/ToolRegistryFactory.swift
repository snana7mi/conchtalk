/// 文件说明：ToolRegistryFactory，统一构建基础工具与任务级工具注册表。
import Foundation

/// ToolRegistryFactory：
/// 将应用启动时的基础工具注册和任务执行时的上下文工具注入收敛到同一入口，
/// 避免工具组装逻辑分散在多个模块中。
nonisolated enum ToolRegistryFactory {
    typealias MemoryToolService = any MemoryReader & MemoryWriter & MemoryEntryStore

    /// 构建应用级基础工具列表。
    /// authService 非 nil 时注入 WebSearchTool（云端代理模式）。
    static func makeBaseTools(
        skillRegistry: SkillRegistry,
        authService: AuthServiceProtocol? = nil,
        subagentSummaries: String = ""
    ) -> [ToolProtocol] {
        var tools: [ToolProtocol] = [
            ExecuteSSHCommandTool(),
            ReadFileTool(),
            WriteFileTool(),
            EditFileTool(),
            GlobTool(),
            GrepTool(),
            UploadFileTool(),
            WebFetchTool(),
            SuggestAgentConnectionTool(),
            ActivateSkillTool(skillRegistry: skillRegistry),
            DispatchSubagentTool(subagentSummaries: subagentSummaries),
        ]

        // 云端代理模式：注入 WebSearchTool
        if let authService {
            tools.append(WebSearchTool(authService: authService))
        }

        return tools
    }

    /// 基于基础工具构建应用级注册表。
    static func makeBaseRegistry(
        skillRegistry: SkillRegistry,
        authService: AuthServiceProtocol? = nil,
        subagentSummaries: String = ""
    ) -> ToolRegistry {
        ToolRegistry(tools: makeBaseTools(
            skillRegistry: skillRegistry,
            authService: authService,
            subagentSummaries: subagentSummaries
        ))
    }

    /// 构建任务级注册表，按需注入当前服务器的记忆读写工具。
    static func makeTaskRegistry(
        baseTools: [ToolProtocol],
        serverID: UUID,
        memoryService: MemoryToolService?
    ) -> ToolRegistry {
        guard let memoryService else {
            return ToolRegistry(tools: baseTools)
        }

        let memoryTools: [ToolProtocol] = [
            MemoryReadTool(serverID: serverID, memoryReader: memoryService, entryStore: memoryService),
            MemoryWriteTool(serverID: serverID, memoryWriter: memoryService, entryStore: memoryService),
        ]
        return ToolRegistry(tools: baseTools + memoryTools)
    }
}
