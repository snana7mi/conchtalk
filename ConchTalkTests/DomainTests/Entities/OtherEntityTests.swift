/// 文件说明：OtherEntityTests，测试 SSHKey、Memory、ToolError、SSHCommand、SafetyLevel 等实体。
import Testing
@testable import ConchTalk
import Foundation

// MARK: - SSHKey

@Suite("SSHKey Entity")
struct SSHKeyTests {

    // MARK: - 基本属性

    @Test("基本属性：id、label、keyType、fingerprint、publicKeyOpenSSH、source 正确存储")
    func basicProperties() {
        let id = UUID()
        let createdAt = Date()
        let key = SSHKey(
            id: id,
            label: "My Server Key",
            keyType: .ed25519,
            fingerprint: "SHA256:abcdef",
            publicKeyOpenSSH: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest",
            createdAt: createdAt,
            source: .generated
        )
        #expect(key.id == id)
        #expect(key.label == "My Server Key")
        #expect(key.keyType == .ed25519)
        #expect(key.fingerprint == "SHA256:abcdef")
        #expect(key.publicKeyOpenSSH == "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest")
        #expect(key.source == .generated)
    }

    // MARK: - KeyType displayName

    @Test("KeyType.ed25519 displayName 非空")
    func ed25519DisplayName() {
        #expect(!SSHKey.KeyType.ed25519.displayName.isEmpty)
    }

    @Test("KeyType.rsa4096 displayName 非空")
    func rsa4096DisplayName() {
        #expect(!SSHKey.KeyType.rsa4096.displayName.isEmpty)
    }

    @Test("KeyType.ecdsaP256 displayName 非空")
    func ecdsaP256DisplayName() {
        #expect(!SSHKey.KeyType.ecdsaP256.displayName.isEmpty)
    }

    @Test("KeyType.unknown displayName 非空")
    func unknownDisplayName() {
        #expect(!SSHKey.KeyType.unknown.displayName.isEmpty)
    }

    @Test("所有 KeyType case 的 displayName 均非空")
    func allKeyTypesHaveDisplayName() {
        for keyType in SSHKey.KeyType.allCases {
            #expect(!keyType.displayName.isEmpty, "KeyType.\(keyType) displayName 为空")
        }
    }

    // MARK: - Codable 往返

    @Test("Codable 往返：编码后解码，属性值完整保留")
    func codableRoundTrip() throws {
        let original = TestFixtures.makeSSHKey(
            label: "Roundtrip Key",
            keyType: .rsa4096,
            fingerprint: "SHA256:roundtrip",
            source: .imported
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHKey.self, from: encoded)
        #expect(decoded.id == original.id)
        #expect(decoded.label == original.label)
        #expect(decoded.keyType == original.keyType)
        #expect(decoded.fingerprint == original.fingerprint)
        #expect(decoded.publicKeyOpenSSH == original.publicKeyOpenSSH)
        #expect(decoded.source == original.source)
    }

    // MARK: - KeySource

    @Test("KeySource.generated 与 .imported 不相等")
    func keySourceDistinct() {
        let generated = SSHKey.KeySource.generated
        let imported = SSHKey.KeySource.imported
        #expect(generated != imported)
    }
}

// MARK: - Memory

@Suite("Memory Entity")
struct MemoryTests {

    // MARK: - 基本属性

    @Test("基本属性：id、serverID、content、updatedAt 正确存储")
    func basicProperties() {
        let id = UUID()
        let serverID = UUID()
        let updatedAt = Date()
        let memory = Memory(
            id: id,
            serverID: serverID,
            content: "server memory content",
            updatedAt: updatedAt
        )
        #expect(memory.id == id)
        #expect(memory.serverID == serverID)
        #expect(memory.content == "server memory content")
        #expect(memory.updatedAt == updatedAt)
    }

    @Test("默认 init 生成唯一 ID")
    func defaultInitGeneratesUniqueID() {
        let m1 = Memory(serverID: UUID(), content: "a")
        let m2 = Memory(serverID: UUID(), content: "b")
        #expect(m1.id != m2.id)
    }
}

