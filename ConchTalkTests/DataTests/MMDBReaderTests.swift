/// 文件说明：MMDBReaderTests，验证离线 IP 国家库读取结果。
import Testing
import Foundation
@testable import ConchTalk

@Suite("MMDBReader")
struct MMDBReaderTests {

    @Test("公开 IPv4 能从本地 MMDB 查到国家代码")
    func publicIPv4ResolvesToCountryCode() {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let projectRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = projectRootURL
            .appendingPathComponent("Sources/Resources/dbip-country.mmdb")
        let reader = MMDBReader(url: url)
        let code = reader?.countryCode(for: "64.81.114.234")

        #expect(reader != nil)
        #expect(code != nil)
    }
}
