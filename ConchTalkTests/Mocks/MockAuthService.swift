/// 文件说明：MockAuthService，认证服务测试替身，登录态与用户信息可控。
@testable import ConchTalk
import Foundation

/// MockAuthService：
/// AuthServiceProtocol 的测试替身，默认已登录。
final class MockAuthService: AuthServiceProtocol, @unchecked Sendable {
    var isLoggedIn: Bool = true
    var currentUser: AuthUser? = nil

    func validAccessToken() async throws -> String { "test-token" }
    func refreshAccessToken() async throws {}
    func updateCurrentUser(_ user: AuthUser) { currentUser = user }
    func fetchAccount() async throws {}
}
