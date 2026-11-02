/// 文件说明：BackgroundCommandLauncher，用 nohup 与 setsid 把长命令挂到后台并写入日志。
import Foundation

/// BackgroundCommandLauncher：
/// 生成脱离 SSH 通道的启动脚本，以及只允许读取本目录日志的轮询脚本。
/// 远程进程自行保活；前台 agent 任务若还在跑，现有 Live Activity 会继续显示当前步骤。
enum BackgroundCommandLauncher {
    /// 后台日志与 PID 的固定目录。轮询工具拒绝这个目录以外的路径。
    static let directory = "/tmp/conchtalk-bg"
    /// 单次轮询最多返回的行数。
    static let maxTailLines = 200
    /// 未指定行数时返回的尾部行数。
    static let defaultTailLines = 80

    /// 为一轮后台命令分配日志与 PID 路径。
    static func paths(token: String = UUID().uuidString) -> (log: String, pid: String) {
        (log: "\(directory)/\(token).log", pid: "\(directory)/\(token).pid")
    }

    /// 把行数夹到 1...200。
    static func clampTailLines(_ lines: Int) -> Int {
        min(maxTailLines, max(1, lines))
    }

    /// 是否是本工具创建的日志路径（拒绝 `..` 和其他目录）。
    static func isManagedLogPath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(directory + "/"), !trimmed.hasSuffix("/") else { return false }
        let rest = trimmed.dropFirst(directory.count + 1)
        return !rest.isEmpty && !rest.contains("..") && !rest.contains("/")
    }

    /// 启动脚本：新会话 + nohup，标准输出和标准错误写入日志，立刻返回 PID。
    static func launchScript(command: String, logPath: String, pidPath: String) -> String {
        let cmd = shellEscape(command)
        let log = shellEscape(logPath)
        let pid = shellEscape(pidPath)
        let dir = shellEscape(directory)
        return """
        mkdir -p \(dir)
        rm -f \(pid)
        if command -v setsid >/dev/null 2>&1; then
          setsid nohup sh -c 'printf %s "$$" > "$1"; exec sh -c "$2"' sh \(pid) \(cmd) > \(log) 2>&1 < /dev/null &
        else
          nohup sh -c 'printf %s "$$" > "$1"; exec sh -c "$2"' sh \(pid) \(cmd) > \(log) 2>&1 < /dev/null &
        fi
        i=0
        while [ "$i" -lt 50 ]; do
          [ -s \(pid) ] && break
          i=$((i + 1))
          sleep 0.1
        done
        if [ ! -s \(pid) ]; then
          echo "failed to start background command" >&2
          exit 1
        fi
        echo "pid=$(tr -cd '0-9' < \(pid))"
        echo "log=\(logPath)"
        """
    }

    /// 轮询脚本：报告进程是否还在，并输出日志尾部。
    static func pollScript(logPath: String, pid: String?, tailLines: Int) -> String {
        let lines = clampTailLines(tailLines)
        let log = shellEscape(logPath)
        let status: String
        if let pid {
            status = """
            if kill -0 \(pid) 2>/dev/null; then echo status=running; else echo status=exited; fi
            """
        } else {
            status = "echo status=unknown"
        }
        return """
        log=\(log)
        if [ ! -f "$log" ]; then echo status=missing; exit 0; fi
        \(status)
        echo ---
        tail -n \(lines) "$log"
        """
    }
}
