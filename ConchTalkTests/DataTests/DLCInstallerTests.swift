/// 文件说明：DLCInstallerTests，测试 DLC 安装命令生成与结果解析。
import Testing
@testable import ConchTalk

@Suite("DLCInstaller")
struct DLCInstallerTests {

    @Test("安装命令包含 token 和正确的安装脚本地址")
    func installCommandContainsToken() {
        let cmd = DLCInstaller.buildInstallCommand(token: "dlc_abc123")
        #expect(cmd.contains("dlc_abc123"))
        #expect(cmd.contains("curl"))
        #expect(cmd.contains("conchtalk-dlc/main/install.sh"))
        #expect(cmd.contains("-t "))
    }

    @Test("解析安装成功输出")
    func parseSuccess() {
        let output = "[OK] ConchTalk DLC installation complete!"
        let result = DLCInstaller.parseInstallResult(output: output, exitCode: 0)
        #expect(result.success == true)
    }

    @Test("解析安装失败 - 非零退出码")
    func parseFailure() {
        let output = "[ERROR] This script must be run as root on Linux. Use sudo."
        let result = DLCInstaller.parseInstallResult(output: output, exitCode: 1)
        #expect(result.success == false)
        #expect(result.errorMessage != nil)
    }
}
