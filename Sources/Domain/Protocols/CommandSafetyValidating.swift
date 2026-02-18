import Foundation

enum CommandSafetyLevel: Sendable {
    case safe
    case needsConfirmation
    case forbidden
}

protocol CommandSafetyValidating: Sendable {
    func validate(_ command: SSHCommand) -> CommandSafetyLevel
}
