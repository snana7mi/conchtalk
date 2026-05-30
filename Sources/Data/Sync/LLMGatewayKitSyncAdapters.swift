import Foundation
import LLMGatewayKit

@MainActor
final class ConchtalkChangeCollector: SyncChangeCollecting, @unchecked Sendable {
    private let collector: SyncChangeCollector
    private var stagedEntries: [SyncChangeEntry] = []
    private var stagedMaxVersion: Int64 = 0

    init(collector: SyncChangeCollector) {
        self.collector = collector
    }

    func collectPending() async throws -> [SyncEnvelope] {
        let result = try await collector.collectChanges(since: SyncState.lastSyncedVersion)
        stagedEntries = result.entries
        stagedMaxVersion = result.maxSyncVersion
        return result.entries.map {
            SyncEnvelope(
                entityType: $0.entityType.rawValue,
                entityID: $0.entityId,
                modifiedAt: ISO8601DateFormatter().date(from: $0.modifiedAt) ?? Date(),
                data: $0.jsonData
            )
        }
    }

    func markSynced(_ envelopes: [SyncEnvelope]) async throws {
        guard !envelopes.isEmpty else { return }
        SyncState.lastSyncedVersion = stagedMaxVersion
        stagedEntries = []
        stagedMaxVersion = 0
    }
}

@MainActor
final class ConchtalkMerger: SyncMerging, @unchecked Sendable {
    private let mergeEngine: SyncMergeEngine

    init(mergeEngine: SyncMergeEngine) {
        self.mergeEngine = mergeEngine
    }

    func apply(_ envelope: SyncEnvelope) async throws {
        guard let entityType = SyncEntityType(rawValue: envelope.entityType) else { return }
        _ = try await mergeEngine.merge(entityType: entityType, jsonData: envelope.data)
        NotificationCenter.default.post(name: .syncDidPullNewData, object: nil)
    }
}
