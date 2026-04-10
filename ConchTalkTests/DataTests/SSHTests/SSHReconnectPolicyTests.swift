/// 文件说明：SSHReconnectPolicyTests，验证重连退避策略的延迟计算。
import Testing
@testable import ConchTalk
import Foundation

@Suite("SSHReconnectPolicy")
struct SSHReconnectPolicyTests {

    @Test("delay 按指数递增")
    func delayExponentialIncrease() {
        let policy = SSHReconnectPolicy()

        #expect(policy.delay(forAttempt: 0) == 2)
        #expect(policy.delay(forAttempt: 1) == 4)
        #expect(policy.delay(forAttempt: 2) == 8)
        #expect(policy.delay(forAttempt: 3) == 16)
    }

    @Test("delay 不超过 maxDelay")
    func delayCappedAtMax() {
        let policy = SSHReconnectPolicy()

        #expect(policy.delay(forAttempt: 4) == 16)
        #expect(policy.delay(forAttempt: 10) == 16)
    }

    @Test("maxAttempts 为 4")
    func maxAttemptsIsFour() {
        let policy = SSHReconnectPolicy()
        #expect(policy.maxAttempts == 4)
    }
}
