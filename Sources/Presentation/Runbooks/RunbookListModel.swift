/// 文件说明：RunbookListModel，操作手册列表的加载、保存与软删除。
import Foundation

/// RunbookListModel：
/// 界面状态。保存与删除都写到目录，并立刻刷新模型可见的 Skill。
@MainActor
@Observable
final class RunbookListModel {
    private let catalog: RunbookCatalog
    private(set) var runbooks: [Runbook] = []
    var errorMessage: String?

    init(catalog: RunbookCatalog) {
        self.catalog = catalog
    }

    func reload() {
        do {
            try catalog.store.purgeDeleted(olderThan: PersistenceMaintenance.softDeleteRetentionInterval, now: Date())
            runbooks = try catalog.store.loadAll()
            catalog.reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 从当前对话保存。失败时写入 `errorMessage` 并返回 false。
    @discardableResult
    func save(displayName: String, messages: [Message], sourceServerID: UUID?) -> Bool {
        let reserved = Set(catalog.skills.bundleSkillNames() + runbooks.map(\.name))
        switch RunbookSkillRenderer.make(
            displayName: displayName,
            messages: messages,
            reservedNames: reserved,
            sourceServerID: sourceServerID
        ) {
        case .failure(.emptyName):
            errorMessage = String(localized: "Enter a name", bundle: LanguageSettings.currentBundle)
            return false
        case .failure(.extraction(.noUserRequest)):
            errorMessage = String(localized: "A runbook needs at least one user request.", bundle: LanguageSettings.currentBundle)
            return false
        case .failure(.extraction(.notSuccessful)):
            errorMessage = String(localized: "This conversation cannot be saved yet. Wait until the assistant finishes successfully.", bundle: LanguageSettings.currentBundle)
            return false
        case .success(let runbook):
            do {
                try catalog.save(runbook)
                runbooks = try catalog.store.loadAll()
                errorMessage = nil
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
    }

    func delete(_ runbook: Runbook) {
        do {
            try catalog.softDelete(id: runbook.id)
            runbooks = try catalog.store.loadAll()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