// MARK: - ToolError

@Suite("ToolError Entity")
struct ToolErrorTests {

    @Test("toolNotFound：errorDescription 包含工具名称")
    func toolNotFoundDescription() {
        let err = ToolError.toolNotFound("my_tool")
        #expect(err.errorDescription != nil)
        #expect(!err.errorDescription!.isEmpty)
        #expect(err.errorDescription!.contains("my_tool"))
    }

    @Test("invalidArguments：errorDescription 包含错误详情")
    func invalidArgumentsDescription() {
        let err = ToolError.invalidArguments("missing field")
        #expect(err.errorDescription != nil)
        #expect(!err.errorDescription!.isEmpty)
        #expect(err.errorDescription!.contains("missing field"))
    }

    @Test("executionFailed：errorDescription 包含失败详情")
    func executionFailedDescription() {
        let err = ToolError.executionFailed("connection refused")
        #expect(err.errorDescription != nil)
        #expect(!err.errorDescription!.isEmpty)
        #expect(err.errorDescription!.contains("connection refused"))
    }

    @Test("missingParameter：errorDescription 包含参数名称")
    func missingParameterDescription() {
        let err = ToolError.missingParameter("command")
        #expect(err.errorDescription != nil)
        #expect(!err.errorDescription!.isEmpty)
        #expect(err.errorDescription!.contains("command"))
    }
}

// MARK: - SSHCommand

@Suite("SSHCommand Entity")
struct SSHCommandTests {

    // MARK: - Codable 往返

    @Test("Codable 往返：command、explanation、isDestructive 正确保留")
    func codableRoundTrip() throws {
        let original = SSHCommand(
            command: "rm -rf /tmp/test",
            explanation: "删除临时测试目录",
            isDestructive: true
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SSHCommand.self, from: encoded)
        #expect(decoded.command == original.command)
        #expect(decoded.explanation == original.explanation)
        #expect(decoded.isDestructive == original.isDestructive)
    }

    // MARK: - snake_case CodingKeys

    @Test("CodingKeys：isDestructive 使用 snake_case 键 'is_destructive'")
    func snakeCaseCodingKey() throws {
        let cmd = SSHCommand(command: "ls", explanation: "list", isDestructive: false)
        let encoded = try JSONEncoder().encode(cmd)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        // 验证 JSON 中使用了 snake_case 键
        #expect(json["is_destructive"] != nil)
        // 驼峰键不应存在
        #expect(json["isDestructive"] == nil)
    }

    @Test("CodingKeys：command 和 explanation 键名不变")
    func standardCodingKeys() throws {
        let cmd = SSHCommand(command: "echo hi", explanation: "say hi", isDestructive: false)
        let encoded = try JSONEncoder().encode(cmd)
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(json["command"] as? String == "echo hi")
        #expect(json["explanation"] as? String == "say hi")
    }

    @Test("非破坏性命令：isDestructive 为 false")
    func nonDestructiveCommand() throws {
        let cmd = SSHCommand(command: "ls -la", explanation: "列出文件", isDestructive: false)
        let encoded = try JSONEncoder().encode(cmd)
        let decoded = try JSONDecoder().decode(SSHCommand.self, from: encoded)
        #expect(decoded.isDestructive == false)
    }
}

// MARK: - SafetyLevel & PermissionLevel

@Suite("SafetyLevel & PermissionLevel")
struct SafetyPermissionTests {

    // MARK: - strict 映射

    @Test("strict: safe → needsConfirmation")
    func strictSafeBecomesConfirmation() {
        let level = PermissionLevel.strict
        let result = level.effectiveSafetyLevel(.safe)
        #expect(result == .needsConfirmation)
    }

    @Test("strict: needsConfirmation → needsConfirmation（不变）")
    func strictConfirmationStays() {
        let level = PermissionLevel.strict
        let result = level.effectiveSafetyLevel(.needsConfirmation)
        #expect(result == .needsConfirmation)
    }

