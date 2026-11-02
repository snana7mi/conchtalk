/// 文件说明：RemoteCommandSupervisor，把远端命令放进独立进程组，超时后只结束该组。
import Foundation

/// RemoteCommandSupervisor：
/// 生成远端包装脚本：优先 `setsid` 记录会话首领 PID，到时 `kill` 进程组。
/// SSH 连接保持不动；只有包装脚本自己退出后，执行通道才会结束。
nonisolated enum RemoteCommandSupervisor {
    /// 工具层允许的最短超时（秒）。
    static let minimumTimeout: TimeInterval = 1
    /// 工具层允许的最长超时（秒）。
    static let maximumTimeout: TimeInterval = 600
    /// 未指定超时时使用的秒数。
    static let defaultTimeout: TimeInterval = 30
    /// 包装脚本在确认超时后使用的退出码。
    static let timeoutExitCode = 124
    /// 写入标准错误、用来区分「用户命令自己退出 124」和「包装脚本杀进程」。
    static let timeoutMarker = "__CONCHTALK_TIMEOUT__"

    /// 把超时夹到 1...600 秒。非有限数值回落到默认值。
    static func clamp(_ timeout: TimeInterval) -> TimeInterval {
        guard timeout.isFinite else { return defaultTimeout }
        return min(maximumTimeout, max(minimumTimeout, timeout))
    }

    /// 本次命令用来记录进程组首领 PID 的临时文件。
    static func pidFilePath(token: String) -> String {
        "/tmp/conchtalk-\(token).pid"
    }

    /// 包装用户命令。超时后结束其进程组，并用标记 + 退出码通知调用方。
    /// - Parameters:
    ///   - command: 原始命令。
    ///   - pidFile: PID 文件绝对路径。
    ///   - timeout: 期望超时；会先夹紧。
    static func wrap(command: String, pidFile: String, timeout: TimeInterval) -> String {
        let seconds = max(1, Int(clamp(timeout).rounded(.up)))
        let pid = shellEscape(pidFile)
        let flag = shellEscape(pidFile + ".timedout")
        let cmd = shellEscape(command)
        // 无 setsid 时只杀记录到的 PID，避免 `-PGID` 误伤当前 SSH 会话。
        return """
        pid=\(pid)
        flag=\(flag)
        rm -f "$pid" "$flag"
        use_group=0
        if command -v setsid >/dev/null 2>&1 && setsid --wait true >/dev/null 2>&1; then
          use_group=1
          setsid --wait sh -c 'printf %s "$$" > "$1"; exec sh -c "$2"' sh "$pid" \(cmd) &
        else
          sh -c 'printf %s "$$" > "$1"; exec sh -c "$2"' sh "$pid" \(cmd) &
        fi
        leader=$!
        (
          sleep \(seconds)
          echo 1 > "$flag"
          target=$(tr -cd '0-9' < "$pid" 2>/dev/null || true)
          if [ -n "$target" ]; then
            if [ "$use_group" -eq 1 ]; then
              kill -TERM "-$target" 2>/dev/null || kill -TERM "$target" 2>/dev/null || true
              sleep 1
              kill -KILL "-$target" 2>/dev/null || kill -KILL "$target" 2>/dev/null || true
            else
              kill -TERM "$target" 2>/dev/null || true
              sleep 1
              kill -KILL "$target" 2>/dev/null || true
            fi
          else
            kill -TERM "$leader" 2>/dev/null || true
          fi
        ) &
        watcher=$!
        wait "$leader"
        rc=$?
        kill "$watcher" 2>/dev/null || true
        wait "$watcher" 2>/dev/null || true
        if [ -f "$flag" ]; then
          rm -f "$pid" "$flag"
          echo '\(timeoutMarker)' >&2
          exit \(timeoutExitCode)
        fi
        rm -f "$pid" "$flag"
        exit "$rc"
        """
    }

    /// 仅当退出码与标记同时出现时，才把结果当成监督超时。
    static func isTimeoutResult(exitCode: Int, stdout: String, stderr: String) -> Bool {
        exitCode == timeoutExitCode
            && (stdout.contains(timeoutMarker) || stderr.contains(timeoutMarker))
    }
}
