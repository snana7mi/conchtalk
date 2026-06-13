/// 文件说明：WebFetchToolSafetyTests，验证 web_fetch 的 SSRF 执行前拦截与公网放行行为。
/// 注意：依赖 DNS 的用例（如 localhost 解析）在离线环境可能 flaky——失败属环境问题，非实现回归。
import Testing
import Foundation
@testable import ConchTalk

@Suite("WebFetchTool safety")
struct WebFetchToolSafetyTests {

    @Suite("SSRF guard rejects non-public")
    struct SSRFRejectionTests {

        /// 断言 URL 在执行前被拒：抛 ToolError 且远端零副作用（未执行任何命令）。
        private func expectRejected(_ url: String) async {
            let sut = WebFetchTool()
            let mock = MockSSHClient()
            await #expect(throws: ToolError.self) {
                _ = try await sut.executeStreaming(
                    arguments: ["url": url, "explanation": "test"],
                    sshClient: mock
                )
            }
            // 拦截发生在构建流之前 -> 远端 curl 不执行
            #expect(mock.executedCommands.isEmpty)
        }

        @Test("IMDS 地址被拒")
        func imdsRejected() async {
            await expectRejected("http://169.254.169.254/latest/meta-data/")
        }

        @Test("127.0.0.1 被拒")
        func loopbackRejected() async {
            await expectRejected("http://127.0.0.1:8080/")
        }

        @Test("localhost 被拒")
        func localhostRejected() async {
            await expectRejected("http://localhost/admin")
        }

        @Test("私网 192.168.x 被拒")
        func privateRangeRejected() async {
            await expectRejected("http://192.168.1.10/")
        }

        @Test("IPv6 回环 [::1] 被拒")
        func ipv6LoopbackRejected() async {
            await expectRejected("http://[::1]/")
        }

        @Test("decimal 编码 IP 被拒")
        func decimalEncodedRejected() async {
            await expectRejected("http://2130706433/")
        }

        @Test("无 host 的 URL 被拒")
        func noHostRejected() async {
            await expectRejected("http://")
        }
    }

    @Suite("Public target still auto-executes")
    struct PublicTargetTests {

        @Test("公网 IP 字面量仍自动执行（远端 curl 运行）")
        func publicIPLiteralStillExecutes() async throws {
            let sut = WebFetchTool()
            let mock = MockSSHClient()
            // 依次响应：转换工具探测 / curl 抓取（200 + text/plain）/ 读临时文件 / 清理
            mock.executeResults = [
                "none",
                "/tmp/conchtalk_wf.test\n200\ntext/plain",
                "hello",
                "",
            ]

            // 公网 IP 字面量（1.1.1.1）无需 DNS，判定确定为公网
            let stream = try await sut.executeStreaming(
                arguments: ["url": "https://1.1.1.1/", "explanation": "test"],
                sshClient: mock
            )
            var last = ""
            if let stream {
                for try await chunk in stream { last = chunk }
            }

            #expect(!mock.executedCommands.isEmpty)
            #expect(last.contains("hello"))
        }

        @Test("validateSafety 对公网与非公网 URL 均返回 .safe（拦截在执行期）")
        func validateSafetyAlwaysSafe() {
            let sut = WebFetchTool()
            #expect(sut.validateSafety(arguments: ["url": "https://example.com/"]) == .safe)
            #expect(sut.validateSafety(arguments: ["url": "http://169.254.169.254/"]) == .safe)
        }

        @Test("非 http(s) scheme 仍被拒（回归）", arguments: ["ftp://example.com/x", "file:///etc/passwd"])
        func nonHTTPSchemeRejected(url: String) async {
            let sut = WebFetchTool()
            let mock = MockSSHClient()
            await #expect(throws: ToolError.self) {
                _ = try await sut.executeStreaming(
                    arguments: ["url": url, "explanation": "test"],
                    sshClient: mock
                )
            }
            #expect(mock.executedCommands.isEmpty)
        }
    }
}