    @Test("strict: forbidden → forbidden")
    func strictForbiddenStays() {
        let level = PermissionLevel.strict
        let result = level.effectiveSafetyLevel(.forbidden)
        #expect(result == .forbidden)
    }

    // MARK: - standard 透传

    @Test("standard: safe → safe（透传）")
    func standardSafePassthrough() {
        let level = PermissionLevel.standard
        #expect(level.effectiveSafetyLevel(.safe) == .safe)
    }

    @Test("standard: needsConfirmation → needsConfirmation（透传）")
    func standardConfirmationPassthrough() {
        let level = PermissionLevel.standard
        #expect(level.effectiveSafetyLevel(.needsConfirmation) == .needsConfirmation)
    }

    @Test("standard: forbidden → forbidden（透传）")
    func standardForbiddenPassthrough() {
        let level = PermissionLevel.standard
        #expect(level.effectiveSafetyLevel(.forbidden) == .forbidden)
    }

    // MARK: - permissive 宽松

    @Test("permissive: safe → safe（不变）")
    func permissiveSafeStays() {
        let level = PermissionLevel.permissive
        #expect(level.effectiveSafetyLevel(.safe) == .safe)
    }

    @Test("permissive: needsConfirmation → safe（自动放行）")
    func permissiveConfirmationBecomeSafe() {
        let level = PermissionLevel.permissive
        let result = level.effectiveSafetyLevel(.needsConfirmation)
        #expect(result == .safe)
    }

    @Test("permissive: forbidden → needsConfirmation（降级为确认而非禁止）")
    func permissiveForbiddenBecomesConfirmation() {
        let level = PermissionLevel.permissive
        let result = level.effectiveSafetyLevel(.forbidden)
        #expect(result == .needsConfirmation)
    }

    // MARK: - forbidden 恒保持（strict / standard）

    @Test("forbidden 在 strict 下保持 forbidden")
    func forbiddenAlwaysForbiddenUnderStrict() {
        #expect(PermissionLevel.strict.effectiveSafetyLevel(.forbidden) == .forbidden)
    }

    @Test("forbidden 在 standard 下保持 forbidden")
    func forbiddenAlwaysForbiddenUnderStandard() {
        #expect(PermissionLevel.standard.effectiveSafetyLevel(.forbidden) == .forbidden)
    }

    // MARK: - ServerPermissionLevel.followGlobal

    @Test("followGlobal 解析为全局 strict")
    func followGlobalResolvesToStrict() {
        let server = ServerPermissionLevel.followGlobal
        #expect(server.resolved(globalLevel: .strict) == .strict)
    }

    @Test("followGlobal 解析为全局 standard")
    func followGlobalResolvesToStandard() {
        let server = ServerPermissionLevel.followGlobal
        #expect(server.resolved(globalLevel: .standard) == .standard)
    }

    @Test("followGlobal 解析为全局 permissive")
    func followGlobalResolvesToPermissive() {
        let server = ServerPermissionLevel.followGlobal
        #expect(server.resolved(globalLevel: .permissive) == .permissive)
    }

    // MARK: - ServerPermissionLevel 显式覆盖全局

    @Test("显式 strict 覆盖全局 permissive")
    func explicitStrictOverridesGlobal() {
        let server = ServerPermissionLevel.strict
        #expect(server.resolved(globalLevel: .permissive) == .strict)
    }

    @Test("显式 permissive 覆盖全局 strict")
    func explicitPermissiveOverridesGlobal() {
        let server = ServerPermissionLevel.permissive
        #expect(server.resolved(globalLevel: .strict) == .permissive)
    }

    @Test("显式 standard 覆盖全局 permissive")
    func explicitStandardOverridesGlobal() {
        let server = ServerPermissionLevel.standard
        #expect(server.resolved(globalLevel: .permissive) == .standard)
    }
}
