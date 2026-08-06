/// 文件说明：SSHProcessTransportTests，验证通用 SSH 进程行传输的基本行为。

import Testing
@testable import ConchTalk

@Suite("SSHProcessTransport")
struct SSHProcessTransportTests {
    @Test("行缓冲正确分割完整行")
    func lineBufferingSplitsCompleteLines() {
        var buffer = LineBuffer()
        let lines1 = buffer.append("{\"type\":\"system\"}\n{\"type\":\"keep")
        #expect(lines1 == ["{\"type\":\"system\"}"])

        let lines2 = buffer.append("_alive\"}\n")
        #expect(lines2 == ["{\"type\":\"keep_alive\"}"])
    }

    @Test("行缓冲剥离 PTY 的 CR")
    func lineBufferStripsCR() {
        var buffer = LineBuffer()
        let lines = buffer.append("{\"type\":\"test\"}\r\n")
        #expect(lines == ["{\"type\":\"test\"}"])
    }

    @Test("空行被跳过")
    func lineBufferSkipsEmptyLines() {
        var buffer = LineBuffer()
        let lines = buffer.append("\n\n{\"type\":\"test\"}\n\n")
        #expect(lines == ["{\"type\":\"test\"}"])
    }
}
