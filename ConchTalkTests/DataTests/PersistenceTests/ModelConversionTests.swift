/// 文件说明：ModelConversionTests，测试 SwiftData 模型与领域实体之间的双向转换正确性。
import Testing
@testable import ConchTalk
import Foundation

// MARK: - ServerModel

@Suite("ServerModel Conversion")
struct ServerModelConversionTests {

    @Test("password auth round-trip")
    func passwordAuthRoundTrip() {
        let original = TestFixtures.makeServer(
            id: UUID(),
            name: "My Server",
            host: "10.0.0.1",
            port: 2222,
            username: "admin",
            authMethod: .password
        )
        let model = ServerModel.fromDomain(original)
        let restored = model.toDomain()

        #expect(restored.id == original.id)
        #expect(restored.name == original.name)
        #expect(restored.host == original.host)
        #expect(restored.port == original.port)
        #expect(restored.username == original.username)
        #expect(restored.authMethod == original.authMethod)
        #expect(model.authMethodRaw == "password")
    }

    @Test("privateKey auth round-trip")
    func privateKeyAuthRoundTrip() {
        let keyID = UUID().uuidString
        let original = TestFixtures.makeServer(
            authMethod: .privateKey(keyID: keyID)
        )
        let model = ServerModel.fromDomain(original)
        let restored = model.toDomain()

        #expect(model.authMethodRaw == "privateKey:\(keyID)")
        guard case .privateKey(let restoredKeyID) = restored.authMethod else {
            #expect(Bool(false), "Expected privateKey auth method")
            return
        }
        #expect(restoredKeyID == keyID)
    }

    @Test("ServerPermissionLevel round-trip", arguments: ServerPermissionLevel.allCases)
    func permissionLevelRoundTrip(level: ServerPermissionLevel) {
        let original = TestFixtures.makeServer(permissionLevel: level)
        let model = ServerModel.fromDomain(original)
        let restored = model.toDomain()

        #expect(restored.permissionLevel == level)
        #expect(model.permissionLevelRaw == level.rawValue)
    }

}

// MARK: - SystemProfileModel

@Suite("SystemProfileModel Conversion")
struct SystemProfileModelConversionTests {
    @Test("system profile round-trip")
    func systemProfileRoundTrip() throws {
        let now = Date()
        let original = SystemProfile(
            serverID: UUID(),
            detectedAt: now,
            osInfo: "Linux test-host 6.8.0",
            packageManager: "apt",
            installedTools: [
                .init(name: "tmux", available: true, version: "tmux 3.4", path: "/usr/bin/tmux"),
                .init(name: "jq", available: false, version: nil, path: nil),
            ]
        )

        let model = try SystemProfileModel.fromDomain(original)
        let restored = try model.toDomain()

        #expect(restored.serverID == original.serverID)
        #expect(restored.detectedAt == original.detectedAt)
        #expect(restored.osInfo == original.osInfo)
        #expect(restored.packageManager == original.packageManager)
        #expect(restored.installedTools.count == original.installedTools.count)
        #expect(restored.installedTools[0].name == "tmux")
        #expect(restored.installedTools[1].name == "jq")
    }

    @Test("invalid tools JSON throws decode error")
    func invalidToolsJSONThrows() {
        let model = SystemProfileModel(
            serverID: UUID(),
            osInfo: "Linux",
            packageManager: "apt",
            toolsJSON: "{invalid-json}",
            detectedAt: Date()
        )

        #expect(throws: SystemProfileModelError.self) {
            _ = try model.toDomain()
        }
    }
}

// MARK: - MessageModel

@Suite("MessageModel Conversion")
struct MessageModelConversionTests {
    private let serverID = UUID()

    @Test("user message round-trip")
    func userMessageRoundTrip() {
        let original = TestFixtures.makeMessage(
            role: .user,
            content: "Hello, world!"
        )
        let model = MessageModel.fromDomain(original, serverID: serverID)
        let restored = model.toDomain()

        #expect(restored.id == original.id)
        #expect(restored.role == original.role)
        #expect(restored.content == original.content)
        #expect(restored.toolCall == nil)
        #expect(restored.toolOutput == nil)
    }

