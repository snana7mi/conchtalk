/// 文件说明：ServerInfoViewModelTests，验证服务器信息解析函数与 ViewModel 生命周期逻辑。

import Testing
@testable import ConchTalk
import Foundation

// MARK: - 解析测试

@Suite("ServerInfoParser")
@MainActor
struct ServerInfoParserTests {

    @Test("解析 /etc/os-release — Ubuntu")
    func parseOsRelease() {
        let output = """
        PRETTY_NAME="Ubuntu 24.04.1 LTS"
        NAME="Ubuntu"
        VERSION="24.04.1 LTS (Noble Numbat)"
        """
        let result = ServerInfoParser.parseOsVersion(output)
        #expect(result == "Ubuntu 24.04.1 LTS")
    }

    @Test("解析 /etc/os-release — CentOS")
    func parseOsReleaseCentos() {
        let output = """
        PRETTY_NAME="CentOS Stream 9"
        NAME="CentOS Stream"
        """
        let result = ServerInfoParser.parseOsVersion(output)
        #expect(result == "CentOS Stream 9")
    }

    @Test("解析 /proc/cpuinfo")
    func parseCpuInfo() {
        let output = """
        processor\t: 0
        model name\t: Intel(R) Xeon(R) CPU E5-2686 v4 @ 2.30GHz

        processor\t: 1
        model name\t: Intel(R) Xeon(R) CPU E5-2686 v4 @ 2.30GHz
        """
        let (model, count) = ServerInfoParser.parseCpuInfo(output)
        #expect(model == "Intel(R) Xeon(R) CPU E5-2686 v4 @ 2.30GHz")
        #expect(count == 2)
    }

    @Test("解析 /proc/meminfo 输出")
    func parseProcMeminfo() {
        let output = """
        MemTotal:       16384000 kB
        MemFree:         2830000 kB
        MemAvailable:    5000000 kB
        Buffers:          123456 kB
        Cached:          2345678 kB
        SwapTotal:       2097152 kB
        SwapFree:        2097152 kB
        """
        let (used, total, available) = ServerInfoParser.parseMemory(output)
        #expect(total == 16_384_000 * 1024)
        #expect(available == 5_000_000 * 1024)
        #expect(used == total - available)
    }

    @Test("解析 /proc/meminfo — 无 MemAvailable（老内核 fallback）")
    func parseProcMeminfoNoAvailable() {
        let output = """
        MemTotal:       8192000 kB
        MemFree:        4096000 kB
        Buffers:         512000 kB
        Cached:         1024000 kB
        """
        let (used, total, available) = ServerInfoParser.parseMemory(output)
        #expect(total == 8_192_000 * 1024)
        // fallback: available = free + buffers + cached
        #expect(available == (4_096_000 + 512_000 + 1_024_000) * 1024)
        #expect(used == total - available)
    }

    @Test("解析 df -h 输出")
    func parseDfOutput() {
        let output = """
        Filesystem      Size  Used Avail Use% Mounted on
        /dev/sda1        50G   23G   25G  48% /
        /dev/sdb1       500G  128G  348G  27% /home
        tmpfs           7.8G     0  7.8G   0% /dev/shm
        """
        let disks = ServerInfoParser.parseDiskUsage(output)
        #expect(disks.count == 2)
        #expect(disks[0].mountPoint == "/")
        #expect(disks[0].percentage == 48)
        #expect(disks[1].mountPoint == "/home")
    }

    @Test("解析 ps aux 输出")
    func parsePsOutput() {
        let output = """
        USER       PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND
        root      1234 45.2  3.1 123456 78901 ?        Ssl  Mar01  10:23 node /app/server.js
        www-data  5678 22.8  8.5 234567 89012 ?        S    Mar01   5:12 python3 app.py
        """
        let procs = ServerInfoParser.parseProcesses(output)
        #expect(procs.count == 2)
        #expect(procs[0].pid == 1234)
        #expect(procs[0].name == "node")
        #expect(procs[0].cpuPercent == 45.2)
        #expect(procs[0].memPercent == 3.1)
    }

    @Test("解析 /proc/stat 差值计算 CPU 利用率")
    func parseProcStatDelta() {
        let previous = """
        cpu  1000 0 500 8000 100 0 0 0
        cpu0 500 0 250 4000 50 0 0 0
        cpu1 500 0 250 4000 50 0 0 0
        """
        let current = """
        cpu  1100 0 600 8100 100 0 0 0
        cpu0 600 0 300 4020 50 0 0 0
        cpu1 500 0 300 4080 50 0 0 0
        """
        let prevSnapshot = ServerInfoParser.parseProcStat(previous)
        let currSnapshot = ServerInfoParser.parseProcStat(current)
        let usages = ServerInfoParser.calculateCpuUsage(previous: prevSnapshot, current: currSnapshot)
        #expect(usages.count == 2)
        // cpu0: total_delta=170, idle_delta=20, usage=150/170≈0.882
        #expect(usages[0] > 0.87)
        #expect(usages[0] < 0.90)
        // cpu1: total_delta=130, idle_delta=80, usage=50/130≈0.385
        #expect(usages[1] > 0.37)
        #expect(usages[1] < 0.40)
    }

    @Test("解析 uptime 输出")
    func parseUptime() {
        let output = " 14:23:45 up 42 days,  7:15,  2 users,  load average: 0.15, 0.10, 0.05"
        let result = ServerInfoParser.parseUptime(output)
        #expect(result.contains("42"))
    }
}

// MARK: - 生命周期测试

@Suite("ServerInfoViewModel Lifecycle")
@MainActor
struct ServerInfoViewModelLifecycleTests {

    private func makeServer() -> Server {
        Server(id: UUID(), name: "Test", host: "192.168.1.1", port: 22,
               username: "root", authMethod: .password)
    }

    @Test("非 Linux 系统设置为 unsupported")
    func nonLinuxDetection() async {
        let client = MockSSHClient()
        client.executeResult = "Darwin"
        let vm = ServerInfoViewModel(server: makeServer(), sshClient: client)
        await vm.startMonitoring()
        #expect(vm.loadingState == .unsupported)
    }

    @Test("SSH 错误设置为 error 状态")
    func sshErrorHandling() async {
        let client = MockSSHClient()
        client.executeError = SSHError.commandFailed("connection lost")
        let vm = ServerInfoViewModel(server: makeServer(), sshClient: client)
        await vm.startMonitoring()
        if case .error = vm.loadingState {
            // 预期的错误状态
        } else {
            Issue.record("Expected error state")
        }
    }
}
