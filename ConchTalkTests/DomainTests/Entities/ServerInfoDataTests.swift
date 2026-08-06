/// 文件说明：ServerInfoDataTests，验证服务器信息数据模型。

import Testing
@testable import ConchTalk

@Suite("ServerInfoData")
struct ServerInfoDataTests {

    @Test("默认值初始化")
    func defaultValues() {
        let data = ServerInfoData()
        #expect(data.osVersion.isEmpty)
        #expect(data.hostname.isEmpty)
        #expect(data.cpuModel.isEmpty)
        #expect(data.coreCount == 0)
        #expect(data.ipAddress.isEmpty)
        #expect(data.uptime.isEmpty)
        #expect(data.cpuUsagePerCore.isEmpty)
        #expect(data.memoryUsed == 0)
        #expect(data.memoryTotal == 0)
        #expect(data.memoryAvailable == 0)
        #expect(data.diskUsages.isEmpty)
        #expect(data.topProcesses.isEmpty)
    }

    @Test("DiskUsage id 等于 mountPoint")
    func diskUsageId() {
        let disk = DiskUsage(mountPoint: "/home", used: "50G", total: "100G", percentage: 50)
        #expect(disk.id == "/home")
    }

    @Test("ProcessInfo id 等于 pid 字符串")
    func processInfoId() {
        let proc = ProcessInfo(pid: 1234, name: "node", cpuPercent: 45.2, memPercent: 3.1)
        #expect(proc.id == "1234")
    }

    @Test("memoryUsagePercent 计算正确")
    func memoryUsagePercent() {
        var data = ServerInfoData()
        data.memoryTotal = 16_000_000_000
        data.memoryUsed = 10_880_000_000
        #expect(data.memoryUsagePercent >= 0.67)
        #expect(data.memoryUsagePercent <= 0.69)
    }

    @Test("memoryUsagePercent 总量为零时返回零")
    func memoryUsagePercentZeroTotal() {
        let data = ServerInfoData()
        #expect(data.memoryUsagePercent == 0)
    }
}
