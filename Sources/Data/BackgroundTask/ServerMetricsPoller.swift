/// 文件说明：ServerMetricsPoller，定时轮询远端服务器 CPU/内存使用率。
import Foundation

/// ServerMetricsPoller：
/// 每 10 秒通过 SSH 查询所有已连接服务器的 CPU 和内存使用率。
/// 切后台时启动，回前台时停止。
@MainActor
final class ServerMetricsPoller {
    struct Metrics: Sendable {
        let cpuUsage: Double
        let memoryUsage: Double
    }

    private let sshManager: SSHSessionManager
    private var pollingTask: Task<Void, Never>?
    private var cachedMetrics: [UUID: Metrics] = [:]
    private let interval: TimeInterval = 10.0

    /// 每次轮询完成后的回调。
    var onMetricsUpdated: (@MainActor () async -> Void)?

    init(sshManager: SSHSessionManager) {
        self.sshManager = sshManager
    }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollAllServers()
                try? await Task.sleep(for: .seconds(self.interval))
            }
        }
        print("[MetricsPoller] 已启动")
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        print("[MetricsPoller] 已停止")
    }

    func metrics(for serverID: UUID) -> Metrics? {
        cachedMetrics[serverID]
    }

    private func pollAllServers() async {
        let serverIDs = sshManager.activeConnectionIDs
        for serverID in serverIDs {
            guard let client = sshManager.getClient(for: serverID) else { continue }
            do {
                let metrics = try await fetchMetrics(client: client)
                cachedMetrics[serverID] = metrics
            } catch {
                print("[MetricsPoller] 探测失败 server=\(serverID): \(error)")
            }
        }
        let activeIDs = Set(serverIDs)
        for key in cachedMetrics.keys where !activeIDs.contains(key) {
            cachedMetrics.removeValue(forKey: key)
        }
        await onMetricsUpdated?()
    }

    /// 两次采样间隔 1 秒取 delta，与 daemon 的 metrics/collector.go 逻辑一致。
    private func fetchMetrics(client: NIOSSHClient) async throws -> Metrics {
        let command = """
            if [ -f /proc/stat ]; then \
                s1=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat); \
                sleep 1; \
                s2=$(awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9}' /proc/stat); \
                echo "$s1 $s2" | awk '{t1=0;t2=0;for(i=1;i<=8;i++){t1+=$i;t2+=$(i+8)} id1=$4+$5;id2=$12+$13; dt=t2-t1;di=id2-id1; printf "CPU:%.4f\\n",(dt>0?(dt-di)/dt:0)}'; \
                awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{printf "MEM:%.4f\\n", (t>0 ? (t-a)/t : 0)}' /proc/meminfo; \
            else \
                nproc=$(sysctl -n hw.ncpu 2>/dev/null || echo 1); \
                ps -A -o %cpu | awk -v n=$nproc 'NR>1{s+=$1} END{printf "CPU:%.4f\\n", (n>0?s/(n*100):0)}'; \
                vm_stat | awk '/Pages free:/{f=$3} /Pages inactive:/{i=$3} /Pages active:/{a=$3} /Pages wired down:/{w=$3} END{t=a+w+f+i; if(t>0) printf "MEM:%.4f\\n",(a+w)/t; else print "MEM:0.0000"}'; \
            fi || true
            """
        let rawOutput = try await client.execute(command: command)
        let output = rawOutput.strippingANSIEscapes()
        var cpu = 0.0
        var mem = 0.0
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("CPU:"), let val = Double(trimmed.dropFirst(4)) {
                cpu = min(max(val, 0), 1)
            } else if trimmed.hasPrefix("MEM:"), let val = Double(trimmed.dropFirst(4)) {
                mem = min(max(val, 0), 1)
            }
        }
        return Metrics(cpuUsage: cpu, memoryUsage: mem)
    }
}
