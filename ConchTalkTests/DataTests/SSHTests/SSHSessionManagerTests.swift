/// 文件说明：SSHSessionManagerTests，覆盖连接管理器在无网络场景下的关键回归路径。
import Testing
@testable import ConchTalk
import Foundation

@Suite("SSHSessionManager")
@MainActor
struct SSHSessionManagerTests {
    @Test("getDetectedOS 在未探测时返回 Linux")
    func getDetectedOSDefaultLinux() {
        let manager = SSHSessionManager()
        let os = manager.getDetectedOS(for: UUID())
        #expect(os == "Linux")
    }

    @Test("getCapabilities 在未探测时返回 unknown")
    func getCapabilitiesDefaultUnknown() {
        let manager = SSHSessionManager()
        let caps = manager.getCapabilities(for: UUID())
        #expect(caps.availableAgents.isEmpty)
    }

    @Test("listDirectory 在无 client 时返回空数组")
    func listDirectoryWithoutClientReturnsEmpty() async throws {
        let manager = SSHSessionManager()
        let result = try await manager.listDirectory(path: "/tmp", serverID: UUID())
        #expect(result.isEmpty)
    }

    @Test("resolveHomeDirectory 在无 client 时返回根目录")
    func resolveHomeDirectoryWithoutClientReturnsRoot() async throws {
        let manager = SSHSessionManager()
        let home = try await manager.resolveHomeDirectory(serverID: UUID())
        #expect(home == "/")
    }

    @Test("findDisconnectedServers 在空管理器时返回空列表")
    func findDisconnectedServersEmpty() async {
        let manager = SSHSessionManager()
        let disconnected = await manager.findDisconnectedServers()
        #expect(disconnected.isEmpty)
    }

    @Test("findDisconnectedServers 返回注入的断连 client")
    func findDisconnectedServersWithInjectedDisconnectedClients() async {
        let manager = SSHSessionManager()
        let server1 = UUID()
        let server2 = UUID()
        manager.registerClientForTesting(serverID: server1, client: NIOSSHClient())
        manager.registerClientForTesting(serverID: server2, client: NIOSSHClient())

        let disconnected = await manager.findDisconnectedServers()
        #expect(Set(disconnected) == Set([server1, server2]))
    }

    @Test("checkAndReconnect 在活跃 client 已连接时恢复活跃连接标记")
    func checkAndReconnectRestoresActiveConnectionMarkerWhenClientAlive() async {
        let manager = SSHSessionManager()
        let serverID = UUID()
        let server = TestFixtures.makeServer(id: serverID)
        let client = NIOSSHClient()
        await client.setConnectionStateForTesting(isConnected: true)
        manager.registerClientForTesting(serverID: serverID, client: client)

        await manager.checkAndReconnect(server: server)

        #expect(manager.activeConnectionIDs.contains(serverID))
    }

    @Test("checkAndReconnect 在无重连参数且断连时保持断开且不崩溃")
    func checkAndReconnectWithoutReconnectParamsLeavesDisconnectedState() async {
        let manager = SSHSessionManager()
        let serverID = UUID()
        let server = TestFixtures.makeServer(id: serverID)
        let client = NIOSSHClient()
        await client.setConnectionStateForTesting(isConnected: false)
        manager.registerClientForTesting(serverID: serverID, client: client)

        await manager.checkAndReconnect(server: server)

        #expect(manager.activeConnectionIDs.contains(serverID) == false)
        #expect(manager.getClient(for: serverID) != nil)
    }

    @Test("checkAndReconnect 在无现有 client 时直接返回")
    func checkAndReconnectWithoutClientNoop() async {
        let manager = SSHSessionManager()
        let server = TestFixtures.makeServer()

        await manager.checkAndReconnect(server: server)

        #expect(manager.activeConnectionIDs.isEmpty)
        #expect(manager.getClient(for: server.id) == nil)
    }

    @Test("refreshCapabilities 在探测失败时落回保守能力")
    func refreshCapabilitiesFallsBackToConservativeDefaults() async {
        let manager = SSHSessionManager()
        let serverID = UUID()
        manager.registerClientForTesting(serverID: serverID, client: NIOSSHClient())

        await manager.refreshCapabilities(for: serverID)
        let caps = manager.getCapabilities(for: serverID)

        #expect(caps.availableAgents.isEmpty)
    }

