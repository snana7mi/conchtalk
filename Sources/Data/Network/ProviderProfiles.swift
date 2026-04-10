/// 文件说明：ProviderProfiles，LLM 供应商 reasoning_content 规则适配。
import Foundation

// MARK: - Provider Profile

/// 协议适配层：将不同 LLM 供应商的 reasoning_content 规则显式化。
nonisolated protocol ProviderProfile {
    /// assistant + tool_calls 历史消息是否附带 reasoning_content。
    var includeReasoningOnToolCallMessages: Bool { get }
    /// 纯 assistant content 历史消息是否附带 reasoning_content。
    var includeReasoningOnPlainAssistantMessages: Bool { get }
}

/// DeepSeek：只在 assistant + tool_calls 历史上带 reasoning_content。
nonisolated struct DeepSeekProfile: ProviderProfile {
    let includeReasoningOnToolCallMessages = true
    let includeReasoningOnPlainAssistantMessages = false
}

/// OpenAI 及其他兼容服务：完全不传 reasoning_content。
nonisolated struct DefaultProfile: ProviderProfile {
    let includeReasoningOnToolCallMessages = false
    let includeReasoningOnPlainAssistantMessages = false
}

/// 根据 endpointURL / modelName 推断供应商 Profile。
nonisolated func resolveProfile(endpointURL: String, modelName: String) -> ProviderProfile {
    let url = endpointURL.lowercased()
    let model = modelName.lowercased()
    if url.contains("deepseek") || model.contains("deepseek") {
        return DeepSeekProfile()
    }
    return DefaultProfile()
}
