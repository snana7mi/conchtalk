/// 文件说明：DirectAgentResumeStore，按服务器 / 代理 / 工作目录记录最近的代理会话 ID，供直连模式恢复会话。
import Foundation

/// DirectAgentResumeStore：
/// 直连模式重新连接同一服务器上的同一代理与目录时，用记录的会话 ID 恢复上下文
///（ACP session/resume|load、Claude Code `--resume`、Codex `thread/resume`）。
/// - 只保存会话 ID 与更新时间，不保存任何对话内容。
/// - 超过 `maxAge` 的记录视为过期（远端会话可能已被清理），直接新建。
/// - 清空上下文（context break）时调用 `clear` 强制下次新建。
nonisolated struct DirectAgentResumeStore: @unchecked Sendable {
    private let defaults: UserDefaults
    /// 记录有效期：14 天。
    static let maxAge: TimeInterval = 14 * 24 * 3600

    private struct Record: Codable {
        let sessionId: String
        let updatedAt: Date
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(serverID: UUID, agentType: AgentType, cwd: String?) -> String {
        let directory = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "directAgentResume.\(serverID.uuidString).\(agentType.rawValue).\(directory.isEmpty ? "~" : directory)"
    }

    /// 读取可恢复的会话 ID（不存在、过期或格式不安全时返回 nil）。
    func sessionId(serverID: UUID, agentType: AgentType, cwd: String?, now: Date = .now) -> String? {
        let key = Self.key(serverID: serverID, agentType: agentType, cwd: cwd)
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        guard now.timeIntervalSince(record.updatedAt) < Self.maxAge,
              AgentSessionIdValidator.isSafe(record.sessionId) else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return record.sessionId
    }

    func save(_ sessionId: String, serverID: UUID, agentType: AgentType, cwd: String?, now: Date = .now) {
        guard AgentSessionIdValidator.isSafe(sessionId),
              let data = try? JSONEncoder().encode(Record(sessionId: sessionId, updatedAt: now)) else { return }
        defaults.set(data, forKey: Self.key(serverID: serverID, agentType: agentType, cwd: cwd))
    }

    func clear(serverID: UUID, agentType: AgentType, cwd: String?) {
        defaults.removeObject(forKey: Self.key(serverID: serverID, agentType: agentType, cwd: cwd))
    }
}
