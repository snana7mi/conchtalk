/// 文件说明：ServerInfoParser，纯函数集合，解析 Linux 系统命令输出为结构化数据。

import Foundation

/// ServerInfoParser：
/// 包含所有服务器信息解析的静态函数，从 SSH 命令输出中提取 OS、CPU、内存、磁盘、进程等信息。
/// 纯函数设计，无副作用，便于独立测试。
enum ServerInfoParser {

    /// CpuSnapshot：/proc/stat 单行 CPU 计数器快照，用于差值计算利用率。
    struct CpuSnapshot: Sendable {
        var user: UInt64
        var nice: UInt64
        var system: UInt64
        var idle: UInt64
        var iowait: UInt64
        var irq: UInt64
        var softirq: UInt64
        var steal: UInt64

        var total: UInt64 { user + nice + system + idle + iowait + irq + softirq + steal }
    }

    /// 从 /etc/os-release 输出中提取 PRETTY_NAME。
    static func parseOsVersion(_ output: String) -> String {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PRETTY_NAME=") {
                var value = String(trimmed.dropFirst("PRETTY_NAME=".count))
                // 去除首尾引号
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                return value
            }
        }
        return ""
    }

    /// 从 /proc/cpuinfo 输出中解析 CPU 型号和核心数。
    static func parseCpuInfo(_ output: String) -> (model: String, count: Int) {
        var model = ""
        var count = 0

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("processor") {
                count += 1
            }
            if trimmed.hasPrefix("model name") && model.isEmpty {
                // 格式: model name\t: VALUE
                if let colonIndex = trimmed.firstIndex(of: ":") {
                    model = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return (model, count)
    }

    /// 从 /proc/meminfo 输出中解析内存用量。
    /// /proc/meminfo 格式稳定（内核接口），不受 procps-ng 版本或 locale 影响。
    /// 值单位为 kB，转换为 bytes 返回。
    static func parseMemory(_ output: String) -> (used: UInt64, total: UInt64, available: UInt64) {
        var total: UInt64 = 0
        var available: UInt64 = 0
        var free: UInt64 = 0
        var buffers: UInt64 = 0
        var cached: UInt64 = 0
        var foundAvailable = false

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 格式: "MemTotal:       16384000 kB"
            let parts = trimmed.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0]
            // 值部分去掉 " kB" 后缀，提取数字
            let valuePart = parts[1].trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " kB", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard let kb = UInt64(valuePart) else { continue }

            switch key {
            case "MemTotal":
                total = kb * 1024
            case "MemAvailable":
                available = kb * 1024
                foundAvailable = true
            case "MemFree":
                free = kb * 1024
            case "Buffers":
                buffers = kb * 1024
            case "Cached":
                cached = kb * 1024
            default:
                break
            }
        }

        // MemAvailable 在 Linux 3.14+ 可用；老内核用 free + buffers + cached 近似
        if !foundAvailable {
            available = free + buffers + cached
        }
        let used = total > available ? total - available : 0

        return (used, total, available)
    }

    /// 从 `df -h` 输出中解析磁盘用量，过滤虚拟文件系统。
    static func parseDiskUsage(_ output: String) -> [DiskUsage] {
        let excludedFilesystems: Set<String> = ["tmpfs", "devtmpfs", "udev", "overlay", "shm"]
        var result: [DiskUsage] = []
        let lines = output.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            // 跳过首行表头
            guard index > 0 else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            // 格式: Filesystem Size Used Avail Use% Mounted_on
            guard parts.count >= 6 else { continue }

            let filesystem = String(parts[0])
            // 检查是否需要过滤
            if excludedFilesystems.contains(where: { filesystem.contains($0) }) {
                continue
            }

            let total = String(parts[1])
            let used = String(parts[2])
            let usePercentStr = String(parts[4]).replacingOccurrences(of: "%", with: "")
            let percentage = Int(usePercentStr) ?? 0
            let mountPoint = String(parts[5])

            result.append(DiskUsage(
                mountPoint: mountPoint,
                used: used,
                total: total,
                percentage: percentage
            ))
        }

        return result
    }

    /// 从 `ps aux` 输出中解析进程信息。
    static func parseProcesses(_ output: String) -> [ProcessInfo] {
        var result: [ProcessInfo] = []
        let lines = output.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            // 跳过首行表头
            guard index > 0 else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            // ps aux 格式: USER PID %CPU %MEM VSZ RSS TTY STAT START TIME COMMAND...
            guard parts.count >= 11 else { continue }

            let pid = Int(parts[1]) ?? 0
            let cpuPercent = Double(parts[2]) ?? 0
            let memPercent = Double(parts[3]) ?? 0
            // COMMAND 是第 11 列（index 10），取二进制名（去掉路径和参数）
            let fullCommand = String(parts[10])
            let binaryName = fullCommand.split(separator: "/").last.map(String.init) ?? fullCommand

            result.append(ProcessInfo(
                pid: pid,
                name: binaryName,
                cpuPercent: cpuPercent,
                memPercent: memPercent
            ))
        }

        return result
    }

    /// 从 /proc/stat 输出中解析每核 CPU 计数器快照。
    static func parseProcStat(_ output: String) -> [CpuSnapshot] {
        var snapshots: [CpuSnapshot] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 只处理 cpuN 行，跳过汇总的 "cpu " 行
            guard trimmed.hasPrefix("cpu") else { continue }
            let afterCpu = trimmed.dropFirst(3)
            guard let firstChar = afterCpu.first, firstChar.isNumber else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            // parts[0] = cpuN, [1..8] = user nice system idle iowait irq softirq steal
            guard parts.count >= 9 else { continue }

            snapshots.append(CpuSnapshot(
                user: UInt64(parts[1]) ?? 0,
                nice: UInt64(parts[2]) ?? 0,
                system: UInt64(parts[3]) ?? 0,
                idle: UInt64(parts[4]) ?? 0,
                iowait: UInt64(parts[5]) ?? 0,
                irq: UInt64(parts[6]) ?? 0,
                softirq: UInt64(parts[7]) ?? 0,
                steal: UInt64(parts[8]) ?? 0
            ))
        }

        return snapshots
    }

    /// 基于前后两次 CpuSnapshot 差值计算每核利用率（0.0-1.0）。
    static func calculateCpuUsage(previous: [CpuSnapshot], current: [CpuSnapshot]) -> [Double] {
        let count = min(previous.count, current.count)
        var usages: [Double] = []

        for i in 0..<count {
            let totalDelta = current[i].total - previous[i].total
            let idleDelta = current[i].idle - previous[i].idle
            guard totalDelta > 0 else {
                usages.append(0)
                continue
            }
            let usage = Double(totalDelta - idleDelta) / Double(totalDelta)
            usages.append(usage)
        }

        return usages
    }

    /// 从 uptime 输出中提取运行时间描述。
    static func parseUptime(_ output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // 典型格式: " 14:23:45 up 42 days,  7:15,  2 users, ..."
        // 找到 "up " 开始，到 ", N user" 结束
        guard let upRange = trimmed.range(of: "up ") else { return trimmed }
        let afterUp = trimmed[upRange.upperBound...]

        // 截取到 "user" 之前的最后一个逗号
        if let userRange = afterUp.range(of: "user") {
            var portion = afterUp[afterUp.startIndex..<userRange.lowerBound]
            // 去掉末尾的 ", N "（数字和逗号）
            while let last = portion.last, last == " " || last == "," || last.isNumber {
                portion = portion.dropLast()
            }
            return portion.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(afterUp).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
