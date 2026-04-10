/// 文件说明：ExecuteSSHCommandToolTests，测试 ExecuteSSHCommandTool 的安全分级与执行行为。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ExecuteSSHCommandTool")
struct ExecuteSSHCommandToolTests {

    // MARK: - 辅助属性

    private let sut = ExecuteSSHCommandTool()

    private func args(command: String, isDestructive: Bool = false, explanation: String = "test") -> [String: Any] {
        ["command": command, "is_destructive": isDestructive, "explanation": explanation]
    }

    // MARK: - Forbidden 禁止级别测试

    @Suite("Forbidden patterns")
    struct ForbiddenTests {

        private let sut = ExecuteSSHCommandTool()

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("rm -rf / is forbidden")
        func rmRfRoot() {
            #expect(sut.validateSafety(arguments: args(command: "rm -rf /")) == .forbidden)
        }

        @Test("rm -fr / is forbidden")
        func rmFrRoot() {
            #expect(sut.validateSafety(arguments: args(command: "rm -fr /")) == .forbidden)
        }

        @Test("sudo rm -rf / is forbidden")
        func sudoRmRfRoot() {
            #expect(sut.validateSafety(arguments: args(command: "sudo rm -rf /")) == .forbidden)
        }

        @Test("mkfs.ext4 /dev/sda1 is forbidden")
        func mkfsExt4() {
            #expect(sut.validateSafety(arguments: args(command: "mkfs.ext4 /dev/sda1")) == .forbidden)
        }

        @Test("dd if=/dev/zero of=/dev/sda is forbidden")
        func ddZero() {
            #expect(sut.validateSafety(arguments: args(command: "dd if=/dev/zero of=/dev/sda")) == .forbidden)
        }

        @Test("chmod -R 777 / is forbidden")
        func chmodR777Root() {
            #expect(sut.validateSafety(arguments: args(command: "chmod -R 777 /")) == .forbidden)
        }
    }

    // MARK: - Safe 安全级别测试

    @Suite("Safe commands")
    struct SafeTests {

        private let sut = ExecuteSSHCommandTool()

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("ls is safe")
        func ls() {
            #expect(sut.validateSafety(arguments: args(command: "ls")) == .safe)
        }

        @Test("ls -la is safe")
        func lsLa() {
            #expect(sut.validateSafety(arguments: args(command: "ls -la")) == .safe)
        }

        @Test("ls /tmp is safe")
        func lsTmp() {
            #expect(sut.validateSafety(arguments: args(command: "ls /tmp")) == .safe)
        }

        @Test("cat /etc/hosts is safe")
        func catHosts() {
            #expect(sut.validateSafety(arguments: args(command: "cat /etc/hosts")) == .safe)
        }

        @Test("ps aux is safe")
        func psAux() {
            #expect(sut.validateSafety(arguments: args(command: "ps aux")) == .safe)
        }

        @Test("df -h is safe")
        func dfH() {
            #expect(sut.validateSafety(arguments: args(command: "df -h")) == .safe)
        }

        @Test("free -m is safe")
        func freeM() {
            #expect(sut.validateSafety(arguments: args(command: "free -m")) == .safe)
        }

        @Test("git status is safe")
        func gitStatus() {
            #expect(sut.validateSafety(arguments: args(command: "git status")) == .safe)
        }
    }

    // MARK: - NeedsConfirmation 需要确认级别测试

    @Suite("NeedsConfirmation commands")
    struct NeedsConfirmationTests {

        private let sut = ExecuteSSHCommandTool()

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("apt install nginx needs confirmation")
        func aptInstall() {
            #expect(sut.validateSafety(arguments: args(command: "apt install nginx")) == .needsConfirmation)
        }

        @Test("systemctl restart nginx needs confirmation")
        func systemctlRestart() {
            #expect(sut.validateSafety(arguments: args(command: "systemctl restart nginx")) == .needsConfirmation)
        }

        @Test("find . piped to rm needs confirmation")
        func findPipedToRm() {
            #expect(sut.validateSafety(arguments: args(command: "find . | rm")) == .needsConfirmation)
        }

        @Test("echo redirecting to /etc/config needs confirmation")
        func echoRedirectToEtc() {
            #expect(sut.validateSafety(arguments: args(command: "echo test > /etc/config")) == .needsConfirmation)
        }
    }

    // MARK: - Execute 执行测试

    @Suite("Execute behavior")
    struct ExecuteTests {

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("Normal execution returns SSH output")
        func normalExecution() async throws {
            let sut = ExecuteSSHCommandTool()
            let mockClient = MockSSHClient()
            mockClient.executeResult = "file1\nfile2\n"

            let result = try await sut.execute(arguments: args(command: "ls"), sshClient: mockClient)

            #expect(result.isSuccess == true)
            #expect(result.output == "file1\nfile2\n")
            #expect(mockClient.executedCommands == ["ls"])
        }

        @Test("Missing command parameter throws ToolError")
        func missingCommandThrows() async {
            let sut = ExecuteSSHCommandTool()
            let mockClient = MockSSHClient()

            await #expect(throws: ToolError.self) {
                _ = try await sut.execute(arguments: [:], sshClient: mockClient)
            }
        }
    }

    // MARK: - 复合命令段检测回归测试

    @Suite("Compound command segment analysis")
    struct CompoundCommandTests {

        private let sut = ExecuteSSHCommandTool()

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("ls && systemctl restart nginx — 后段非安全命令不应被判定为 safe")
        func safeFirstDangerousSecondNeedsConfirmation() {
            #expect(sut.validateSafety(arguments: args(command: "ls && systemctl restart nginx")) == .needsConfirmation)
        }

        @Test("systemctl restart nginx && ls — 前段非安全命令不应被判定为 safe")
        func dangerousFirstSafeSecondNeedsConfirmation() {
            #expect(sut.validateSafety(arguments: args(command: "systemctl restart nginx && ls")) == .needsConfirmation)
        }

        @Test("ls && ps aux — 全安全段应判定为 safe")
        func allSafeSegments() {
            #expect(sut.validateSafety(arguments: args(command: "ls && ps aux")) == .safe)
        }

        @Test("cat /etc/hosts | grep localhost — 全安全段应判定为 safe")
        func safePipeChain() {
            #expect(sut.validateSafety(arguments: args(command: "cat /etc/hosts | grep localhost")) == .safe)
        }

        @Test("sudo ls — sudo 命令应需要确认")
        func sudoLsNeedsConfirmation() {
            #expect(sut.validateSafety(arguments: args(command: "sudo ls")) == .needsConfirmation)
        }
    }
}
