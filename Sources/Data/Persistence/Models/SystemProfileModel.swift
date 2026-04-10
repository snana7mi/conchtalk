/// 文件说明：SystemProfileModel，服务器系统环境探测结果的 SwiftData 持久化模型。
import Foundation
import SwiftData

/// SystemProfileModelError：
/// SystemProfile 持久化与领域转换中的错误类型。
enum SystemProfileModelError: LocalizedError {
    case toolsEncodingFailed
    case toolsDecodingFailed

    var errorDescription: String? {
        switch self {
        case .toolsEncodingFailed:
            "Failed to encode system profile tools."
        case .toolsDecodingFailed:
            "Failed to decode system profile tools."
        }
    }
}

/// SystemProfileModel：
/// 以 serverID 为唯一键存储探测结果，支持 upsert 语义。
@Model
final class SystemProfileModel {
    @Attribute(.unique) var serverID: UUID
    var osInfo: String
    var packageManager: String?
    var toolsJSON: String
    var detectedAt: Date

    // MARK: - 同步字段
    var syncVersion: Int64 = 0
    var modifiedAt: Date = Date()
    var isDeleted: Bool = false
    var isRemoteMerge: Bool = false

    init(serverID: UUID, osInfo: String, packageManager: String?, toolsJSON: String, detectedAt: Date) {
        self.serverID = serverID
        self.osInfo = osInfo
        self.packageManager = packageManager
        self.toolsJSON = toolsJSON
        self.detectedAt = detectedAt
    }

    /// 转换为领域层 SystemProfile。
    func toDomain() throws -> SystemProfile {
        guard let data = toolsJSON.data(using: .utf8),
              let tools = try? JSONDecoder().decode([SystemProfile.ToolInfo].self, from: data) else {
            throw SystemProfileModelError.toolsDecodingFailed
        }
        return SystemProfile(
            serverID: serverID,
            detectedAt: detectedAt,
            osInfo: osInfo,
            packageManager: packageManager,
            installedTools: tools
        )
    }

    /// 从领域层 SystemProfile 构建持久化模型。
    static func fromDomain(_ profile: SystemProfile) throws -> SystemProfileModel {
        guard let data = try? JSONEncoder().encode(profile.installedTools),
              let json = String(data: data, encoding: .utf8) else {
            throw SystemProfileModelError.toolsEncodingFailed
        }
        return SystemProfileModel(
            serverID: profile.serverID,
            osInfo: profile.osInfo,
            packageManager: profile.packageManager,
            toolsJSON: json,
            detectedAt: profile.detectedAt
        )
    }
}
