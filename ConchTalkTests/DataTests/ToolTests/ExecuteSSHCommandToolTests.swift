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
            #expect(mockClient.callHistory.last?.arguments["reclaimOnTimeout"] == "true")
            #expect(Double(mockClient.callHistory.last?.arguments["timeout"] ?? "") == 30)
        }

        @Test("timeout 被夹到 1...600 秒")
        func timeoutIsClamped() async throws {
            let sut = ExecuteSSHCommandTool()
            let high = MockSSHClient()
            _ = try await sut.execute(
                arguments: ["command": "sleep 1", "is_destructive": false, "explanation": "test", "timeout": 5_000],
                sshClient: high
            )
            #expect(Double(high.callHistory.last?.arguments["timeout"] ?? "") == 600)

            let low = MockSSHClient()
            _ = try await sut.execute(
                arguments: ["command": "sleep 1", "is_destructive": false, "explanation": "test", "timeout": 0],
                sshClient: low
            )
            #expect(Double(low.callHistory.last?.arguments["timeout"] ?? "") == 1)
        }

        @Test("background 用 nohup 启动并立刻返回日志路径")
        func backgroundLaunch() async throws {
            let sut = ExecuteSSHCommandTool()
            let mockClient = MockSSHClient()
            mockClient.executeResult = "pid=42\nlog=/tmp/conchtalk-bg/x.log"

            let result = try await sut.execute(
                arguments: ["command": "echo hi", "is_destructive": false, "explanation": "test", "background": true],
                sshClient: mockClient
            )

            #expect(result.output.contains("log_path:"))
            #expect(result.output.contains("/tmp/conchtalk-bg/"))
            #expect(mockClient.executedCommands.first?.contains("nohup") == true)
            #expect(mockClient.executedCommands.first?.contains("setsid") == true)
            #expect(mockClient.callHistory.last?.arguments["reclaimOnTimeout"] == "false")
        }

        @Test("后台执行只读命令也要确认，禁止命令仍然禁止")
        func backgroundSafety() {
            let sut = ExecuteSSHCommandTool()
            #expect(sut.validateSafety(arguments: ["command": "ls", "is_destructive": false, "background": true]) == .needsConfirmation)
            #expect(sut.validateSafety(arguments: ["command": "rm -rf /", "is_destructive": true, "background": true]) == .forbidden)
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

    // MARK: - 白名单写重定向绕过测试

    @Suite("Whitelist write redirection bypass")
    struct WhitelistWriteRedirectionTests {

        private let sut = ExecuteSSHCommandTool()

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("echo 追加 authorized_keys 触发确认")
        func echoAppendAuthorizedKeys() {
            #expect(sut.validateSafety(arguments: args(command: "echo 'ssh-ed25519 AAAA attacker' >> ~/.ssh/authorized_keys")) == .needsConfirmation)
        }

        @Test("echo 覆写 .bashrc 触发确认")
        func echoOverwriteBashrc() {
            #expect(sut.validateSafety(arguments: args(command: "echo x > ~/.bashrc")) == .needsConfirmation)
        }

        @Test("printf 写 .profile 触发确认")
        func printfAppendProfile() {
            #expect(sut.validateSafety(arguments: args(command: "printf 'x' >> ~/.profile")) == .needsConfirmation)
        }

        @Test("重定向写 /tmp 脚本触发确认")
        func redirectToTmpScript() {
            #expect(sut.validateSafety(arguments: args(command: "echo x > /tmp/evil.sh")) == .needsConfirmation)
        }

        @Test("重定向写 /opt 触发确认")
        func redirectToOpt() {
            #expect(sut.validateSafety(arguments: args(command: "echo x >> /opt/app/run")) == .needsConfirmation)
        }

        @Test("管道读链末端重定向写文件触发确认")
        func pipeChainWithRedirect() {
            #expect(sut.validateSafety(arguments: args(command: "cat /etc/hosts | grep x > out.txt")) == .needsConfirmation)
        }

        @Test("tee 写文件触发确认（回归，确认仍拦）")
        func teeWrite() {
            #expect(sut.validateSafety(arguments: args(command: "echo x | tee ~/.bashrc")) == .needsConfirmation)
        }

        @Test("heredoc 触发确认")
        func heredoc() {
            let cmd = "cat > ~/.config/systemd/user/evil.service <<'EOF'\n[Service]\nEOF"
            #expect(sut.validateSafety(arguments: args(command: cmd)) == .needsConfirmation)
        }

        @Test("herestring 触发确认")
        func herestring() {
            #expect(sut.validateSafety(arguments: args(command: "cat <<< 'x' > ~/.bashrc")) == .needsConfirmation)
        }

        @Test("is_destructive=false 不能降低写命令风险")
        func isDestructiveFalseCannotLowerRisk() {
            let arguments = args(command: "echo 'k' >> ~/.ssh/authorized_keys", isDestructive: false)
            #expect(sut.validateSafety(arguments: arguments) == .needsConfirmation)
        }
    }

    // MARK: - 误报与回归守护测试

    @Suite("No false-positive / regression guards")
    struct NoFalsePositiveTests {

        private let sut = ExecuteSSHCommandTool()

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("纯读命令保持 safe", arguments: ["ls -la", "cat /etc/hosts"])
        func pureReadStaysSafe(command: String) {
            #expect(sut.validateSafety(arguments: args(command: command)) == .safe)
        }

        @Test("纯管道读链保持 safe")
        func pipeReadChainStaysSafe() {
            #expect(sut.validateSafety(arguments: args(command: "cat /etc/hosts | grep localhost")) == .safe)
        }

        @Test("2>/dev/null 维持 needsConfirmation（与现状一致，不豁免 /dev/null）")
        func devNullRedirectNeedsConfirmation() {
            #expect(sut.validateSafety(arguments: args(command: "ls 2>/dev/null")) == .needsConfirmation)
        }

        @Test("2>&1 维持 needsConfirmation（& 分段所致，pre-existing 行为）")
        func fdDupNeedsConfirmation() {
            #expect(sut.validateSafety(arguments: args(command: "ps aux 2>&1")) == .needsConfirmation)
        }
    }

    // MARK: - 包装器 / 子命令 / rm 边界

    @Suite("Wrapper and subcommand classification")
    struct WrapperAndSubcommandTests {
        private let sut = ExecuteSSHCommandTool()

        private func args(command: String, isDestructive: Bool = false) -> [String: Any] {
            ["command": command, "is_destructive": isDestructive, "explanation": "test"]
        }

        @Test("包装器不因首词在白名单而自动放行", arguments: [
            "env ls",
            "env rm -rf /tmp/build",
            "env sh -c 'ls'",
            "env sh -c 'rm -rf /tmp/build'",
            "sudo ls",
            "nohup ls",
            "xargs ls",
            "timeout 5 ls",
            "nice ls",
            "time ls",
            "command ls",
            "exec ls",
            "sh -c 'ls'",
            "bash -c 'rm -rf /tmp/build'",
        ])
        func wrapperNeedsConfirmation(command: String) {
            #expect(sut.validateSafety(arguments: args(command: command)) == .needsConfirmation, "应需要确认: \(command)")
        }

        @Test("没有子命令的 env 保持 safe")
        func bareEnvIsSafe() {
            #expect(sut.validateSafety(arguments: args(command: "env")) == .safe)
            #expect(sut.validateSafety(arguments: args(command: "env FOO=bar")) == .safe)
        }

        @Test("白名单命令的破坏性形式需要确认", arguments: [
            "find . -delete",
            "find . -execdir rm {} +",
            "find . -ok echo {} \\;",
            "find . -fprint out.txt",
            "find . -fprintf out.txt '%p'",
            "find . -fls listing",
            "ip link set eth0 up",
            "ip addr flush dev eth0",
            "ip addr add 10.0.0.2/24 dev eth0",
            "ip addr del 10.0.0.2/24 dev eth0",
            "ip route add default via 10.0.0.1",
            "ip route del default",
            "hostname web-1",
            "date -s 2020-01-01",
            "date --set 2020-01-01",
            "git branch -d feature",
            "git branch -D feature",
            "git diff --output out.patch",
            "git diff --output=out.patch",
            "rm -rf /tmp/build",
            "rm -rf /usr/bin",
            "rm -rf ~/work",
        ])
        func destructiveFormNeedsConfirmation(command: String) {
            #expect(sut.validateSafety(arguments: args(command: command)) == .needsConfirmation, "应需要确认: \(command)")
        }

        @Test("只读形式保持 safe", arguments: [
            "ls -la /tmp",
            "find . -name foo",
            "ip addr show",
            "ip link",
            "ip route get 8.8.8.8",
            "hostname",
            "hostname -I",
            "date",
            "date +%s",
            "git status -sb",
            "git branch -vv",
            "git diff HEAD",
            "echo rm -rf /tmp/build",
        ])
        func readOnlyStaysSafe(command: String) {
            #expect(sut.validateSafety(arguments: args(command: command)) == .safe, "应自动放行: \(command)")
        }

        @Test("is_destructive 不能把 rm -rf /tmp/build 降成 safe")
        func destructiveFlagCannotClearRm() {
            #expect(sut.validateSafety(arguments: args(command: "rm -rf /tmp/build", isDestructive: false)) == .needsConfirmation)
        }

        @Test("is_destructive 可以把只读命令升为需要确认")
        func destructiveFlagRaisesReadOnly() {
            #expect(sut.validateSafety(arguments: args(command: "ls", isDestructive: true)) == .needsConfirmation)
        }
    }

    @Suite("rm and mkfs boundaries")
    struct RmAndMkfsBoundaryTests {
        private let sut = ExecuteSSHCommandTool()

        private func args(command: String) -> [String: Any] {
            ["command": command, "is_destructive": false, "explanation": "test"]
        }

        @Test("递归删除受保护路径 forbidden", arguments: [
            "rm -rf /",
            "rm -fr /",
            "rm -rf /*",
            "rm -rf ~",
            "rm -rf ~/",
            "rm -rf $HOME",
            "rm -rf ${HOME}",
            "rm -r -f /",
            "rm --recursive --force /",
            "sudo rm -rf /*",
            "env rm -rf ~",
            "bash -c 'rm -rf /'",
            "rm -rf /usr",
            "rm -rf /tmp",
            "rm -rf /bin/*",
        ])
        func protectedRmIsForbidden(command: String) {
            #expect(sut.validateSafety(arguments: args(command: command)) == .forbidden, "应禁止: \(command)")
        }

        @Test("子路径和非递归删除不 forbidden", arguments: [
            "rm -rf /tmp/build",
            "rm -rf ./build",
            "rm -rf /usr/local",
            "rm -f /tmp/build/file",
            "rm file.txt",
        ])
        func narrowRmNeedsConfirmation(command: String) {
            #expect(sut.validateSafety(arguments: args(command: command)) == .needsConfirmation, "应需要确认: \(command)")
        }

        @Test("mkfs 词边界")
        func mkfsWordBoundary() {
            #expect(sut.validateSafety(arguments: args(command: "mkfs.ext4 /dev/sda1")) == .forbidden)
            #expect(sut.validateSafety(arguments: args(command: "sudo mkfs /dev/sda")) == .forbidden)
            #expect(sut.validateSafety(arguments: args(command: "echo mkfs")) == .forbidden)
            #expect(sut.validateSafety(arguments: args(command: "echo notmkfs")) == .safe)
            #expect(sut.validateSafety(arguments: args(command: "echo mkfilesystem")) == .safe)
            #expect(sut.validateSafety(arguments: args(command: "grep mkfs /var/log/syslog")) == .forbidden)
        }
    }
}
