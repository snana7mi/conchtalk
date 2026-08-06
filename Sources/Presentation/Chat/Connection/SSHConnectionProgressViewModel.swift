/// 文件说明：SSHConnectionProgressViewModel，管理 SSH 连接进度动画的分阶段状态与日志推进。
import SwiftUI

/// 单行日志的类型，决定渲染颜色。
enum LogLineType: Sendable {
    case info
    case success
    case error
}

/// 日志区的一行文本。
struct LogLine: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let type: LogLineType
}

/// 阶段执行状态。
enum StageStatus: Sendable {
    case pending
    case active
    case completed
    case failed
}

/// 时间线上的一个连接阶段。
struct ConnectionStage: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let logMessages: [String]
    var status: StageStatus = .pending
}

/// SSHConnectionProgressViewModel：
/// 驱动终端风格的分阶段连接进度动画。动画在前台播放，真实连接在后台并行执行，
/// 连接结果决定动画最终走向（快进完成 or 失败变红）。
@Observable
final class SSHConnectionProgressViewModel {
    /// 所有阶段。
    var stages: [ConnectionStage] = []
    /// 日志区已显示的行。
    var logLines: [LogLine] = []
    /// 动画是否已全部结束。
    var isFinished = false

    /// 真实连接结果；由外部通过 `reportConnectionResult` 写入。
    private var connectionResult: Result<Void, Error>?
    /// 动画结束后恢复等待方的 continuation。
    private var completionContinuation: CheckedContinuation<Void, Never>?

    private let host: String
    private let port: Int
    private let username: String
    private let authMethod: Server.AuthMethod

    init(server: Server) {
        self.host = server.host
        self.port = server.port
        self.username = server.username
        self.authMethod = server.authMethod
        self.stages = Self.buildStages(server: server)
    }

    // MARK: - 构建阶段

    private static func buildStages(server: Server) -> [ConnectionStage] {
        let authMethodLabel: String
        switch server.authMethod {
        case .password: authMethodLabel = "password"
        case .privateKey: authMethodLabel = "publickey"
        }

        let bundle = LanguageSettings.currentBundle
        return [
            ConnectionStage(
                title: String(localized: "Initialize Config", bundle: bundle),
                logMessages: [
                    "Loading SSH client configuration...",
                    "Protocol: SSH-2.0",
                    "Key exchange algorithms: curve25519-sha256",
                    "Cipher: aes256-gcm",
                ]
            ),
            ConnectionStage(
                title: String(localized: "Connect to Server", bundle: bundle),
                logMessages: [
                    "Resolving \(server.host)...",
                    "Connecting to \(server.host):\(server.port)...",
                    "TCP connection established",
                    "Remote: SSH-2.0-OpenSSH",
                ]
            ),
            ConnectionStage(
                title: String(localized: "Configure Protocol", bundle: bundle),
                logMessages: [
                    "Negotiating key exchange...",
                    "KEXECDH: curve25519-sha256",
                    "Host key: ssh-ed25519 SHA256:...",
                    "Encryption negotiated",
                ]
            ),
            ConnectionStage(
                title: String(localized: "Authenticate User", bundle: bundle),
                logMessages: [
                    "Authenticating as \(server.username)...",
                    "Method: \(authMethodLabel)",
                    "Authentication successful",
                ]
            ),
            ConnectionStage(
                title: String(localized: "Connected", bundle: bundle),
                logMessages: [
                    "Session established",
                    "Channel opened",
                    "Ready",
                ]
            ),
        ]
    }

    // MARK: - 公开 API

    /// 接收真实 SSH 连接的结果。
    func reportConnectionResult(_ result: Result<Void, Error>) {
        connectionResult = result
    }

    /// 等待整个动画流程结束（含失败停顿）。调用方会在此挂起。
    func waitForCompletion() async {
        if isFinished { return }
        await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
    }

    /// 启动动画 Task，逐阶段、逐行推进日志。
    /// - Note: 所有退出路径（含取消）都会调用 `finishAnimation()`，确保 `waitForCompletion()` 不会永远挂起。
    func startAnimation() async {
        // 前两个阶段（0, 1）为纯模拟阶段，可以自由推进
        // 后三个阶段（2, 3, 4）需要确认连接结果后才能推进
        let gateStageIndex = 2

        for stageIndex in stages.indices {
            guard !Task.isCancelled else { finishAnimation(); return }

            // 从第 gateStageIndex 阶段起，必须先拿到连接结果才继续
            if stageIndex >= gateStageIndex && connectionResult == nil {
                while connectionResult == nil && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard !Task.isCancelled else { finishAnimation(); return }
            }

            // 检查失败 — 进入新阶段前就拦截
            if case .failure(let error) = connectionResult {
                stages[stageIndex].status = .failed
                logLines.append(LogLine(text: "Error: \(error.localizedDescription)", type: .error))
                try? await Task.sleep(for: .seconds(2))
                finishAnimation()
                return
            }

            // 标记当前阶段为 active
            stages[stageIndex].status = .active

            // 连接已成功且在后半段 → 快进
            let fastForward = connectionResult != nil && stageIndex >= gateStageIndex

            let messages = stages[stageIndex].logMessages
            for (lineIndex, msg) in messages.enumerated() {
                guard !Task.isCancelled else { finishAnimation(); return }

                // 逐行推进中再次检查失败（处理阶段内收到失败的情况）
                if case .failure(let error) = connectionResult {
                    stages[stageIndex].status = .failed
                    logLines.append(LogLine(text: msg, type: .error))
                    logLines.append(LogLine(text: "Error: \(error.localizedDescription)", type: .error))
                    try? await Task.sleep(for: .seconds(2))
                    finishAnimation()
                    return
                }

                let lineType: LogLineType = (lineIndex == messages.count - 1 && stageIndex == stages.count - 1) ? .success : .info
                logLines.append(LogLine(text: msg, type: lineType))

                let delay = fastForward ? 50 : Int.random(in: 150...250)
                try? await Task.sleep(for: .milliseconds(delay))
            }

            // 阶段完成
            stages[stageIndex].status = .completed

            // 阶段间间隔
            if stageIndex < stages.count - 1 {
                let gap = fastForward ? 100 : Int.random(in: 300...500)
                try? await Task.sleep(for: .milliseconds(gap))
            }
        }

        // 最后停留 0.5 秒
        try? await Task.sleep(for: .milliseconds(500))
        finishAnimation()
    }

    // MARK: - 内部

    private func finishAnimation() {
        isFinished = true
        completionContinuation?.resume()
        completionContinuation = nil
    }
}
