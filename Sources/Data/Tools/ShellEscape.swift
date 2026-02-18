import Foundation

/// Escape a string for safe use in a shell command.
func shellEscape(_ string: String) -> String {
    "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
