/// 文件说明：RemoteCommandSupervisorTests，验证超时包装脚本与超时判定。
import Testing
@testable import ConchTalk
import Foundation

@Suite("RemoteCommandSupervisor")
struct RemoteCommandSupervisorTests {
    @Test("超时被夹到 1...600")
    func clampTimeout() {
        #expect(RemoteCommandSupervisor.clamp(0) == 1)
        #expect(RemoteCommandSupervisor.clamp(30) == 30)
        #expect(RemoteCommandSupervisor.clamp(5_000) == 600)
        #expect(RemoteCommandSupervisor.clamp(.nan) == 30)
    }

    @Test("包装脚本使用 setsid 并在超时后杀掉进程组")
    func wrapUsesSetsidAndKill() {
        let script = RemoteCommandSupervisor.wrap(
            command: "echo 'hi'",
            pidFile: "/tmp/conchtalk-test.pid",
            timeout: 5_000
        )
        #expect(script.contains("setsid --wait"))
        #expect(script.contains("kill -TERM \"-$target\""))
        #expect(script.contains("sleep 600"))
        #expect(script.contains(RemoteCommandSupervisor.timeoutMarker))
        #expect(script.contains(shellEscape("echo 'hi'")))
        #expect(script.contains("/tmp/conchtalk-test.pid"))
    }

    @Test("只有退出码和标记同时出现才算监督超时")
    func timeoutResultRequiresMarker() {
        #expect(RemoteCommandSupervisor.isTimeoutResult(
            exitCode: 124,
            stdout: "",
            stderr: RemoteCommandSupervisor.timeoutMarker
        ))
        #expect(!RemoteCommandSupervisor.isTimeoutResult(exitCode: 124, stdout: "done", stderr: ""))
        #expect(!RemoteCommandSupervisor.isTimeoutResult(
            exitCode: 1,
            stdout: "",
            stderr: RemoteCommandSupervisor.timeoutMarker
        ))
    }
}
