/// 文件说明：RemoteFileBrowserTests，覆盖远端路径、目录整理、预览策略和浏览器读取。
import Testing
@testable import ConchTalk
import Foundation

@Suite("Remote file browser")
struct RemoteFileBrowserTests {
    @Test("路径折叠点号并拒绝把斜线写进文件名")
    func normalizesPaths() {
        #expect(RemotePath.normalize("/var/log/../tmp/./a") == "/var/tmp/a")
        #expect(RemotePath.normalize("/") == "/")
        #expect(RemotePath.normalize("/../../etc") == "/etc")
        #expect(RemotePath.joining(directory: "/var", name: "log") == "/var/log")
        #expect(RemotePath.joining(directory: "/", name: "etc") == "/etc")
        #expect(RemotePath.joining(directory: "/var", name: "a/b") == "/var/ab")
        #expect(RemotePath.parent(of: "/var/log") == "/var")
        #expect(RemotePath.parent(of: "/") == nil)
    }

    @Test("目录项跳过点目录，文件夹排在前面")
    func sortsDirectoryEntries() {
        let entries = RemoteDirectoryIndex.entries(directory: "/home", items: [
            .init(name: "..", longname: "d", permissions: 0o040755, size: nil),
            .init(name: "notes.txt", longname: "-rw-r--r--", permissions: 0o100644, size: 12),
            .init(name: "src", longname: "drwxr-xr-x", permissions: 0o040755, size: nil),
            .init(name: "b.txt", longname: "", permissions: nil, size: 1),
        ])
        #expect(entries.map(\.name) == ["src", "b.txt", "notes.txt"])
        #expect(entries[0].isDirectory)
        #expect(entries[0].path == "/home/src")
        #expect(!entries[1].isDirectory)
    }

    @Test("没有权限位时用长名称判断目录")
    func longnameMarksDirectory() {
        #expect(RemoteFileAttributes.isDirectory(permissions: nil, longname: "drwxr-xr-x"))
        #expect(!RemoteFileAttributes.isDirectory(permissions: nil, longname: "-rw-r--r--"))
        #expect(!RemoteFileAttributes.isDirectory(permissions: 0o120777, longname: "lrwxrwxrwx"))
    }

    @Test("文本、图片、过大和二进制的预览分类")
    func classifiesPreviews() {
        let text = RemoteFilePreviewPolicy.preview(fileName: "a.json", data: Data("{\"ok\":true}".utf8))
        #expect(text == .text("{\"ok\":true}"))

        let png = Data([0x89, 0x50, 0x4E, 0x47])
        #expect(RemoteFilePreviewPolicy.preview(fileName: "a.png", data: png) == .image(png))

        let binary = Data([0x00, 0x01, 0x02])
        #expect(RemoteFilePreviewPolicy.preview(fileName: "a.bin", data: binary) == .binary)

        let huge = Data(repeating: 0x61, count: RemoteFilePreviewPolicy.textPreviewLimit + 1)
        if case .tooLarge = RemoteFilePreviewPolicy.preview(fileName: "a.log", data: huge) {
        } else {
            Issue.record("expected tooLarge")
        }
        #expect(RemoteFilePreviewPolicy.previewReadLimit(for: "a.png") == RemoteFilePreviewPolicy.imagePreviewLimit)
    }

    @Test("下载写入临时文件并替换路径分隔符")
    func writesTemporaryDownload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try RemoteFileDownload.writeTemporary(fileName: "a/b.txt", data: Data("hi".utf8), directory: folder)
        #expect(url.lastPathComponent == "a_b.txt")
        #expect(try String(contentsOf: url, encoding: .utf8) == "hi")
    }

    @Test("浏览器从 pwd 进入家目录，并能预览文本")
    @MainActor
    func browserLoadsHomeAndPreviewsText() async {
        let client = MockSSHClient()
        client.executeResult = "/home/me\n"
        client.sftpListResult = [
            RemoteFileEntry(name: "notes.txt", path: "/home/me/notes.txt", isDirectory: false, size: 4)
        ]
        client.sftpFileSizeResult = 4
        client.sftpReadResult = Data("note".utf8)
        let model = RemoteFileBrowserModel(client: client)
        await model.loadInitial()
        #expect(model.path == "/home/me")
        #expect(model.entries.map(\.name) == ["notes.txt"])

        await model.loadPreview(for: model.entries[0])
        #expect(model.preview == .text("note"))
    }

    @Test("超过预览上限时不读取文件内容")
    @MainActor
    func browserSkipsOversizedPreview() async {
        let client = MockSSHClient()
        client.sftpFileSizeResult = UInt64(RemoteFilePreviewPolicy.textPreviewLimit + 10)
        let model = RemoteFileBrowserModel(client: client, path: "/tmp")
        let entry = RemoteFileEntry(name: "big.log", path: "/tmp/big.log", isDirectory: false, size: client.sftpFileSizeResult)
        await model.loadPreview(for: entry)
        if case .tooLarge = model.preview {
        } else {
            Issue.record("expected tooLarge preview")
        }
        #expect(!client.didCall("sftpReadFile"))
    }
}
