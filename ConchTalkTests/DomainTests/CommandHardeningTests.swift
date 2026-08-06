/// 文件说明：CommandHardeningTests，验证共享安全谓词与旧 ExecuteSSHCommandTool 行为一致。
import Testing
@testable import ConchTalk

@Suite("CommandHardening")
struct CommandHardeningTests {
    @Test("forbidden: rm -rf /")
    func forbiddenRmRf() {
        #expect(CommandHardening.isForbidden("rm -rf /") == true)
        #expect(CommandHardening.isForbidden("mkfs.ext4 /dev/sda1") == true)
        #expect(CommandHardening.isForbidden("ls -la") == false)
    }

    @Test("输出重定向/ tee / heredoc 视为写注入")
    func injection() {
        #expect(CommandHardening.hasInjectionOrRedirection("echo x > /etc/hosts") == true)
        #expect(CommandHardening.hasInjectionOrRedirection("cat a | tee b") == true)
        #expect(CommandHardening.hasInjectionOrRedirection("cat <<EOF") == true)
        #expect(CommandHardening.hasInjectionOrRedirection("find . -exec rm {} ;") == true)
        #expect(CommandHardening.hasInjectionOrRedirection("echo $(whoami)") == true)
        #expect(CommandHardening.hasInjectionOrRedirection("git -C /srv/app pull") == false)
    }

    @Test("按操作符分段")
    func split() {
        #expect(CommandHardening.splitRawSegments("a | b ; c & d") == ["a", "b", "c", "d"])
        #expect(CommandHardening.splitRawSegments("git -C /srv/app pull").count == 1)
    }

    @Test("段内 token 化")
    func tokenize() {
        #expect(CommandHardening.tokenize("git -C /srv/app pull") == ["git", "-C", "/srv/app", "pull"])
        #expect(CommandHardening.tokenize("  systemctl   status  ") == ["systemctl", "status"])
    }

    @Test("安全白名单首词匹配")
    func safe() {
        #expect(CommandHardening.matchesSafeCommand("ls -la") == true)
        #expect(CommandHardening.matchesSafeCommand("findstuff") == false)
    }
}
