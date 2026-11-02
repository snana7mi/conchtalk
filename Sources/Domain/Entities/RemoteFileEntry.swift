/// 文件说明：RemoteFileEntry，SFTP 目录中的一条远端文件记录。
import Foundation

/// RemoteFileEntry：
/// 浏览器用的值类型。目录和文件都用绝对路径标识。
nonisolated struct RemoteFileEntry: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var isDirectory: Bool
    var size: UInt64?

    init(name: String, path: String, isDirectory: Bool, size: UInt64?) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
    }
}

/// RemotePath：整理远端绝对路径，折叠 `.` 和 `..`。
nonisolated enum RemotePath {
    static func normalize(_ path: String) -> String {
        let cleaned = path.replacingOccurrences(of: "\0", with: "")
        var parts: [String] = []
        for raw in cleaned.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(raw)
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        if parts.isEmpty { return "/" }
        return "/" + parts.joined(separator: "/")
    }

    static func joining(directory: String, name: String) -> String {
        let dir = normalize(directory)
        let child = name.replacingOccurrences(of: "/", with: "")
        if dir == "/" { return "/" + child }
        return dir + "/" + child
    }

    static func parent(of path: String) -> String? {
        let normalized = normalize(path)
        guard normalized != "/" else { return nil }
        let parent = (normalized as NSString).deletingLastPathComponent
        if parent.isEmpty || parent == "." { return "/" }
        return parent
    }
}

/// RemoteFileAttributes：从 SFTP 权限位或 `ls` 长名称判断是否为目录。
nonisolated enum RemoteFileAttributes {
    static func isDirectory(permissions: UInt32?, longname: String) -> Bool {
        if let permissions {
            let type = permissions & 0o170000
            if type == 0o040000 { return true }
            if type != 0 { return false }
        }
        return longname.hasPrefix("d")
    }
}

/// RemoteDirectoryIndex：把原始目录项整理成排序后的列表，跳过 `.` 和 `..`。
nonisolated enum RemoteDirectoryIndex {
    struct Item: Sendable {
        var name: String
        var longname: String
        var permissions: UInt32?
        var size: UInt64?
    }

    static func entries(directory: String, items: [Item]) -> [RemoteFileEntry] {
        let built = items.compactMap { item -> RemoteFileEntry? in
            guard item.name != ".", item.name != ".." else { return nil }
            guard !item.name.isEmpty, !item.name.contains("/") else { return nil }
            let path = RemotePath.joining(directory: directory, name: item.name)
            return RemoteFileEntry(
                name: item.name,
                path: path,
                isDirectory: RemoteFileAttributes.isDirectory(permissions: item.permissions, longname: item.longname),
                size: item.size
            )
        }
        return built.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
