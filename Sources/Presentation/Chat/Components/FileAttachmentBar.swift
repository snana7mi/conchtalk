/// 文件说明：FileAttachmentBar，横向滚动展示已选附件列表。
import SwiftUI

/// FileAttachmentBar：
/// 以横向滚动方式展示用户选中的文件附件卡片，支持逐个删除。
struct FileAttachmentBar: View {
    let attachments: [FileAttachment]
    let onRemove: (FileAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    FileAttachmentCard(attachment: attachment) {
                        onRemove(attachment)
                    }
                }
            }
        }
    }
}
