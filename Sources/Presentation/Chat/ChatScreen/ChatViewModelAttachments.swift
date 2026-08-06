/// 文件说明：ChatViewModelAttachments，承载聊天页面附件选择与本地附件状态管理。
import Foundation
import UniformTypeIdentifiers

extension ChatViewModel {
    /// 50MB 单文件大小上限。
    static let maxFileSize: Int64 = 50 * 1024 * 1024

    /// 添加附件，校验文件大小。
    /// - Returns: 超出大小限制时返回文件名列表。
    func addAttachments(from urls: [URL]) -> [String] {
        var oversizedFiles: [String] = []
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            // 先通过元数据检查文件大小，避免大文件整体读入内存
            guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = resourceValues.fileSize.map(Int64.init) else { continue }

            if fileSize > Self.maxFileSize {
                oversizedFiles.append(url.lastPathComponent)
                continue
            }

            guard let data = try? Data(contentsOf: url) else { continue }

            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"

            let attachment = FileAttachment(
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                mimeType: mimeType,
                data: data
            )
            attachments.append(attachment)
        }
        return oversizedFiles
    }

    /// 移除指定附件。
    func removeAttachment(_ attachment: FileAttachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    /// 清空所有附件。
    func clearAttachments() {
        attachments.removeAll()
    }
}
