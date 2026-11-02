/// 文件说明：HostKeyPrompting，主机密钥确认的抽象，让握手可以等用户看完指纹。
import Foundation

/// HostKeyPrompting：
/// 首次连接或密钥变化时，由界面实现这个协议并挂起握手，直到用户接受或拒绝。
/// 接受之后才允许存储层做原子写入。
nonisolated protocol HostKeyPrompting: Sendable {
    func decide(_ prompt: HostKeyPrompt) async -> HostKeyPromptDecision
}
