/// 文件说明：ApprovalPreviewBuilderTests，验证各工具的预览分支。
import Testing
import Foundation
@testable import ConchTalk

@Suite("ApprovalPreviewBuilder")
struct ApprovalPreviewBuilderTests {
    /// 复用既有共享桩 MockSSHClient（实现 SSHClientProtocol 全部成员）。

    @Test("edit_file 直接 diff old_text/new_text，无需读文件")
    func editDiff() async throws {
        let b = ApprovalPreviewBuilder()
        let p = await b.buildPreview(toolName: "edit_file",
            arguments: ["path": "/a", "old_text": "x\ny", "new_text": "x\nz"], sshClient: MockSSHClient())
        if case .fileDiff(let lines, _) = p {
            #expect(lines.contains(.removed("y"))); #expect(lines.contains(.added("z")))
        } else { Issue.record("应为 fileDiff") }
    }

    @Test("write_file 覆盖：远端存在则出 diff")
    func writeOverwriteDiff() async throws {
        let ssh = MockSSHClient()
        ssh.sftpReadResult = Data("old".utf8)
        ssh.sftpFileSizeResult = 3
        let p = await ApprovalPreviewBuilder().buildPreview(toolName: "write_file",
            arguments: ["path": "/a", "content": "new"], sshClient: ssh)
        if case .fileDiff = p {} else { Issue.record("应为 fileDiff") }
    }

    @Test("write_file 远端不存在 → newFile")
    func writeNewFile() async throws {
        let ssh = MockSSHClient()
        ssh.sftpFileSizeError = ToolError.executionFailed("not found")
        ssh.sftpReadError = ToolError.executionFailed("not found")
        let p = await ApprovalPreviewBuilder().buildPreview(toolName: "write_file",
            arguments: ["path": "/none", "content": "a\nb"], sshClient: ssh)
        if case .newFile(let lc, _) = p { #expect(lc == 2) } else { Issue.record("应为 newFile") }
    }

    @Test("append → append 分支")
    func appendBranch() async throws {
        let p = await ApprovalPreviewBuilder().buildPreview(toolName: "write_file",
            arguments: ["path": "/a", "content": "tail", "append": true], sshClient: MockSSHClient())
        if case .append = p {} else { Issue.record("应为 append") }
    }

    @Test("base64 → binaryWrite")
    func binary() async throws {
        let p = await ApprovalPreviewBuilder().buildPreview(toolName: "write_file",
            arguments: ["path": "/a", "content": "aGVsbG8=", "encoding": "base64"], sshClient: MockSSHClient())
        if case .binaryWrite = p {} else { Issue.record("应为 binaryWrite") }
    }

    @Test("超大文件 → unavailable")
    func tooLarge() async throws {
        let ssh = MockSSHClient()
        ssh.sftpFileSizeResult = 5_000_000
        let p = await ApprovalPreviewBuilder().buildPreview(toolName: "write_file",
            arguments: ["path": "/big", "content": "x"], sshClient: ssh)
        if case .unavailable = p {} else { Issue.record("应为 unavailable") }
    }

    @Test("execute_ssh_command → command")
    func command() async throws {
        let p = await ApprovalPreviewBuilder().buildPreview(toolName: "execute_ssh_command",
            arguments: ["command": "ls -la"], sshClient: MockSSHClient())
        if case .command(let t) = p { #expect(t == "ls -la") } else { Issue.record("应为 command") }
    }
}
