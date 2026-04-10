/// 文件说明：AuthServiceProtocol，定义认证服务的跨层接口契约。
import Foundation

/// AuthServiceProtocol：
/// 抽象认证服务的核心只读能力与令牌管理，供 Data/Domain 层消费，
/// 避免直接依赖 AuthService 具体实现。
protocol AuthServiceProtocol: AnyObject, Sendable {
    /// 当前是否已登录。
    var isLoggedIn: Bool { get }
    /// 当前登录用户信息。
    var currentUser: AuthUser? { get }
    /// 获取有效的 access token，过期时自动刷新。
    func validAccessToken() async throws -> String
    /// 刷新 access token。
    func refreshAccessToken() async throws
    /// 外部传入新的 AuthUser 以刷新本地状态（用于订阅验证后更新 tier）。
    func updateCurrentUser(_ user: AuthUser)
    /// 从后端拉取最新账户信息并更新本地状态。
    func fetchAccount() async throws
}
