import Foundation

struct ServerGroup: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var sortOrder: Int
    var colorTag: String?

    init(id: UUID = UUID(), name: String, sortOrder: Int = 0, colorTag: String? = nil) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.colorTag = colorTag
    }
}
