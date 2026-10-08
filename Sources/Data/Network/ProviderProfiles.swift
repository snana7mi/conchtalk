/// 文件说明：ProviderProfiles，LLM 供应商 reasoning_content 规则适配。
import Foundation

// MARK: - Provider Profile

/// 协议适配层：将不同 LLM 供应商的 reasoning_content 规则显式化。
nonisolated protocol ProviderProfile {
    /// assistant + tool_calls 历史消息是否附带 reasoning_content。
    var includeReasoningOnToolCallMessages: Bool { get }
    /// 纯 assistant content 历史消息是否附带 reasoning_content。
    var includeReasoningOnPlainAssistantMessages: Bool { get }
    /// assistant + tool_calls 历史消息是否附带原样保存的 Anthropic thinking 块。
    var includeAnthropicThinkingBlocks: Bool { get }
}

extension ProviderProfile {
    /// 默认回放 Anthropic thinking 块（仅 Anthropic 格式会使用，OpenAI 格式发送前剔除）。
    nonisolated var includeAnthropicThinkingBlocks: Bool { true }
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

/// 自愈「移除思考」重试：不带 reasoning_content，也不回放 thinking 块
///（例如 thinking 块签名失效导致 400 "Invalid `signature` in `thinking` block"）。
nonisolated struct NoReasoningProfile: ProviderProfile {
    let includeReasoningOnToolCallMessages = false
    let includeReasoningOnPlainAssistantMessages = false
    let includeAnthropicThinkingBlocks = false
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
