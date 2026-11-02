/// 文件说明：HealthCheckProber，连上服务器并执行固定的只读健康检查命令。
import Foundation

/// HealthCheckProber：
/// 只运行 `HealthProbeCommand` 生成的脚本。连接失败时把错误交回调度器，不重试其他服务器。
enum HealthCheckProber {
    @MainActor
    static func probe(
        server: Server,
        thresholds: HealthThresholds,
        sshManager: SSHSessionManager,
        keychain: any KeychainServiceProtocol
    ) async -> Result<HealthProbeReading, Error> {
        guard let script = HealthProbeCommand.script(services: thresholds.services) else {
            return .failure(HealthProbeError.unsafeServiceName)
        }
        do {
            var password: String?
            if case .password = server.authMethod {
                password = try keychain.getPassword(forServer: server.id)
            }
            try await sshManager.ensureConnected(to: server, password: password, keychainService: keychain)
            guard let client = sshManager.getClient(for: server.id) else {
                throw SSHError.notConnected
            }
            let output = try await client.execute(command: script, timeout: 20)
            return .success(HealthProbeParser.parse(output, expectedServices: thresholds.services))
        } catch {
            return .failure(error)
        }
    }
}

/// HealthProbeError：服务名无法安全放进 shell 时拒绝执行。
enum HealthProbeError: LocalizedError {
    case unsafeServiceName

    var errorDescription: String? {
        String(localized: "A service name is not safe to check.", bundle: LanguageSettings.currentBundle)
    }
}
