/// 文件说明：SubagentRunner，复用 ExecuteNaturalLanguageCommandUseCase 跑子 agent，含并发限流与受限工具表。
import Foundation

/// SubagentRunner：
/// 为每个任务实例化一个受限的子 ExecuteNaturalLanguageCommandUseCase 并运行，
/// 并发上限内并行；确认请求经 SubagentApprovalGate 串行冒泡到父回调。
/// - 失败隔离：单个子 agent 抛错只影响其自身结果（succeeded=false），不会中断其余任务。
/// - 嵌套防护：受限工具表永远剔除 `dispatch_subagent`，子 agent 无法再派生子 agent。
nonisolated final class SubagentRunner: SubagentRunning, @unchecked Sendable {
    private let aiService: AIServiceProtocol
    private let sshClient: SSHClientProtocol
    private let baseToolRegistry: ToolRegistryProtocol
    private let registry: SubagentRegistry
    private let serverID: UUID?
    private let permissionLevel: PermissionLevel
    private let serverContext: String
    private let approvalGate: SubagentApprovalGate
    private let parentConfirm: @Sendable (ToolCall) async -> CommandApproval
    /// 同时运行的子 agent 上限（至少 1）。
    private let maxConcurrent: Int
    /// 子循环的最大迭代轮数（比主循环更小，更快收敛）。
    private let subMaxIterations: Int

    /// 初始化编排器并注入子循环所需依赖。
    /// - Parameters:
    ///   - aiService: 与主 UseCase 共用的 AI 服务。
    ///   - sshClient: 与主 UseCase 共用的 SSH 客户端。
    ///   - baseToolRegistry: 父级工具表，受限工具表在其基础上按白名单裁剪。
    ///   - registry: subagent 角色注册表，用于按名查找角色定义。
    ///   - serverID: 当前服务器 ID（透传给子 UseCase）。
    ///   - permissionLevel: 生效的操作权限等级（透传给子 UseCase）。
    ///   - serverContext: 服务器上下文，会与角色 systemPrompt 拼接注入子 UseCase。
    ///   - approvalGate: 确认串行闸，保证并行子 agent 的确认请求一次只冒泡一个。
    ///   - parentConfirm: 父级确认入口，复用主循环的审批通道。
    ///   - maxConcurrent: 并发上限（默认 2，内部夹紧到至少 1）。
    ///   - subMaxIterations: 子循环最大轮数（默认 25）。
    init(
        aiService: AIServiceProtocol,
        sshClient: SSHClientProtocol,
        baseToolRegistry: ToolRegistryProtocol,
        registry: SubagentRegistry,
        serverID: UUID?,
        permissionLevel: PermissionLevel,
        serverContext: String,
        approvalGate: SubagentApprovalGate,
        parentConfirm: @escaping @Sendable (ToolCall) async -> CommandApproval,
        maxConcurrent: Int = 2,
        subMaxIterations: Int = 25
    ) {
        self.aiService = aiService
        self.sshClient = sshClient
        self.baseToolRegistry = baseToolRegistry
        self.registry = registry
        self.serverID = serverID
        self.permissionLevel = permissionLevel
        self.serverContext = serverContext
        self.approvalGate = approvalGate
        self.parentConfirm = parentConfirm
        self.maxConcurrent = max(1, maxConcurrent)
        self.subMaxIterations = subMaxIterations
    }

    /// 并发执行任务并按输入顺序回填结果。
    /// - 限流策略：先投放 `min(maxConcurrent, tasks.count)` 个任务，每完成一个再补投一个，
    ///   使任意时刻在跑任务数不超过 `maxConcurrent`。
    /// - 顺序保证：用下标把结果写回固定位置，最后 compactMap，与输入顺序一一对应。
    func run(tasks: [SubagentTask]) async -> [SubagentResult] {
        guard !tasks.isEmpty else { return [] }
        var results = [SubagentResult?](repeating: nil, count: tasks.count)

        await withTaskGroup(of: (Int, SubagentResult).self) { group in
            var next = 0
            let limit = min(maxConcurrent, tasks.count)
            for _ in 0..<limit {
                let i = next
                next += 1
                let task = tasks[i]
                // 取消后不再启动新子 agent；返回值表示是否成功加入，正常路径恒为 true，逻辑等价。
                _ = group.addTaskUnlessCancelled { (i, await self.runOne(task)) }
            }
            while let (idx, res) = await group.next() {
                results[idx] = res
                if next < tasks.count {
                    let i = next
                    next += 1
                    let task = tasks[i]
                    _ = group.addTaskUnlessCancelled { (i, await self.runOne(task)) }
                }
            }
        }
        return results.compactMap { $0 }
    }

    /// 执行单个任务：查角色 → 建受限工具表 → 跑子 UseCase → 取最终结论。
    /// 找不到角色时返回失败结果（不抛错），保证失败隔离。
    private func runOne(_ task: SubagentTask) async -> SubagentResult {
        guard let def = registry.subagent(named: task.subagentType) else {
            return SubagentResult(
                subagentName: task.subagentType,
                task: task.prompt,
                outcome: "",
                succeeded: false,
                errorSummary: "Unknown subagent type: \(task.subagentType)"
            )
        }

        let restricted = makeRestrictedRegistry(for: def)
        let scopedAIService: AIServiceProtocol
        if let proxy = aiService as? AIProxyService {
            scopedAIService = proxy.withToolRegistry(restricted)
        } else {
            scopedAIService = aiService
        }
        let sub = ExecuteNaturalLanguageCommandUseCase(
            aiService: scopedAIService,
            sshClient: sshClient,
            toolRegistry: restricted,
            serverID: serverID,
            permissionLevel: permissionLevel,
            maxIterations: subMaxIterations
        )
        // 确认请求经串行闸冒泡到父回调，避免并行子 agent 的确认互相覆盖。
        sub.onToolCallNeedsConfirmation = { [approvalGate, parentConfirm] call in
            await approvalGate.requestConfirmation(call, via: parentConfirm)
        }

        // 角色 systemPrompt 注入：拼在 serverContext 之前，作为子 UseCase 的上下文。
        let context = def.systemPrompt + "\n\n" + serverContext
        do {
            let messages = try await sub.execute(
                userMessage: task.prompt,
                conversationHistory: [],
                serverContext: context
            )
            let outcome = messages.last(where: { $0.role == .assistant })?.content ?? ""
            return SubagentResult(
                subagentName: def.name,
                task: task.prompt,
                outcome: outcome,
                succeeded: true,
                errorSummary: nil
            )
        } catch {
            return SubagentResult(
                subagentName: def.name,
                task: task.prompt,
                outcome: "",
                succeeded: false,
                errorSummary: "\(error)"
            )
        }
    }

    /// 构建受限工具注册表：按白名单过滤；空白名单继承父工具；永远剔除 dispatch_subagent（嵌套防护）。
    /// - Note: 设为 internal（非 private）以便单测直接验证裁剪结果。
    func makeRestrictedRegistry(for def: SubagentDefinition) -> ToolRegistry {
        let parentTools = baseToolRegistry.tools.filter { $0.name != DispatchSubagentTool.toolName }
        if def.allowedTools.isEmpty {
            return ToolRegistry(tools: parentTools)
        }
        let allow = Set(def.allowedTools)
        return ToolRegistry(tools: parentTools.filter { allow.contains($0.name) })
    }
}
