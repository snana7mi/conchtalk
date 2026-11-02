/// 文件说明：RemoteFileBrowserModel，通过 SFTP 浏览远端目录并读取文件预览。
import Foundation

/// RemoteFileBrowserModel：
/// 只做目录列举和读取。下载与附加到聊天由界面拿字节后完成。
@MainActor
@Observable
final class RemoteFileBrowserModel {
    private let client: SSHClientProtocol
    var path: String
    private(set) var entries: [RemoteFileEntry] = []
    var isLoading = false
    var errorMessage: String?
    var preview: RemoteFilePreview?
    var previewName: String?

    init(client: SSHClientProtocol, path: String = ".") {
        self.client = client
        self.path = path
    }

    func loadInitial() async {
        if path == "." {
            let pwd = try? await client.execute(command: "pwd", timeout: 10)
            let trimmed = pwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            path = trimmed.hasPrefix("/") ? RemotePath.normalize(trimmed) : "/"
        }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        let directory = RemotePath.normalize(path)
        path = directory
        do {
            entries = try await client.sftpListDirectory(path: directory)
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func open(_ entry: RemoteFileEntry) async {
        guard entry.isDirectory else { return }
        path = entry.path
        await reload()
    }

    func goUp() async {
        guard let parent = RemotePath.parent(of: path) else { return }
        path = parent
        await reload()
    }

    func loadPreview(for entry: RemoteFileEntry) async {
        previewName = entry.name
        preview = nil
        errorMessage = nil
        do {
            let size = try await client.sftpFileSize(path: entry.path)
            let limit = RemoteFilePreviewPolicy.previewReadLimit(for: entry.name)
            if Int64(size) > limit {
                preview = .tooLarge(Int64(size))
                return
            }
            let data = try await client.sftpReadFile(path: entry.path)
            preview = RemoteFilePreviewPolicy.preview(fileName: entry.name, data: data)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func readFile(_ entry: RemoteFileEntry) async throws -> Data {
        let size = try await client.sftpFileSize(path: entry.path)
        if Int64(size) > RemoteFilePreviewPolicy.maxTransferBytes {
            throw RemoteFileTransferError.tooLarge(Int64(size))
        }
        return try await client.sftpReadFile(path: entry.path)
    }
}

/// RemoteFileTransferError：读取超过聊天附件上限的远端文件。
nonisolated enum RemoteFileTransferError: Error, Equatable {
    case tooLarge(Int64)
}