    @Test("assistant message with reasoning round-trip")
    func assistantWithReasoningRoundTrip() {
        let original = TestFixtures.makeMessage(
            role: .assistant,
            content: "Based on my analysis...",
            reasoningContent: "Let me think step by step..."
        )
        let model = MessageModel.fromDomain(original, serverID: serverID)
        let restored = model.toDomain()

        #expect(restored.role == .assistant)
        #expect(restored.content == original.content)
        #expect(restored.reasoningContent == original.reasoningContent)
    }

    @Test("command message with toolCall round-trip")
    func commandWithToolCallRoundTrip() {
        let toolCall = TestFixtures.makeToolCall(
            id: "call_abc123",
            toolName: "execute_ssh_command",
            arguments: ["command": "ls -la"],
            explanation: "List directory contents"
        )
        let original = TestFixtures.makeMessage(
            role: .command,
            content: "",
            toolCall: toolCall,
            toolOutput: "total 8\ndrwxr-xr-x 2 root root"
        )
        let model = MessageModel.fromDomain(original, serverID: serverID)
        let restored = model.toDomain()

        #expect(restored.role == .command)
        #expect(restored.toolOutput == original.toolOutput)
        #expect(restored.toolCall?.id == toolCall.id)
        #expect(restored.toolCall?.toolName == toolCall.toolName)
    }

    @Test("system message type round-trip")
    func systemMessageTypeRoundTrip() {
        let original = TestFixtures.makeMessage(
            role: .system,
            content: "Connected to server",
            systemMessageType: .connected
        )
        let model = MessageModel.fromDomain(original, serverID: serverID)
        let restored = model.toDomain()

        #expect(restored.role == .system)
        #expect(restored.systemMessageType == .connected)
        #expect(model.systemMessageTypeRaw == "connected")
    }
}

// MARK: - SSHKeyModel

@Suite("SSHKeyModel Conversion")
struct SSHKeyModelConversionTests {

    @Test("all KeyType cases round-trip", arguments: SSHKey.KeyType.allCases)
    func keyTypeRoundTrip(keyType: SSHKey.KeyType) {
        let original = TestFixtures.makeSSHKey(keyType: keyType)
        let model = SSHKeyModel.fromDomain(original)
        let restored = model.toDomain()

        #expect(restored.id == original.id)
        #expect(restored.keyType == keyType)
        #expect(model.keyTypeRaw == keyType.rawValue)
    }

    @Test("generated KeySource round-trip")
    func generatedKeySourceRoundTrip() {
        let original = TestFixtures.makeSSHKey(source: .generated)
        let model = SSHKeyModel.fromDomain(original)
        let restored = model.toDomain()

        #expect(restored.source == .generated)
        #expect(model.sourceRaw == "generated")
    }

    @Test("imported KeySource round-trip")
    func importedKeySourceRoundTrip() {
        let original = TestFixtures.makeSSHKey(source: .imported)
        let model = SSHKeyModel.fromDomain(original)
        let restored = model.toDomain()

        #expect(restored.source == .imported)
        #expect(model.sourceRaw == "imported")
    }
}

// MARK: - MemoryModel

@Suite("MemoryModel Conversion")
struct MemoryModelConversionTests {

    @Test("memory round-trip")
    func memoryRoundTrip() {
        let serverID = UUID()
        let original = TestFixtures.makeMemory(serverID: serverID, content: "Server runs Ubuntu 24.04")
        let model = MemoryModel.fromDomain(original)
        let restored = model.toDomain()

        #expect(restored.id == original.id)
        #expect(restored.serverID == original.serverID)
        #expect(restored.content == original.content)
    }

    @Test("memory model stores serverID correctly")
    func memoryModelServerIDField() {
        let serverID = UUID()
        let memory = TestFixtures.makeMemory(serverID: serverID)
        let model = MemoryModel.fromDomain(memory)

        #expect(model.serverID == serverID)
    }
}
