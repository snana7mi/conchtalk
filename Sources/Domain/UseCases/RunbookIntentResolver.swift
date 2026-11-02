/// 文件说明：RunbookIntentResolver，把快捷指令参数解析成要启动的手册和服务器。
import Foundation

/// RunbookIntentResolver：
/// 纯函数，不连接 SSH。名称匹配不区分大小写；主机名只在没有名称命中时作为补充。
nonisolated enum RunbookIntentResolver {
    nonisolated enum Failure: Equatable, Sendable, Error {
        case missingRunbook
        case missingServer(String)
        case ambiguousServer(String)
    }

    nonisolated struct Selection: Equatable, Sendable {
        var runbook: Runbook
        var server: Server
    }

    static func resolve(
        runbookID: String,
        serverName: String,
        runbooks: [Runbook],
        servers: [Server]
    ) -> Result<Selection, Failure> {
        guard let runbook = runbooks.first(where: { $0.id.uuidString == runbookID || $0.name == runbookID }) else {
            return .failure(.missingRunbook)
        }
        let query = serverName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure(.missingServer(serverName)) }

        let exact = servers.filter { $0.name.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        if exact.count == 1 {
            return .success(Selection(runbook: runbook, server: exact[0]))
        }
        if exact.count > 1 {
            return .failure(.ambiguousServer(query))
        }

        let partial = servers.filter {
            $0.name.localizedStandardContains(query) || $0.host.localizedStandardContains(query)
        }
        if partial.count == 1 {
            return .success(Selection(runbook: runbook, server: partial[0]))
        }
        if partial.count > 1 {
            return .failure(.ambiguousServer(query))
        }
        return .failure(.missingServer(query))
    }
}
