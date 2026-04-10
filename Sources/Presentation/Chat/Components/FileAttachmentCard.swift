/// 文件说明：FileAttachmentCard，显示单个附件文件的预览卡片。
import SwiftUI

/// FileAttachmentCard：
/// 展示文件名（截断）、类型扩展名标签、文件大小，以及删除按钮。
struct FileAttachmentCard: View {
    let attachment: FileAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // 文件类型图标
            Text(attachment.fileExtension)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(iconColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(attachment.formattedSize)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 120, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 根据文件扩展名返回对应的图标颜色。
    private var iconColor: Color {
        switch attachment.fileExtension {
        case "PDF": return .red
        case "DOC", "DOCX": return .blue
        case "XLS", "XLSX": return .green
        case "PPT", "PPTX": return .orange
        case "ZIP", "RAR", "7Z", "TAR", "GZ": return .purple
        case "JPG", "JPEG", "PNG", "GIF", "SVG", "WEBP": return .pink
        case "MP4", "MOV", "AVI", "MKV": return .indigo
        case "MP3", "WAV", "FLAC", "AAC": return .teal
        default: return .gray
        }
    }
}
