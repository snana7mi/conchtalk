/// 文件说明：ServerBatchReport，同一任务在一组服务器上的逐台结果与对比摘要。
import Foundation

/// ServerBatchServerResult：一台服务器的批处理结果。审批不在这里合并。
nonisolated struct ServerBatchServerResult: Equatable, Sendable, Identifiable {
    var id: UUID { serverID }
    var serverID: UUID
    var serverName: String
    var succeeded: Bool
    var summary: String

    init(serverID: UUID, serverName: String, succeeded: Bool, summary: String) {
        self.serverID = serverID
        self.serverName = serverName
        self.succeeded = succeeded
        self.summary = summary
    }
}

/// ServerBatchReport：一组服务器的结果，以及给用户看的对比文本。
nonisolated struct ServerBatchReport: Equatable, Sendable {
    var groupName: String
    var prompt: String
    var results: [ServerBatchServerResult]
    var markdown: String
}

/// ServerBatchExecuting：在一台服务器上执行提示词。实现必须使用该服务器自己的审批通道。
protocol ServerBatchExecuting: Sendable {
    func run(server: Server, prompt: String) async -> ServerBatchServerResult
}

/// ServerBatchReportBuilder：把逐台结果收成可比较的摘要。
nonisolated enum ServerBatchReportBuilder {
    static func make(
        groupName: String,
        prompt: String,
        results: [ServerBatchServerResult]
    ) -> ServerBatchReport {
        var lines: [String] = []
        lines.append("Batch on \(groupName)")
        lines.append("Prompt: \(prompt)")
        if results.isEmpty {
            lines.append("No servers in this group.")
        } else {
            let succeeded = results.filter(\.succeeded).count
            lines.append("Succeeded \(succeeded) of \(results.count).")
            for result in results {
                let status = result.succeeded ? "ok" : "failed"
                lines.append("- \(result.serverName): \(status). \(result.summary)")
            }
            let distinct = Set(results.map(\.summary))
            if results.count > 1 && distinct.count == 1 {
                lines.append("Comparison: every server returned the same summary.")
            } else if results.count > 1 {
                lines.append("Comparison: summaries differ across servers.")
            }
        }
        return ServerBatchReport(
            groupName: groupName,
            prompt: prompt,
            results: results,
            markdown: lines.joined(separator: "\n")
        )
    }

    /// 截断助手回复，避免对比摘要被单台长输出占满。
    static func clippedSummary(_ text: String, limit: Int = 500) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No assistant reply." }
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
