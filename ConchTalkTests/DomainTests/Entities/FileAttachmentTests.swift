/// 文件说明：FileAttachmentTests，测试 FileAttachment 实体的属性、扩展名提取与大小格式化。
import Testing
@testable import ConchTalk
import Foundation

@Suite("FileAttachment Entity")
struct FileAttachmentTests {

    // MARK: - 基本属性

    @Test("基本属性：id、fileName、fileSize、mimeType、data 正确存储")
    func basicProperties() {
        let id = UUID()
        let data = Data("hello".utf8)
        let attachment = FileAttachment(
            id: id,
            fileName: "document.pdf",
            fileSize: 1024,
            mimeType: "application/pdf",
            data: data
        )
        #expect(attachment.id == id)
        #expect(attachment.fileName == "document.pdf")
        #expect(attachment.fileSize == 1024)
        #expect(attachment.mimeType == "application/pdf")
        #expect(attachment.data == data)
    }

    // MARK: - fileExtension 大写

    @Test("fileExtension：返回大写扩展名（如 .gz → GZ）")
    func fileExtensionUppercase() {
        let attachment = TestFixtures.makeFileAttachment(fileName: "archive.gz")
        #expect(attachment.fileExtension == "GZ")
    }

    @Test("fileExtension：多字节扩展名返回大写（如 .xlsx → XLSX）")
    func fileExtensionMultiCharUppercase() {
        let attachment = TestFixtures.makeFileAttachment(fileName: "report.xlsx")
        #expect(attachment.fileExtension == "XLSX")
    }

    @Test("fileExtension：小写扩展名转为大写（如 .txt → TXT）")
    func fileExtensionLowercaseToUpper() {
        let attachment = TestFixtures.makeFileAttachment(fileName: "readme.txt")
        #expect(attachment.fileExtension == "TXT")
    }

    // MARK: - 无扩展名返回 FILE

    @Test("fileExtension：无扩展名时返回 FILE")
    func fileExtensionNoExtension() {
        let attachment = TestFixtures.makeFileAttachment(fileName: "Makefile")
        #expect(attachment.fileExtension == "FILE")
    }

    @Test("fileExtension：空文件名时返回 FILE")
    func fileExtensionEmptyFileName() {
        let attachment = TestFixtures.makeFileAttachment(fileName: "")
        #expect(attachment.fileExtension == "FILE")
    }

    // MARK: - formattedSize

    @Test("formattedSize：非空字符串（ByteCountFormatter 有输出）")
    func formattedSizeNotEmpty() {
        let attachment = TestFixtures.makeFileAttachment(fileSize: 2_400_000)
        #expect(!attachment.formattedSize.isEmpty)
    }

    @Test("formattedSize：零字节时也有输出")
    func formattedSizeZero() {
        let attachment = TestFixtures.makeFileAttachment(fileSize: 0)
        #expect(!attachment.formattedSize.isEmpty)
    }

    // MARK: - 唯一 ID

    @Test("唯一 ID：两个默认构造的 FileAttachment id 不同")
    func uniqueIDs() {
        let a1 = TestFixtures.makeFileAttachment()
        let a2 = TestFixtures.makeFileAttachment()
        #expect(a1.id != a2.id)
    }

    @Test("指定 ID：构造时传入 UUID 则使用该值")
    func specifiedID() {
        let fixedID = UUID()
        let attachment = TestFixtures.makeFileAttachment(id: fixedID)
        #expect(attachment.id == fixedID)
    }
}
