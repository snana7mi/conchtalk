/// 文件说明：IntegrationTestConfig，集成测试配置助手，从本地 JSON 文件或环境变量读取服务器和 AI 连接参数。
@testable import ConchTalk
@preconcurrency import Citadel
import Foundation
import Testing

// MARK: - Integration Test Tag

extension Tag {
    /// 标记需要真实服务器连接的集成测试，可通过 `swift test --filter` 过滤。
    @Tag static var integration: Self
}

// MARK: - IntegrationTestConfig

/// IntegrationTestConfig：
/// 优先从 `integration_test_config.json` 加载配置，fallback 到环境变量。
/// 提供工厂方法创建 Server、NIOSSHClient、AIProxyService 等实例。
struct IntegrationTestConfig: Sendable, Codable {

    // MARK: - SSH 配置

    let host: String
    let port: Int
    let user: String
    let password: String

    // MARK: - AI 配置

    let aiBaseURL: String
    let aiModel: String
    let aiAPIKey: String

    // MARK: - 加载

    /// 优先从 JSON 配置文件加载，找不到则 fallback 到环境变量。
    /// JSON 文件搜索路径：
    /// 1. 测试 Bundle 内的 `integration_test_config.json`
    /// 2. 源码目录 `ConchTalkTests/Helpers/integration_test_config.json`
    /// 3. 项目根目录 `integration_test_config.json`
    /// 全部找不到或解析失败时，尝试环境变量。都没有则返回 nil（测试自动跳过）。
    static func load() -> IntegrationTestConfig? {
        // 尝试从 JSON 文件加载
        if let config = loadFromFile() {
            return config
        }
        // Fallback 到环境变量
        return loadFromEnvironment()
    }

    /// 从 JSON 配置文件加载。利用 `#filePath` 在编译时获取源码路径，推算配置文件位置。
    private static func loadFromFile() -> IntegrationTestConfig? {
        // #filePath → .../ConchTalkTests/Helpers/IntegrationTestConfig.swift
        // 同目录下放 integration_test_config.json
        let thisFile = URL(fileURLWithPath: #filePath)
        let configURL = thisFile.deletingLastPathComponent()
            .appendingPathComponent("integration_test_config.json")

        // 也尝试项目根目录
        let projectRoot = thisFile.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootConfigURL = projectRoot.appendingPathComponent("integration_test_config.json")

        for url in [configURL, rootConfigURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let config = try JSONDecoder().decode(IntegrationTestConfig.self, from: data)
                print("[IntegrationTest] Loaded config from: \(url.path)")
                return config
            } catch {
                print("[IntegrationTest] Failed to decode \(url.path): \(error)")
            }
        }
        return nil
    }

    /// 从环境变量加载。
    private static func loadFromEnvironment() -> IntegrationTestConfig? {
        let env = ProcessInfo.processInfo.environment

        guard let host = env["CT_TEST_HOST"],
              let user = env["CT_TEST_USER"],
              let password = env["CT_TEST_PASSWORD"],
              let aiBaseURL = env["CT_TEST_AI_BASE_URL"],
              let aiModel = env["CT_TEST_AI_MODEL"],
              let aiAPIKey = env["CT_TEST_AI_API_KEY"]
        else {
            return nil
        }

        let port = env["CT_TEST_PORT"].flatMap(Int.init) ?? 22
        print("[IntegrationTest] Loaded config from environment variables")

        return IntegrationTestConfig(
            host: host,
            port: port,
            user: user,
            password: password,
            aiBaseURL: aiBaseURL,
            aiModel: aiModel,
            aiAPIKey: aiAPIKey
        )
    }


    // MARK: - 工厂方法

    /// 创建测试用 Server 领域实体。
    func makeServer() -> Server {
        Server(
            name: "Integration Test Server",
            host: host,
            port: port,
            username: user,
            authMethod: .password
        )
    }

    /// 创建并连接 NIOSSHClient，返回已建立连接的客户端实例。
    func connectSSH() async throws -> NIOSSHClient {
        let client = NIOSSHClient()
        let server = makeServer()
        try await client.connect(to: server, password: password, sshKeyData: nil, keyPassphrase: nil)
        return client
    }

    /// 创建 AIProxyService，将 AI 配置写入 UserDefaults 和 MockKeychainService。
    /// - Parameters:
    ///   - toolRegistry: 工具注册表，默认为空。Agentic loop 测试需传入真实工具。
    ///   - skillRegistry: Skill 注册表，默认为空。
    ///   - keychainService: 测试用 Keychain 服务（调用方可复用同一实例）。
    /// - Returns: 配置好的 AIProxyService 实例和使用的 MockKeychainService。
    func makeAIService(
        toolRegistry: ToolRegistryProtocol = ToolRegistry(tools: []),
        skillRegistry: SkillRegistry = SkillRegistry(preloaded: []),
        keychainService: MockKeychainService = MockKeychainService()
    ) -> (AIProxyService, MockKeychainService) {
        // 写入 UserDefaults
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: "aiUseLocalConfig")
        defaults.set(aiBaseURL, forKey: "aiEndpointURL")
        defaults.set(aiModel, forKey: "aiModelName")
        defaults.set("openai", forKey: "aiAPIFormat")

        // 写入 API Key 到 MockKeychainService
        try? keychainService.saveAPIKey(aiAPIKey)

        let service = AIProxyService(
            keychainService: keychainService,
            toolRegistry: toolRegistry,
            skillRegistry: skillRegistry
        )
        return (service, keychainService)
    }

    /// 清理 AI 相关的 UserDefaults 条目，避免测试间污染。
    static func cleanupAISettings() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "aiUseLocalConfig")
        defaults.removeObject(forKey: "aiEndpointURL")
        defaults.removeObject(forKey: "aiModelName")
        defaults.removeObject(forKey: "aiAPIFormat")
    }

    /// 创建并连接 SSH，同时返回 NIOSSHClient 和底层 Citadel SSHClient。
    /// - Throws: 连接失败或 citadelClient 为 nil 时抛出错误。
    func connectForACP() async throws -> (nioClient: NIOSSHClient, citadelClient: SSHClient) {
        let nioClient = try await connectSSH()
        guard let citadel = await nioClient.citadelClient else {
            throw SSHError.notConnected
        }
        return (nioClient, citadel)
    }
}

