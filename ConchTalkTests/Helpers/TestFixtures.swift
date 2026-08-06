/// 文件说明：TestFixtures，提供测试数据工厂方法，集中管理测试实体创建。
@testable import ConchTalk
import Foundation

/// TestFixtures：
/// 测试数据工厂，提供各领域实体的便捷创建方法，所有参数均有合理默认值。
enum TestFixtures {

    // MARK: - Server

    static func makeServer(
        id: UUID = UUID(),
        name: String = "Test Server",
        host: String = "192.168.1.100",
        port: Int = 22,
        username: String = "root",
        authMethod: Server.AuthMethod = .password,
        permissionLevel: ServerPermissionLevel = .followGlobal
    ) -> Server {
        Server(
            id: id,
            name: name,
            host: host,
            port: port,
            username: username,
            authMethod: authMethod,
            permissionLevel: permissionLevel
        )
    }

    // MARK: - Message

    static func makeMessage(
        id: UUID = UUID(),
        role: Message.MessageRole = .user,
        content: String = "Test message",
        timestamp: Date = Date(),
        toolCall: ToolCall? = nil,
        toolOutput: String? = nil,
        reasoningContent: String? = nil,
        systemMessageType: Message.SystemMessageType? = nil,
        isLoading: Bool = false,
        source: MessageSource? = nil
    ) -> Message {
        Message(
            id: id,
            role: role,
            content: content,
            timestamp: timestamp,
            toolCall: toolCall,
            toolOutput: toolOutput,
            reasoningContent: reasoningContent,
            systemMessageType: systemMessageType,
            isLoading: isLoading,
            source: source
        )
    }

    // MARK: - ToolCall

    static func makeToolCall(
        id: String = "call_test_123",
        toolName: String = "execute_ssh_command",
        arguments: [String: Any] = ["command": "ls -la"],
        explanation: String = "List directory contents"
    ) -> ToolCall {
        precondition(
            JSONSerialization.isValidJSONObject(arguments),
            "TestFixtures.makeToolCall received non-JSON arguments: \(arguments)"
        )
        let argumentsJSON: Data
        do {
            argumentsJSON = try JSONSerialization.data(withJSONObject: arguments)
        } catch {
            preconditionFailure("TestFixtures.makeToolCall failed to encode arguments: \(error)")
        }
        return ToolCall(
            id: id,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            explanation: explanation
        )
    }

    // MARK: - SSHKey

    static func makeSSHKey(
        id: UUID = UUID(),
        label: String = "Test Key",
        keyType: SSHKey.KeyType = .ed25519,
        fingerprint: String = "SHA256:testfingerprint",
        publicKeyOpenSSH: String = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest",
        createdAt: Date = Date(),
        source: SSHKey.KeySource = .generated
    ) -> SSHKey {
        SSHKey(
            id: id,
            label: label,
            keyType: keyType,
            fingerprint: fingerprint,
            publicKeyOpenSSH: publicKeyOpenSSH,
            createdAt: createdAt,
            source: source
        )
    }

    // MARK: - Memory

    static func makeMemory(
        id: UUID = UUID(),
        serverID: UUID = UUID(),
        content: String = "Test memory content",
        updatedAt: Date = Date()
    ) -> Memory {
        Memory(
            id: id,
            serverID: serverID,
            content: content,
            updatedAt: updatedAt
        )
    }

    // MARK: - FileAttachment

    static func makeFileAttachment(
        id: UUID = UUID(),
        fileName: String = "test.txt",
        fileSize: Int64? = nil,
        mimeType: String = "text/plain",
        content: Data? = nil
    ) -> FileAttachment {
        let data = content ?? Data("test file content".utf8)
        let size = fileSize ?? Int64(data.count)
        return FileAttachment(
            id: id,
            fileName: fileName,
            fileSize: size,
            mimeType: mimeType,
            data: data
        )
    }

    // MARK: - ToolExecutionResult

    static func makeToolExecutionResult(
        output: String = "command output",
        isSuccess: Bool = true
    ) -> ToolExecutionResult {
        ToolExecutionResult(output: output, isSuccess: isSuccess)
    }

    // MARK: - ServerCapabilities

    static func makeServerCapabilities() -> ServerCapabilities {
        ServerCapabilities()
    }
}
