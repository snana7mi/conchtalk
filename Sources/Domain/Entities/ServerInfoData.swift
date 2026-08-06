/// 文件说明：ServerInfoData，服务器硬件信息数据模型。

import Foundation

/// ServerInfoData：
/// 服务器系统与硬件信息的值类型容器，包含静态信息（OS、CPU 型号）和动态信息（利用率、进程）。
struct ServerInfoData: Sendable {
    // 基本信息（首次获取，不刷新）
    var osVersion: String = ""
    var hostname: String = ""
    var cpuModel: String = ""
    var coreCount: Int = 0
    var ipAddress: String = ""

    // 动态数据（每秒刷新）
    var uptime: String = ""
    var cpuUsagePerCore: [Double] = []   // 每核利用率 0.0-1.0
    var memoryUsed: UInt64 = 0           // bytes
    var memoryTotal: UInt64 = 0
    var memoryAvailable: UInt64 = 0
    var diskUsages: [DiskUsage] = []
    var topProcesses: [ProcessInfo] = []

    /// 内存利用率百分比 0.0-1.0
    var memoryUsagePercent: Double {
        guard memoryTotal > 0 else { return 0 }
        return Double(memoryUsed) / Double(memoryTotal)
    }
}

/// DiskUsage：单个挂载点的磁盘用量信息。
struct DiskUsage: Sendable, Identifiable {
    var id: String { mountPoint }
    var mountPoint: String
    var used: String
    var total: String
    var percentage: Int
}

/// ProcessInfo：单个进程的资源占用信息。
struct ProcessInfo: Sendable, Identifiable {
    var id: String { "\(pid)" }
    var pid: Int
    var name: String
    var cpuPercent: Double
    var memPercent: Double
}

/// ServerInfoLoadingState：页面加载状态。
enum ServerInfoLoadingState: Sendable, Equatable {
    case loading
    case loaded
    case unsupported
    case error(String)
    case disconnected
}

/// ProcessSortMode：进程排序模式。
enum ProcessSortMode: String, CaseIterable, Sendable {
    case cpu = "CPU"
    case mem = "MEM"
}
