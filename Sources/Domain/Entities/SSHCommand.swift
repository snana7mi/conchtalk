import Foundation

nonisolated struct SSHCommand: Codable, Sendable {
    let command: String
    let explanation: String
    let isDestructive: Bool

    enum CodingKeys: String, CodingKey {
        case command
        case explanation
        case isDestructive = "is_destructive"
    }
}
