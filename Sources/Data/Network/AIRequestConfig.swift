/// 文件说明：AIRequestConfig，AI 请求配置封装。
import Foundation

/// AIRequestConfig：
/// 封装单次 AI 请求所需的 endpoint、认证信息、模型名和格式策略。
struct AIRequestConfig {
    let endpointURL: String
    let apiKey: String
    let modelName: String
    let strategy: APIFormatStrategy
}
