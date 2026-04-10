/// 文件说明：DLCInstaller，通过 SSH 在远程服务器上自动安装 conchtalk-dlc daemon。
import Foundation

struct DLCInstallResult: Sendable {
    let success: Bool
    let errorMessage: String?
}

actor DLCInstaller {
    private let relayTokenService: RelayTokenService
    private let sshManager: SSHSessionManager

    init(relayTokenService: RelayTokenService, sshManager: SSHSessionManager) {
        self.relayTokenService = relayTokenService
        self.sshManager = sshManager
    }

    func install(serverID: UUID, serverName: String) async -> DLCInstallResult {
        let tokenResponse: RelayTokenResponse
        do {
            tokenResponse = try await relayTokenService.createToken(serverID: serverID, name: serverName)
        } catch {
            return DLCInstallResult(success: false, errorMessage: "Failed to generate relay token: \(error.localizedDescription)")
        }

        guard let client = await MainActor.run(body: { sshManager.getClient(for: serverID) }) else {
            return DLCInstallResult(success: false, errorMessage: "SSH client not available")
        }

        let whoami: String
        do {
            whoami = try await client.execute(command: "whoami", timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return DLCInstallResult(success: false, errorMessage: "Failed to check user: \(error.localizedDescription)")
        }

        let installCmd = Self.buildInstallCommand(token: tokenResponse.token)
        let fullCmd = whoami == "root" ? installCmd : "sudo -n \(installCmd)"

        let output: String
        do {
            output = try await client.execute(command: fullCmd, timeout: 120)
        } catch {
            return DLCInstallResult(success: false, errorMessage: "Install failed: \(error.localizedDescription)")
        }

        return Self.parseInstallResult(output: output, exitCode: 0)
    }

    static func buildInstallCommand(token: String) -> String {
        "bash <(curl -sL https://raw.githubusercontent.com/snana7mi/conchtalk-dlc/main/install.sh) -t \(token)"
    }

    static func parseInstallResult(output: String, exitCode: Int) -> DLCInstallResult {
        if exitCode != 0 {
            let errorLine = output.components(separatedBy: "\n").first(where: { $0.contains("[ERROR]") })
            return DLCInstallResult(success: false, errorMessage: errorLine ?? "Exit code \(exitCode)")
        }
        if output.contains("installation complete") {
            return DLCInstallResult(success: true, errorMessage: nil)
        }
        return DLCInstallResult(success: false, errorMessage: "Installation may have failed: completion marker not found")
    }
}
