/// 文件说明：PushRegistrationServiceTests，验证 token hex 编码、installID 持久化与上传。
import Testing
import Foundation
@testable import ConchTalk

@Suite("PushRegistrationService")
struct PushRegistrationServiceTests {
    actor FakeAPI: PushUploading {
        private(set) var registered: (token: String, env: String, install: String)?
        private(set) var deleted: String?
        func registerToken(apnsToken: String, environment: String, installID: String) async throws { registered = (apnsToken, environment, installID) }
        func deleteToken(installID: String) async throws { deleted = installID }
    }

    @Test("device token 转 hex 并上传，installID 稳定复用")
    func uploadsHexToken() async throws {
        let api = FakeAPI()
        let defaults = UserDefaults(suiteName: "push-test-\(UUID().uuidString)")!
        let svc = PushRegistrationService(api: api, defaults: defaults)
        try await svc.handleToken(Data([0xDE, 0xAD, 0xBE, 0xEF]))
        let reg = await api.registered
        #expect(reg?.token == "deadbeef")
        #expect(reg?.install == svc.installID)            // 同一 installID
        #expect(defaults.string(forKey: "push.installID") == svc.installID)  // 已持久化
    }

    @Test("environment：DEBUG=sandbox")
    func environmentValue() {
        #if DEBUG
        #expect(PushRegistrationService.currentEnvironment == "sandbox")
        #else
        #expect(PushRegistrationService.currentEnvironment == "production")
        #endif
    }
}
