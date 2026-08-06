/// 文件说明：PackageManagerDetectorTests，测试包管理器探测逻辑。
import Testing
@testable import ConchTalk

@Suite("PackageManagerDetector")
struct PackageManagerDetectorTests {
    @Test("normalize 支持别名与大小写")
    func normalizeAliases() {
        #expect(PackageManagerDetector.normalize("apt-get\n") == "apt")
        #expect(PackageManagerDetector.normalize("APT") == "apt")
        #expect(PackageManagerDetector.normalize("dnf") == "dnf")
    }

    @Test("normalize 对 unknown 与空值返回 nil")
    func normalizeUnknown() {
        #expect(PackageManagerDetector.normalize("unknown") == nil)
        #expect(PackageManagerDetector.normalize("   ") == nil)
    }

    @Test("detect 使用执行器输出")
    func detectFromExecutor() async {
        let detected = await PackageManagerDetector.detect(using: { _ in
            "zypper\n"
        })
        #expect(detected == "zypper")
    }
}
