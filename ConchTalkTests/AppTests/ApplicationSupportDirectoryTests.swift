/// 文件说明：ApplicationSupportDirectoryTests，验证 Application Support 目录不会强制解包。
import Testing
@testable import ConchTalk
import Foundation

@Suite("ApplicationSupportDirectory")
struct ApplicationSupportDirectoryTests {
    @Test("候选列表为空时直接返回")
    func emptyListDoesNothing() {
        ApplicationSupportDirectory.ensureExists(urls: [])
    }

    @Test("只创建第一个候选目录")
    func createsFirstURLOnly() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conchtalk-support-\(UUID().uuidString)", isDirectory: true)
        let ignored = FileManager.default.temporaryDirectory
            .appendingPathComponent("conchtalk-support-ignored-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: ignored)
        }

        ApplicationSupportDirectory.ensureExists(urls: [root, ignored])

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(!FileManager.default.fileExists(atPath: ignored.path))
    }
}
