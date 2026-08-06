/// 文件说明：PersistenceMaintenance，定义本地持久化维护策略。
import Foundation

/// PersistenceMaintenance：
/// 定义本地持久化维护策略，避免软删除记录无限增长。
enum PersistenceMaintenance {
    static let softDeleteRetentionInterval: TimeInterval = 30 * 24 * 60 * 60
}
