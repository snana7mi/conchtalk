/// 文件说明：MockSyncAPIClient，按预置序列返回 pull 响应并记录请求参数。
@testable import ConchTalk
import Foundation

/// MockSyncAPIClient：
/// SyncAPIClientProtocol 的测试替身。pullResponses 按调用次序逐个返回，
/// 耗尽后返回空页（entries: [], next_cursor: nil），模拟"没有更多数据"。
final class MockSyncAPIClient: SyncAPIClientProtocol, @unchecked Sendable {
    var pullResponses: [SyncAPIClient.PullResponse] = []
    private(set) var receivedPullSeqs: [Int64] = []
    private(set) var pushedRequests: [SyncAPIClient.PushRequest] = []
    private var pullIndex = 0

    func push(_ request: SyncAPIClient.PushRequest) async throws -> SyncAPIClient.PushResponse {
        pushedRequests.append(request)
        return SyncAPIClient.PushResponse(success: true, stored_entries: request.entries.count, pruned_count: 0)
    }

    func pull(sinceSeq: Int64, deviceId: String, limit: Int) async throws -> SyncAPIClient.PullResponse {
        receivedPullSeqs.append(sinceSeq)
        guard pullIndex < pullResponses.count else {
            return SyncAPIClient.PullResponse(entries: [], next_cursor: nil)
        }
        defer { pullIndex += 1 }
        return pullResponses[pullIndex]
    }

    func deleteAll() async throws -> SyncAPIClient.DeleteResponse {
        SyncAPIClient.DeleteResponse(success: true, deleted_entries: 0)
    }
}
