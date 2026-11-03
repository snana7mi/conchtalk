/// 文件说明：RemoteFilePreviewPolicy，决定远端文件能以文本、图片还是二进制方式预览。
import Foundation

/// RemoteFilePreview：预览结果。图片保留原始字节，由界面解码。
nonisolated enum RemoteFilePreview: Equatable, Sendable {
    case text(String)
    case image(Data)
    case tooLarge(Int64)
    case binary
}

/// RemoteFilePreviewPolicy：
/// 文本和未知的小文件尝试按 UTF-8 显示。图片只接受常见扩展名。
/// 传输上限与聊天附件一致，避免把大文件整段读进内存。
nonisolated enum RemoteFilePreviewPolicy {
    static let maxTransferBytes: Int64 = 50 * 1024 * 1024
    static let textPreviewLimit: Int64 = 256 * 1024
    static let imagePreviewLimit: Int64 = 8 * 1024 * 1024

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "log", "swift", "py", "rb", "go", "rs", "java", "kt",
        "sh", "bash", "zsh", "yml", "yaml", "toml", "conf", "cfg", "ini", "xml", "html", "css",
        "js", "ts", "tsx", "jsx", "csv", "env", "service", "plist", "sql", "gitignore"
    ]

    /// 预览前允许读入内存的上限。图片比文本更高，其余类型按文本上限。
    static func previewReadLimit(for fileName: String) -> Int64 {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return imagePreviewLimit }
        return textPreviewLimit
    }

    static func preview(fileName: String, data: Data) -> RemoteFilePreview {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            if Int64(data.count) > imagePreviewLimit { return .tooLarge(Int64(data.count)) }
            return .image(data)
        }
        if Int64(data.count) > textPreviewLimit {
            return .tooLarge(Int64(data.count))
        }
        if textExtensions.contains(ext) || ext.isEmpty || !data.contains(0) {
            if let text = String(data: data, encoding: .utf8) {
                return .text(text)
            }
        }
        return .binary
    }

    static func mimeType(for fileName: String) -> String {
        let ext = (fileName as NSString).pathExtension
        if ext.isEmpty { return "application/octet-stream" }
        // UTType 在界面层补全。这里给一个足够让附件卡片显示扩展名的回退。
        return "application/octet-stream"
    }
}

/// RemoteFileDownload：把已读到的字节写到临时文件，供系统分享。
nonisolated enum RemoteFileDownload {
    static func writeTemporary(fileName: String, data: Data, directory: URL? = nil) throws -> URL {
        let folder = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("ConchTalkDownloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safeName = fileName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\0", with: "")
        let name = safeName.isEmpty ? "download" : safeName
        let url = folder.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
