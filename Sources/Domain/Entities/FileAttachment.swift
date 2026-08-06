/// 文件说明：FileAttachment，定义用户选择的本地文件附件模型。
import Foundation

/// FileAttachment：
/// 表示用户从本地设备选择的待上传文件，携带文件元数据与二进制内容。
nonisolated struct FileAttachment: Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let fileSize: Int64
    let mimeType: String
    let data: Data

    init(id: UUID = UUID(), fileName: String, fileSize: Int64, mimeType: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.data = data
    }

    /// 格式化的文件大小（如 "2.4 MB"）
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    /// 文件扩展名（大写，如 "XLSX"）
    var fileExtension: String {
        let ext = (fileName as NSString).pathExtension
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }
}
