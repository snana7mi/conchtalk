/// 文件说明：TokenEstimator，CJK 感知的 token 数估算。
import Foundation

/// TokenEstimator：
/// 基于 ASCII run flush 模式的 CJK 感知 token 估算实现。
/// - ASCII/Latin 字符：每 4 字符约 1 token。
/// - CJK 字符（常用汉字、扩展 A、日文标点）：每字符约 2 token。
nonisolated struct TokenEstimator: Sendable {
    /// 判断 unicode scalar 是否属于 CJK 范围。
    private func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x4E00 && scalar.value <= 0x9FFF ||
        scalar.value >= 0x3400 && scalar.value <= 0x4DBF ||
        scalar.value >= 0x3000 && scalar.value <= 0x303F
    }

    func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var tokens = 0
        var asciiRun = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                // 先 flush 累积的 ASCII run
                if asciiRun > 0 { tokens += max(asciiRun / 4, 1); asciiRun = 0 }
                tokens += 2
            } else {
                asciiRun += 1
            }
        }
        // flush 尾部 ASCII run
        if asciiRun > 0 { tokens += max(asciiRun / 4, 1) }
        return tokens
    }

    /// 估算单条消息发送给 AI 时实际占用的 token。
    /// 不仅算 content，还要算 toolOutput（命令原始 stdout，agentic loop 里通常是最大负载）
    /// 与 reasoningContent（推理链）——这两块都会进入上下文，旧实现只算 content 会严重低估。
    func estimateTokens(for message: Message) -> Int {
        var total = estimateTokens(message.content)
        if let output = message.toolOutput, !output.isEmpty {
            total += estimateTokens(output)
        }
        if let reasoning = message.reasoningContent, !reasoning.isEmpty {
            total += estimateTokens(reasoning)
        }
        return total
    }
}
