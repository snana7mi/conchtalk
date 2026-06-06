/// 文件说明：ToolProtocol，定义 AI 工具调用的统一契约与安全分级。
import Foundation

/// SafetyLevel：定义工具调用在执行前的安全决策级别。
nonisolated enum SafetyLevel: Equatable, Sendable {
    case safe               // 可直接执行，不需要用户确认
    case needsConfirmation  // 需要弹窗确认后再执行
    case forbidden          // 明确禁止执行
}

/// PermissionLevel：全局默认的操作权限等级。
nonisolated enum PermissionLevel: String, Codable, CaseIterable, Sendable {
    case strict      // 所有命令都需要手动确认
    case standard    // 默认：读放行，写确认，危险禁止
    case permissive  // 宽松：读写放行，危险需确认

    /// 将工具原始安全级别映射为当前权限等级下的有效安全级别。
    func effectiveSafetyLevel(_ raw: SafetyLevel) -> SafetyLevel {
        switch self {
        case .strict:
            return raw == .safe ? .needsConfirmation : raw
        case .standard:
            return raw
        case .permissive:
            switch raw {
            case .safe: return .safe
            case .needsConfirmation: return .safe
            case .forbidden: return .needsConfirmation
            }
        }
    }
}

/// ServerPermissionLevel：服务器级别的权限覆盖设置，默认跟随全局。
nonisolated enum ServerPermissionLevel: String, Codable, CaseIterable, Sendable {
    case followGlobal  // 跟随全局设置
    case strict
    case standard
    case permissive

    /// 解析为实际生效的权限等级。
    func resolved(globalLevel: PermissionLevel) -> PermissionLevel {
        switch self {
        case .followGlobal: globalLevel
        case .strict: .strict
        case .standard: .standard
        case .permissive: .permissive
        }
    }
}

// MARK: - UI Display Helpers

extension PermissionLevel {
    /// 本地化展示名称（仅供 UI 使用）。
    var displayName: String {
        switch self {
        case .strict:
            String(localized: "Strict", bundle: LanguageSettings.currentBundle)
        case .standard:
            String(localized: "Standard", bundle: LanguageSettings.currentBundle)
        case .permissive:
            String(localized: "Permissive", bundle: LanguageSettings.currentBundle)
        }
    }

    /// 本地化说明文案（仅供 UI 使用）。
    var descriptionText: String {
        switch self {
        case .strict:
            String(localized: "All commands require manual confirmation", bundle: LanguageSettings.currentBundle)
        case .standard:
            String(localized: "Reads auto-execute, writes need confirmation, dangerous commands blocked", bundle: LanguageSettings.currentBundle)
        case .permissive:
            String(localized: "Reads and writes auto-execute, dangerous commands need confirmation", bundle: LanguageSettings.currentBundle)
        }
    }

    /// UI 图标名称。
    var iconName: String {
        switch self {
        case .strict: "lock.shield.fill"
        case .standard: "shield.checkered"
        case .permissive: "bolt.shield.fill"
        }
    }
}

extension ServerPermissionLevel {
    /// 服务器级权限展示名称（仅供 UI 使用）。
    var displayName: String {
        switch self {
        case .followGlobal:
            String(localized: "Follow Global", bundle: LanguageSettings.currentBundle)
        case .strict:
            PermissionLevel.strict.displayName
        case .standard:
            PermissionLevel.standard.displayName
        case .permissive:
            PermissionLevel.permissive.displayName
        }
    }
}

/// ToolProtocol：
/// 所有 AI 可调用工具的统一接口，负责声明工具元信息、参数结构、安全策略与执行逻辑。
nonisolated protocol ToolProtocol: Sendable {
    /// 工具唯一名称（如 `execute_ssh_command`），用于模型函数调用匹配。
    var name: String { get }
    /// 工具用途说明，会注入系统提示词帮助模型正确选工具。
    var description: String { get }
    /// 函数调用参数的 JSON Schema（OpenAI tools 格式）。
    var parametersSchema: [String: Any] { get }
    /// 根据本次参数评估安全级别。
    /// - Parameter arguments: 本次工具调用参数。
    /// - Returns: 对应的安全级别（直接执行/确认/禁止）。
    func validateSafety(arguments: [String: Any]) -> SafetyLevel
    /// 执行工具逻辑并返回标准化结果。
    /// - Parameters:
    ///   - arguments: 本次工具调用参数。
    ///   - sshClient: 远端命令执行客户端。
    /// - Returns: 工具执行结果（文本输出）。
    /// - Throws: 参数缺失、参数非法或远端执行失败时抛出。
    func execute(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> ToolExecutionResult

    /// 是否支持流式执行（逐块返回输出）。
    var supportsStreaming: Bool { get }

    /// 以流式方式执行工具，逐块返回输出文本。
    /// - Parameters:
    ///   - arguments: 本次工具调用参数。
    ///   - sshClient: 远端命令执行客户端。
    /// - Returns: 异步抛出流；不支持流式时返回 `nil`。
    func executeStreaming(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> AsyncThrowingStream<String, Error>?
}

// MARK: - Default Streaming Implementations

nonisolated extension ToolProtocol {
    var supportsStreaming: Bool { false }

    func executeStreaming(arguments: [String: Any], sshClient: SSHClientProtocol) async throws -> AsyncThrowingStream<String, Error>? {
        nil
    }
}
