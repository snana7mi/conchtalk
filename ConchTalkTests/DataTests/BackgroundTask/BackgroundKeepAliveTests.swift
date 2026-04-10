/// 文件说明：BackgroundKeepAliveTests，验证 BackgroundKeepAlive 基本行为。
import Testing
@testable import ConchTalk

@Suite("BackgroundKeepAlive")
@MainActor
struct BackgroundKeepAliveTests {
    @Test("初始化不 crash")
    func initialization() {
        let _ = BackgroundKeepAlive()
    }

    @Test("endBackgroundKeepAlive 幂等调用不 crash")
    func endIsIdempotent() {
        let keepAlive = BackgroundKeepAlive()
        keepAlive.endBackgroundKeepAlive()
        keepAlive.endBackgroundKeepAlive()
    }
}
