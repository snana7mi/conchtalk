/// 文件说明：CommandHardeningTests，验证命令禁止规则、包装器与白名单子命令边界。
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

    @Test("包装器不能靠首词自动放行", arguments: wrapperNotAutoSafe)
    func wrapperIsNotAutoSafe(command: String) {
        #expect(CommandHardening.isAutoSafe(command) == false, "不应自动放行: \(command)")
    }

    @Test("没有子命令的 env 仍是只读")
    func bareEnvPrintsOnly() {
        #expect(CommandHardening.isAutoSafe("env") == true)
        #expect(CommandHardening.isAutoSafe("env FOO=bar") == true)
        #expect(CommandHardening.isAutoSafe("env -u PATH") == true)
        #expect(CommandHardening.isForbidden("env") == false)
    }

    @Test("白名单命令的破坏性子命令/标志不自动放行", arguments: destructiveAllowlisted)
    func destructiveAllowlistedNeedsReview(command: String) {
        #expect(CommandHardening.isForbidden(command) == false, "不应禁止: \(command)")
        #expect(CommandHardening.isAutoSafe(command) == false, "不应自动放行: \(command)")
    }

    @Test("只读形式保持自动放行", arguments: readOnlyAllowlisted)
    func readOnlyStayAutoSafe(command: String) {
        #expect(CommandHardening.isForbidden(command) == false, "不应禁止: \(command)")
        #expect(CommandHardening.isAutoSafe(command) == true, "应自动放行: \(command)")
    }

    @Test("递归删除受保护路径被禁止", arguments: forbiddenRm)
    func recursiveRmOfProtectedPaths(command: String) {
        #expect(CommandHardening.isForbidden(command) == true, "应禁止: \(command)")
    }

    @Test("非受保护目标或非递归 rm 不禁止", arguments: allowedRm)
    func rmThatIsNotAProtectedWipe(command: String) {
        #expect(CommandHardening.isForbidden(command) == false, "不应禁止: \(command)")
    }

    @Test("mkfs 按词边界禁止")
    func mkfsWordBoundary() {
        for command in ["mkfs /dev/sda1", "mkfs.ext4 /dev/sda1", "sudo mkfs.xfs /dev/sdb", "echo mkfs", "ls /sbin/mkfs.ext4"] {
            #expect(CommandHardening.isForbidden(command) == true, "应禁止: \(command)")
        }
        for command in ["echo notmkfs", "echo mkfilesystem", "echo my_mkfs_notes", "grep pattern /var/log/syslog"] {
            #expect(CommandHardening.isForbidden(command) == false, "不应禁止: \(command)")
        }
    }
}

private let wrapperNotAutoSafe = [
    "env ls",
    "env FOO=1 ls -la",
    "env rm -rf /tmp/build",
    "env sh -c 'ls'",
    "env sh -c 'rm -rf /tmp/build'",
    "sudo ls",
    "nohup ls",
    "xargs ls",
    "timeout 5 ls",
    "nice ls",
    "nice -n 5 ls",
    "time ls",
    "command ls",
    "exec ls",
    "sh -c 'ls'",
    "bash -lc 'hostname'",
    "dash -c 'ls'",
]

private let destructiveAllowlisted = [
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
    "hostname -F /etc/hostname",
    "date -s '2020-01-01 00:00:00'",
    "date --set '2020-01-01 00:00:00'",
    "date --set=2020-01-01",
    "date 010100002026",
    "git branch -d feature",
    "git branch -D feature",
    "git branch --delete feature",
    "git diff --output out.patch",
    "git diff --output=out.patch",
]

private let readOnlyAllowlisted = [
    "ls -la",
    "cat /etc/hosts",
    "ps aux",
    "df -h",
    "find . -name '*.swift'",
    "find /var/log -type f",
    "ip addr",
    "ip -4 addr show",
    "ip link show",
    "ip route",
    "ip route get 1.1.1.1",
    "hostname",
    "hostname -I",
    "hostname -f",
    "date",
    "date -u",
    "date +%Y-%m-%d",
    "date -d yesterday",
    "git status",
    "git branch",
    "git branch -vv",
    "git diff",
    "git diff --stat",
    "git log -1",
    "docker ps -a",
    "systemctl status nginx",
    "echo 'a && rm -rf /tmp/build'",
    "ls && ps aux",
    "cat /etc/hosts | grep localhost",
]

private let forbiddenRm = [
    "rm -rf /",
    "rm -fr /",
    "rm -rf /.",
    "rm -rf //",
    "rm -rf /*",
    "rm -rf ~",
    "rm -rf ~/",
    "rm -rf ~/*",
    "rm -rf $HOME",
    "rm -rf $HOME/",
    "rm -rf $HOME/*",
    "rm -rf ${HOME}",
    "rm -rf \"${HOME}\"",
    "rm -rf '$HOME'",
    "rm -r -f /",
    "rm -f -r /",
    "rm --recursive --force /",
    "rm --force --recursive -- /",
    "rm -rfv /bin",
    "rm -rf /bin/",
    "rm -rf /usr",
    "rm -rf /usr/*",
    "rm -rf /etc",
    "rm -rf /tmp",
    "rm -rf /tmp/",
    "rm -rf /tmp/*",
    "rm -rf /home",
    "rm -rf /tmp/..",
    "rm -rf /tmp/../usr",
    "sudo rm -rf /*",
    "sudo -u root rm -rf /",
    "env rm -rf ~",
    "env sh -c 'rm -rf /'",
    "bash -c 'rm -rf ~'",
    "bash -lc \"rm -rf /*\"",
    "nohup rm -rf /",
    "xargs rm -rf /",
    "timeout 5 rm -rf /",
    "nice rm -rf ~",
    "time rm -rf /home",
    "command rm --recursive --force /",
    "exec rm -r -f /",
    "find . -exec rm -rf / {} \\;",
    "echo 'rm -rf /'",
    "python -c \"import os; os.system('rm -rf /')\"",
]

private let allowedRm = [
    "rm -rf /tmp/build",
    "rm   -rf   /tmp/build",
    "rm -rf /tmp/build/",
    "rm -rf //tmp//build",
    "rm -rf ./build",
    "rm -rf /usr/bin",
    "rm -rf /usr/local/src",
    "rm -rf /var/log/app",
    "rm -rf /tmp/../var/log",
    "rm -rf ~/work",
    "rm -rf $HOME/projects",
    "rm file.txt",
    "rm -f /tmp/a",
    "rm /",
    "rm -rf -- /tmp/build",
    "echo 'rm -rf /tmp/build'",
    "echo rm -rf /tmp/build",
    "ls && rm -rf /tmp/build",
]
