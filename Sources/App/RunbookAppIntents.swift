/// 文件说明：RunbookAppIntents，把已保存的操作手册暴露给 Siri 与快捷指令。
import AppIntents
import Foundation

/// RunbookEntity：快捷指令里可选的一本操作手册。
struct RunbookEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Runbook")
    static var defaultQuery = RunbookEntityQuery()

    var id: String
    var displayName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: LocalizedStringResource(stringLiteral: displayName))
    }

    init(runbook: Runbook) {
        self.id = runbook.id.uuidString
        self.displayName = runbook.displayName
    }
}

/// RunbookEntityQuery：从与 App 相同的本地目录读取手册。
struct RunbookEntityQuery: EntityQuery {
    func entities(for identifiers: [RunbookEntity.ID]) async throws -> [RunbookEntity] {
        let all = try load()
        let wanted = Set(identifiers)
        return all.filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [RunbookEntity] {
        try load()
    }

    private func load() throws -> [RunbookEntity] {
        try FileRunbookStore(directory: RunbookStorage.directory)
            .loadAll()
            .map(RunbookEntity.init)
    }
}

/// RunRunbookIntent：在指定服务器上再次运行一本操作手册。
struct RunRunbookIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Runbook"
    static let description = IntentDescription("Run a saved runbook on one of your servers.")
    static let openAppWhenRun = true

    @Parameter(title: "Runbook")
    var runbook: RunbookEntity

    @Parameter(title: "Server name")
    var serverName: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = await RunbookIntentBridge.shared.launch(
            runbookID: runbook.id,
            serverName: serverName
        )
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}

/// ConchTalkRunbookShortcuts：Siri 短语。每条短语都包含应用名。
struct ConchTalkRunbookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunRunbookIntent(),
            phrases: [
                "Run a runbook with \(.applicationName)",
                "用\(.applicationName)运行操作手册",
            ],
            shortTitle: "Run Runbook",
            systemImageName: "text.book.closed"
        )
    }
}

/// RunbookIntentBridge：
/// App Intent 与界面之间的交接。冷启动时界面尚未就绪，先记住请求，等注册后再执行。
@MainActor
final class RunbookIntentBridge {
    static let shared = RunbookIntentBridge()

    private var handler: ((String, String) async -> String)?
    private var pending: (runbookID: String, serverName: String)?

    private init() {}

    func register(handler: @escaping (String, String) async -> String) {
        self.handler = handler
        guard let pending else { return }
        self.pending = nil
        Task { _ = await handler(pending.runbookID, pending.serverName) }
    }

    func launch(runbookID: String, serverName: String) async -> String {
        if let handler {
            return await handler(runbookID, serverName)
        }
        pending = (runbookID, serverName)
        return String(localized: "Opening ConchTalk to run the runbook.", bundle: LanguageSettings.currentBundle)
    }
}
