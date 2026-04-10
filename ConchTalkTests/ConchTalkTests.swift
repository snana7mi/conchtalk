/// 文件说明：ConchTalkTests，测试 target 入口验证文件。
import Testing
@testable import ConchTalk

@Suite("Smoke Test")
struct SmokeTests {
    @Test("测试 target 可正常编译和运行")
    func smokeTest() {
        #expect(true)
    }
}
