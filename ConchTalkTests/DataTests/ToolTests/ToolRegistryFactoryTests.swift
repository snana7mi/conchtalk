/// 文件说明：ToolRegistryFactoryTests，验证基础工具与任务级工具注册的一致性。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ToolRegistryFactory")
struct ToolRegistryFactoryTests {
    private actor MemoryToolServiceStub: MemoryReader, MemoryWriter, MemoryEntryStore {
        func fetchMemory(forServer serverID: UUID) async throws -> String? { nil }
        func upsertMemory(_ memory: Memory) async throws {}
        func deleteMemory(forServer serverID: UUID) async throws {}
        func addMemoryEntry(_ entry: MemoryEntry) async throws {}
        func fetchMemoryEntries(forServer serverID: UUID) async throws -> [MemoryEntry] { [] }
        func deleteMemoryEntries(_ entryIDs: [UUID]) async throws {}
        func memoryEntryCount(forServer serverID: UUID) async throws -> Int { 0 }
    }

    @Test("task registry appends memory tools only when task context exists")
    func taskRegistryAddsMemoryToolsOnlyForServerScopedTask() {
        let baseTools: [any ToolProtocol] = [
            ReadFileTool(),
            WriteFileTool(),
        ]
        let memoryService = MemoryToolServiceStub()

        let withoutMemory = ToolRegistryFactory.makeTaskRegistry(
            baseTools: baseTools,
            serverID: UUID(),
            memoryService: nil
        )
        #expect(withoutMemory.tools.count == 2)
        #expect(withoutMemory.tool(named: "memory_read") == nil)
        #expect(withoutMemory.tool(named: "memory_write") == nil)

        let withMemory = ToolRegistryFactory.makeTaskRegistry(
            baseTools: baseTools,
            serverID: UUID(),
            memoryService: memoryService
        )
        #expect(withMemory.tools.count == 4)
        #expect(withMemory.tool(named: "memory_read") != nil)
        #expect(withMemory.tool(named: "memory_write") != nil)
    }

    @Test("base tools 注册用户自有 Brave web_search")
    func baseToolsIncludeUserOwnedWebSearch() {
        let tools = ToolRegistryFactory.makeBaseTools(
            skillRegistry: SkillRegistry(preloaded: []),
            keychainService: MockKeychainService()
        )
        let hasWebSearch = tools.contains { $0.name == "web_search" }
        #expect(hasWebSearch)
    }
}
