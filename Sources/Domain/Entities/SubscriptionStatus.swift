/// 文件说明：SubscriptionStatus，订阅相关值类型。

/// PurchaseState：描述当前购买操作的状态。
enum PurchaseState: Sendable, Equatable {
    case idle
    /// Apple 支付面板展示中
    case purchasing
    /// 后端验证中
    case verifying
    /// 购买成功
    case success
    /// 等待家长审批等
    case pending
    /// 购买失败（存错误描述，Error 不是 Sendable）
    case failed(String)
}
