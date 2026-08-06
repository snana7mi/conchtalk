/// 文件说明：ConnectionProgressError，连接进度动画使用的错误类型。
import Foundation

/// 连接进度动画使用的错误类型。
enum ConnectionProgressError: LocalizedError {
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let reason): reason
        }
    }
}
