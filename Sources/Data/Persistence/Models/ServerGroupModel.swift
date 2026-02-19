/// 文件说明：ServerGroupModel，定义服务器分组在 SwiftData 中的持久化结构。
import Foundation
import SwiftData

/// ServerGroupModel：
/// 服务器分组持久化模型，维护分组元数据及与服务器的反向关系。
@Model
final class ServerGroupModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortOrder: Int
    var colorTag: String?
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \ServerModel.group)
    var servers: [ServerModel] = []

    /// 初始化服务器分组持久化模型。
    /// - Parameters:
    ///   - id: 分组标识。
    ///   - name: 分组名称。
    ///   - sortOrder: 排序权重。
    ///   - colorTag: 颜色标签。
    ///   - createdAt: 创建时间。
    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, colorTag: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.colorTag = colorTag
        self.createdAt = createdAt
    }

    /// 转换为领域层 `ServerGroup` 实体。
    /// - Returns: 对应的领域分组对象。
    func toDomain() -> ServerGroup {
        ServerGroup(id: id, name: name, sortOrder: sortOrder, colorTag: colorTag)
    }

    /// 从领域层 `ServerGroup` 构建持久化模型。
    /// - Parameter group: 领域分组对象。
    /// - Returns: 对应的持久化模型实例。
    static func fromDomain(_ group: ServerGroup) -> ServerGroupModel {
        ServerGroupModel(id: group.id, name: group.name, sortOrder: group.sortOrder, colorTag: group.colorTag)
    }
}
