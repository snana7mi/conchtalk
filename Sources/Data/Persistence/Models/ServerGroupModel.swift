import Foundation
import SwiftData

@Model
final class ServerGroupModel {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortOrder: Int
    var colorTag: String?
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \ServerModel.group)
    var servers: [ServerModel] = []

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, colorTag: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.colorTag = colorTag
        self.createdAt = createdAt
    }

    func toDomain() -> ServerGroup {
        ServerGroup(id: id, name: name, sortOrder: sortOrder, colorTag: colorTag)
    }

    static func fromDomain(_ group: ServerGroup) -> ServerGroupModel {
        ServerGroupModel(id: group.id, name: group.name, sortOrder: group.sortOrder, colorTag: group.colorTag)
    }
}