    @Test("disconnectAll 会清理所有注入的 clients")
    func disconnectAllClearsInjectedClients() async {
        let manager = SSHSessionManager()
        let server1 = UUID()
        let server2 = UUID()
        manager.registerClientForTesting(serverID: server1, client: NIOSSHClient())
        manager.registerClientForTesting(serverID: server2, client: NIOSSHClient())

        await manager.disconnectAll()

        #expect(manager.getClient(for: server1) == nil)
        #expect(manager.getClient(for: server2) == nil)
    }

    @Test("reconnectProgress 初始为空")
    func reconnectProgressInitiallyEmpty() {
        let manager = SSHSessionManager()
        #expect(manager.reconnectProgress.isEmpty)
    }

    @Test("clearReconnectState 清除指定服务器的重连状态")
    func clearReconnectStateClearsServer() {
        let manager = SSHSessionManager()
        let serverID = UUID()
        // 手动设置状态用于测试
        manager.setReconnectProgressForTesting(serverID: serverID, attempt: 2, maxAttempts: 4)
        #expect(manager.reconnectProgress[serverID] != nil)

        manager.clearReconnectState(for: serverID)
        #expect(manager.reconnectProgress[serverID] == nil)
    }

    // MARK: - 连接限制测试

    @Test("ensureConnected 在 free tier 已连接其他服务器时抛出 connectionLimitReached")
    func ensureConnectedThrowsConnectionLimitForFreeTier() async throws {
        let manager = SSHSessionManager()
        let existingServerID = UUID()

        let client = NIOSSHClient()
        await client.setConnectionStateForTesting(isConnected: true)
        manager.registerClientForTesting(serverID: existingServerID, client: client)
        manager.activeConnectionIDs.insert(existingServerID)

        let newServer = TestFixtures.makeServer(id: UUID())
        let mockKeychain = MockKeychainService()

        await #expect(throws: SSHError.connectionLimitReached) {
            try await manager.ensureConnected(
                to: newServer, password: "test",
                keychainService: mockKeychain, userTier: "free"
            )
        }
    }

    @Test("ensureConnected 在 free tier 重连同一服务器时不抛 connectionLimitReached")
    func ensureConnectedAllowsReconnectSameServerForFreeTier() async throws {
        let manager = SSHSessionManager()
        let serverID = UUID()

        let client = NIOSSHClient()
        await client.setConnectionStateForTesting(isConnected: false)
        manager.registerClientForTesting(serverID: serverID, client: client)
        manager.activeConnectionIDs.insert(serverID)

        let server = TestFixtures.makeServer(id: serverID)
        let mockKeychain = MockKeychainService()

        do {
            try await manager.ensureConnected(
                to: server, password: "test",
                keychainService: mockKeychain, userTier: "free"
            )
        } catch let error as SSHError where error == .connectionLimitReached {
            Issue.record("Should not throw connectionLimitReached for same server reconnect")
        } catch {
            // 其他错误（如连接失败）是预期的
        }
    }

    @Test("ensureConnected 在 paid tier 时允许多服务器连接")
    func ensureConnectedAllowsMultipleConnectionsForPaidTier() async throws {
        let manager = SSHSessionManager()
        let existingServerID = UUID()

        let client = NIOSSHClient()
        await client.setConnectionStateForTesting(isConnected: true)
        manager.registerClientForTesting(serverID: existingServerID, client: client)
        manager.activeConnectionIDs.insert(existingServerID)

        let newServer = TestFixtures.makeServer(id: UUID())
        let mockKeychain = MockKeychainService()

        do {
            try await manager.ensureConnected(
                to: newServer, password: "test",
                keychainService: mockKeychain, userTier: "paid"
            )
        } catch let error as SSHError where error == .connectionLimitReached {
            Issue.record("Should not throw connectionLimitReached for paid tier")
        } catch {
            // 其他错误是预期的
        }
    }
}
