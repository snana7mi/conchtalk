/// 文件说明：ServerGroup，定义服务器分组的领域实体模型。
import Foundation

/// ServerGroup：
/// 表示服务器列表中的分组信息，包含名称、排序与可选颜色标签。
struct ServerGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sortOrder: Int
    var colorTag: String?

    /// 初始化服务器分组实体。
    /// - Parameters:
    ///   - id: 分组标识。
    ///   - name: 分组名称。
    ///   - sortOrder: 排序权重（越小越靠前）。
    ///   - colorTag: 分组颜色标签（可选）。
    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, colorTag: String? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.colorTag = colorTag
    }
}
