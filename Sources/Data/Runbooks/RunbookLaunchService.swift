/// 文件说明：RunbookLaunchService，把快捷指令或列表里的运行请求交给界面去连接服务器。
import Foundation

/// RunbookLaunchService：
/// 解析手册和服务器后，发出一次待执行请求并等待界面报告是否已经开始。
/// 界面通过观察 `request` 执行连接，避免在 App 结构体上保存过期闭包。
@MainActor
@Observable
final class RunbookLaunchService {
    /// 界面需要接手的一次运行。
    struct Request: Equatable, Sendable {
        var id: UUID
        var server: Server
        var prompt: String
    }

    @ObservationIgnored private let catalog: RunbookCatalog
    @ObservationIgnored private let store: SwiftDataStore
    private(set) var request: Request?
    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?

    init(catalog: RunbookCatalog, store: SwiftDataStore) {
        self.catalog = catalog
        self.store = store
    }

    /// 解析参数。成功时挂起，直到界面消费请求并回报连接结果。
    func launch(runbookID: String, serverName: String) async -> String {
        let runbooks = (try? catalog.store.loadAll()) ?? []
        let servers = (try? await store.fetchServers()) ?? []
        switch RunbookIntentResolver.resolve(
            runbookID: runbookID,
            serverName: serverName,
            runbooks: runbooks,
            servers: servers
        ) {
        case .failure(.missingRunbook):
            return String(localized: "Could not find that runbook.", bundle: LanguageSettings.currentBundle)
        case .failure(.missingServer(let name)):
            return String(
                format: String(localized: "Could not find a server named %@.", bundle: LanguageSettings.currentBundle),
                locale: LanguageSettings.currentLocale,
                name
            )
        case .failure(.ambiguousServer(let name)):
            return String(
                format: String(localized: "Several servers match %@. Use the full name.", bundle: LanguageSettings.currentBundle),
                locale: LanguageSettings.currentLocale,
                name
            )
        case .success(let selection):
            catalog.reload()
            let prompt = RunbookSkillRenderer.replayPrompt(for: selection.runbook)
            let started = await submit(server: selection.server, prompt: prompt)
            if started {
                return String(
                    format: String(localized: "Started %@ on %@.", bundle: LanguageSettings.currentBundle),
                    locale: LanguageSettings.currentLocale,
                    selection.runbook.displayName,
                    selection.server.name
                )
            }
            return String(
                format: String(localized: "Could not connect to %@.", bundle: LanguageSettings.currentBundle),
                locale: LanguageSettings.currentLocale,
                selection.server.name
            )
        }
    }

    /// 界面完成连接后调用。只接受当前请求，避免旧任务覆盖新结果。
    func consume(_ request: Request, success: Bool) {
        guard self.request?.id == request.id else { return }
        self.request = nil
        continuation?.resume(returning: success)
        continuation = nil
    }

    private func submit(server: Server, prompt: String) async -> Bool {
        if continuation != nil {
            continuation?.resume(returning: false)
            continuation = nil
        }
        let requestID = UUID()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let request = Request(id: requestID, server: server, prompt: prompt)
            self.request = request
            // 界面若没有消费请求，避免快捷指令一直挂起。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(180))
                self.expire(requestID)
            }
        }
    }

    private func expire(_ requestID: UUID) {
        guard request?.id == requestID else { return }
        request = nil
        continuation?.resume(returning: false)
        continuation = nil
    }
}
