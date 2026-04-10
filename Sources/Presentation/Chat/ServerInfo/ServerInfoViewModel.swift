/// 文件说明：ServerInfoViewModel，管理服务器硬件信息的获取、解析与定时刷新。

import Foundation
import Observation

/// ServerInfoViewModel：
/// 通过 SSH 执行系统命令获取服务器信息，委托 ServerInfoParser 解析输出并驱动 UI 更新。
/// 负责生命周期管理（启动监控、定时刷新）。
@Observable final class ServerInfoViewModel {

    // MARK: - 公开属性

    let server: Server
    let sshClient: SSHClientProtocol
    var data: ServerInfoData = ServerInfoData()
    var loadingState: ServerInfoLoadingState = .loading
    var processSortMode: ProcessSortMode = .cpu

    // MARK: - 内部状态

    private var previousProcStat: [ServerInfoParser.CpuSnapshot] = []

    // MARK: - 初始化

    init(server: Server, sshClient: SSHClientProtocol) {
        self.server = server
        self.sshClient = sshClient
    }

    // MARK: - 生命周期

    /// 从 View 的 .task {} 或 Retry 按钮调用，检测 OS 类型后开始定时刷新。
    /// 重复调用时会取消上一次的刷新循环，避免并发。
    func startMonitoring() async {
        loadingState = .loading

        do {
            // 检测是否为 Linux
            let osType = try await sshClient.execute(command: "uname -s").strippingANSIEscapes().trimmingCharacters(in: .whitespacesAndNewlines)
            guard osType == "Linux" else {
                loadingState = .unsupported
                return
            }

            // 获取静态信息
            await fetchStaticInfo()
            loadingState = .loaded

            // 进入刷新循环
            while !Task.isCancelled {
                await fetchDynamicInfo()
                try await Task.sleep(for: .seconds(1))
            }
        } catch is CancellationError {
            // 正常取消，不处理
        } catch {
            // 区分 SSH 断连和其他错误
            let desc = error.localizedDescription
            if desc.contains("disconnect") || desc.contains("closed") || desc.contains("reset") {
                loadingState = .disconnected
            } else {
                loadingState = .error(desc)
            }
        }
    }

    /// 公开方法，供测试使用。执行一次完整数据获取（不进入刷新循环）。
    func fetchInitialData() async {
        do {
            let osType = try await sshClient.execute(command: "uname -s").strippingANSIEscapes().trimmingCharacters(in: .whitespacesAndNewlines)
            guard osType == "Linux" else {
                loadingState = .unsupported
                return
            }
            await fetchStaticInfo()
            await fetchDynamicInfo()
            loadingState = .loaded
        } catch {
            loadingState = .error(error.localizedDescription)
        }
    }

    /// 获取静态信息：OS 版本、主机名、CPU 信息、IP 地址。
    func fetchStaticInfo() async {
        await withTaskGroup(of: (String, String).self) { group in
            let client = sshClient

            group.addTask { ("os", (try? await client.execute(command: "cat /etc/os-release"))?.strippingANSIEscapes() ?? "") }
            group.addTask { ("hostname", (try? await client.execute(command: "hostname"))?.strippingANSIEscapes() ?? "") }
            group.addTask { ("cpuinfo", (try? await client.execute(command: "cat /proc/cpuinfo"))?.strippingANSIEscapes() ?? "") }
            group.addTask { ("ip", (try? await client.execute(command: "hostname -I || echo unknown"))?.strippingANSIEscapes() ?? "") }

            for await (key, output) in group {
                switch key {
                case "os":
                    data.osVersion = ServerInfoParser.parseOsVersion(output)
                case "hostname":
                    data.hostname = output.trimmingCharacters(in: .whitespacesAndNewlines)
                case "cpuinfo":
                    let (model, count) = ServerInfoParser.parseCpuInfo(output)
                    data.cpuModel = model
                    data.coreCount = count
                case "ip":
                    // hostname -I 返回空格分隔的 IP 列表，取第一个
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    data.ipAddress = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
                default:
                    break
                }
            }
        }
    }

    /// 获取动态信息：CPU 利用率、内存、磁盘、进程、uptime。
    func fetchDynamicInfo() async {
        let sortFlag = processSortMode == .cpu ? "-pcpu" : "-pmem"

        await withTaskGroup(of: (String, String).self) { group in
            let client = sshClient

            group.addTask { ("procstat", (try? await client.execute(command: "cat /proc/stat"))?.strippingANSIEscapes() ?? "") }
            group.addTask { ("uptime", (try? await client.execute(command: "uptime"))?.strippingANSIEscapes() ?? "") }
            group.addTask { ("memory", (try? await client.execute(command: "cat /proc/meminfo"))?.strippingANSIEscapes() ?? "") }
            group.addTask { ("disk", (try? await client.execute(command: "df -h"))?.strippingANSIEscapes() ?? "") }
            group.addTask { ("ps", (try? await client.execute(command: "ps aux --sort=\(sortFlag) | head -6"))?.strippingANSIEscapes() ?? "") }

            for await (key, output) in group {
                switch key {
                case "procstat":
                    let current = ServerInfoParser.parseProcStat(output)
                    if !previousProcStat.isEmpty {
                        data.cpuUsagePerCore = ServerInfoParser.calculateCpuUsage(previous: previousProcStat, current: current)
                    }
                    previousProcStat = current
                case "uptime":
                    data.uptime = ServerInfoParser.parseUptime(output)
                case "memory":
                    let (used, total, available) = ServerInfoParser.parseMemory(output)
                    data.memoryUsed = used
                    data.memoryTotal = total
                    data.memoryAvailable = available
                case "disk":
                    data.diskUsages = ServerInfoParser.parseDiskUsage(output)
                case "ps":
                    data.topProcesses = ServerInfoParser.parseProcesses(output)
                default:
                    break
                }
            }
        }
    }

}
