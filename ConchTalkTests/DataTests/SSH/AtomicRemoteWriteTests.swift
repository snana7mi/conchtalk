/// 文件说明：AtomicRemoteWriteTests，验证临时文件与原子替换命令。
import Testing
@testable import ConchTalk
import Foundation

@Suite("AtomicRemoteWrite")
struct AtomicRemoteWriteTests {
    @Test("临时文件与目标在同一目录")
    func temporaryFileStaysBesideDestination() {
        let path = AtomicRemoteWrite.temporaryPath(for: "/var/app/config.yaml", token: "abc")
        #expect(path == "/var/app/.config.yaml.conchtalk-abc.tmp")
        #expect(AtomicRemoteWrite.temporaryPath(for: "/config.yaml", token: "abc") == "/.config.yaml.conchtalk-abc.tmp")
    }

    @Test("替换与恢复命令使用 mv -f")
    func commandsUseAtomicRename() {
        let replace = AtomicRemoteWrite.replaceCommand(
            temporaryPath: "/var/app/.config.yaml.conchtalk-abc.tmp",
            destination: "/var/app/config.yaml"
        )
        #expect(replace.contains("mv -f"))
        #expect(replace.contains(shellEscape("/var/app/config.yaml")))

        let restore = AtomicRemoteWrite.restoreCommand(
            snapshotPath: "/tmp/snap",
            destination: "/var/app/config.yaml",
            token: "abc"
        )
        #expect(restore.contains("cp -p"))
        #expect(restore.contains("mv -f"))
        #expect(restore.contains("/var/app/.config.yaml.conchtalk-abc.tmp") || restore.contains(shellEscape("/var/app/.config.yaml.conchtalk-abc.tmp")))
    }
}
