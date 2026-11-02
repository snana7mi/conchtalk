/// 文件说明：AtomicRemoteWrite，同目录临时文件路径与原子替换命令。
import Foundation

/// AtomicRemoteWrite：
/// 先把内容写到目标同目录的临时文件，再用 `mv -f` 替换。
/// 同一文件系统上的 rename 会一次换成完整内容，避免写到一半留下截断文件。
nonisolated enum AtomicRemoteWrite {
    /// 目标同目录下的隐藏临时路径。
    static func temporaryPath(for destination: String, token: String = UUID().uuidString) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = (trimmed as NSString).deletingLastPathComponent
        let name = (trimmed as NSString).lastPathComponent
        let temporaryName = ".\(name).conchtalk-\(token).tmp"
        if directory.isEmpty || directory == "." {
            return temporaryName
        }
        if directory == "/" {
            return "/" + temporaryName
        }
        return directory + "/" + temporaryName
    }

    /// 用同目录 `mv -f` 替换目标。调用方需要先把原权限和属主写到临时文件上。
    static func replaceCommand(temporaryPath: String, destination: String) -> String {
        "mv -f \(shellEscape(temporaryPath)) \(shellEscape(destination))"
    }

    /// 从快照恢复：先 `cp -p` 保留模式与属主，再原子替换。
    static func restoreCommand(snapshotPath: String, destination: String, token: String = UUID().uuidString) -> String {
        let temporary = temporaryPath(for: destination, token: token)
        return "cp -p \(shellEscape(snapshotPath)) \(shellEscape(temporary)) && mv -f \(shellEscape(temporary)) \(shellEscape(destination))"
    }

    /// 撤销「新建文件」时删除目标。
    static func removeCommand(destination: String) -> String {
        "rm -f \(shellEscape(destination))"
    }
}
