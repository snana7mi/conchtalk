# ConchTalk Development Guide

## AI 协作偏好

- 优先使用 superpowers skills（如 brainstorming、writing-plans、test-driven-development、systematic-debugging 等）来驱动开发流程

## 测试规范

- **所有测试 case（包括现有的和新增的）都应尽可能在测试服务器上进行测试**
- 测试服务器连接信息见本地 memory（`reference_test_server.md`），不要将凭据写入代码或提交到 git

## Project Overview

ConchTalk 是一个运行在 iOS 上的 AI 个人助手应用，通过 SSH 连接远端服务器作为计算资源，借助 AI（云端代理或用户自定义 API）和 Tool Calling，以自然语言驱动完成各类任务——数据处理、文件操作、网页爬取、系统运维、编码协作等。除常规 agentic loop 外，应用还支持通过 ACP 协议直连远端编码代理（如 OpenCode、Gemini CLI、Kimi CLI、OpenClaw、Qwen Code）。

## Tech Stack

- **语言**: Swift 6（strict concurrency: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`）
- **UI**: SwiftUI
- **持久化**: SwiftData
- **SSH**: Citadel 0.12.0（基于 SwiftNIO SSH）
- **订阅**: RevenueCat（应用内购买与订阅生命周期管理）
- **AI 接入**: ConchTalk 云端服务 + Custom API（OpenAI Compatible / Anthropic）+ ACP Direct Mode
- **构建**: Xcode project（`PBXFileSystemSynchronizedRootGroup`，Sources/ 下文件自动包含）
- **部署目标**: iOS 26+

## Architecture: MVVM + Clean Architecture

```
Sources/
├── App/                    # 入口 & 依赖装配
│   └── DependencyContainer # 全局依赖注册
├── Domain/                 # 纯业务逻辑（不依赖框架）
│   ├── Entities/           # 值类型实体（struct, Sendable）
│   ├── Protocols/          # 抽象契约
│   └── UseCases/           # 用例
├── Data/                   # 基础设施实现
│   ├── ACP/                # ACP 直连代理传输与会话
│   ├── BackgroundTask/     # 后台任务编排（Coordinator 模式）
│   ├── Chat/               # ChatMessageRepository 等聊天数据层
│   ├── Context/            # Token 预算与上下文压缩
│   ├── Memory/             # AI 记忆
│   ├── Network/            # API 调用
│   ├── Persistence/        # SwiftData Models + SwiftDataStore
│   ├── Security/           # Keychain
│   ├── Settings/           # UserDefaults
│   ├── Skills/             # Skill 加载与激活管理
│   ├── Speech/             # 语音识别与音频权限
│   ├── SSH/                # NIOSSHClient, SSHSessionManager
│   ├── Subscription/       # RevenueCat 订阅管理（购买、恢复、状态监听）
│   ├── Sync/               # 云同步（E2E 加密、变更收集、合并引擎、API 通信）
│   └── Tools/              # AI 工具实现（ToolProtocol）
├── Presentation/           # UI 层
│   ├── Chat/               # 聊天页
│   ├── Paywall/            # 订阅付费墙（功能对比 + 购买流程）
│   ├── ServerList/         # 服务器列表
│   ├── ServerSetup/        # 服务器配置
│   ├── Settings/           # 设置页
│   └── Shared/             # 公共组件
└── Resources/              # 资源文件
```

## Core Conventions

### 模块化与测试
- **所有功能尽可能模块化**，避免耦合，不要写太大或太复杂的模块。每个模块职责单一、边界清晰，便于独立理解和替换
- **每个模块都要有对应的测试**。编译和运行测试时不允许有任何警告（warnings）

### Swift 类型选择
- Domain entities → `struct`（值类型，`Sendable`）
- SwiftData models → `@Model class`，放 `Data/Persistence/Models/`，提供 `toDomain()` / `fromDomain()` 转换
- `SwiftDataStore` → `@ModelActor actor`（线程安全持久化）
- SSH 客户端 → `actor`（`NIOSSHClient`）
- ViewModels → `@Observable class`

### 跨平台兼容
- 使用 `#if os(iOS)` 守卫 iOS-only API（`navigationBarTitleDisplayMode`, `textInputAutocapitalization`, `keyboardType`）
- 使用 `Color.secondary.opacity(x)` 代替 `Color(.systemGrayN)`

### 多语言（i18n）

应用支持三种语言：English、中文、日本語，用户可在设置中切换。

- **UI 文本必须走 `String(localized:bundle:)`**，bundle 传 `LanguageSettings.currentBundle`
- 所有用户可见字符串在 `Localizable.xcstrings` 中维护
- **Tool 的 `description` 和参数 `description`** 用英文（给 AI 模型读的，不是给用户看的）
- **Tool 返回给用户的 `message` / `explanation`** 应使用 `"in the user's language"` 让 AI 按用户语言输出，而非硬编码某种语言
- 固定展示名（如语言名称 "English" / "中文" / "日本語"）不做本地化

### 注释规范
- 每个文件首行：`/// 文件说明：ClassName，一句话描述。`
- 类型声明前：`/// ClassName：\n/// 多行说明。`
- 关键实现细节用行内注释
- 代码注释使用中文（跟随项目主语言）

## Tool 开发规范

### 核心原则：职责单一 + 安全分级

每个 Tool 只做自己职责范围内的事。**如果需要执行不属于自己职责的 SSH 命令（如安装依赖），必须返回提示信息让 AI 通过 `execute_ssh_command` 走标准确认流程，绝不自行执行。**

### 新建 Tool 检查清单

1. **实现 `ToolProtocol`**，放在 `Sources/Data/Tools/`
2. **`validateSafety` 必须正确分级**：
   - `.safe` — 纯读取/探测操作（`ls`, `cat`, 系统信息）
   - `.needsConfirmation` — 任何写入/变更操作（写文件、杀进程、管理服务）
   - `.forbidden` — 高危操作（`rm -rf /`, `mkfs`）
3. **`sshClient.execute()` 调用准则**：
   - 读取/探测类调用 → 可以直接用 `sshClient.execute()`
   - 变更类调用 → 必须是 Tool 自身职责范围内的操作，且 `validateSafety` 已标记为 `.needsConfirmation`
   - 超出自身职责的变更操作 → 返回提示 JSON（含 `status` + `message` + 建议命令），让 AI 走 `execute_ssh_command`
4. **注册到 `DependencyContainer`** 的 `ToolRegistry`
5. **参数 schema** 遵循 OpenAI function calling 格式

### Tool 安全分级速查

| SafetyLevel | 含义 | 示例 |
|---|---|---|
| `.safe` | 无副作用，自动执行 | `read_file`, `list_directory`, `get_system_info` |
| `.needsConfirmation` | 有副作用，需用户确认 | `execute_ssh_command`, `write_file`, `start_long_running_command`, `start_interactive_session`, `send_input`（含危险关键词时） |
| `.forbidden` | 禁止执行 | `rm -rf /`, `mkfs` |

### PermissionLevel 权限叠加

`PermissionLevel` 会对 Tool 的 `SafetyLevel` 做二次映射：
- **strict**: `.safe` → `.needsConfirmation`（所有操作都要确认）
- **standard**: 原样保留
- **permissive**: `.needsConfirmation` → `.safe`（写操作也自动执行）

### SSH 命令执行规则

所有远端命令必须通过以下 Tool 执行：
- `execute_ssh_command` — 非交互式命令
- `start_interactive_session` + `send_input` — 交互式命令（需要 stdin 输入的程序）
- `start_long_running_command` — 长运行后台任务

禁止绕过 Tool 直接调用 `sshClient.execute()` 来运行用户请求的命令——这会跳过安全分级和用户确认流程。

交互式程序（vim、htop 等）如有专用 Tool（如 write_file 替代 vim），优先使用专用 Tool。exec channel 的超时机制（120 秒）作为兜底保障。

## Skill 开发规范

### 什么是 Skill

Skill 是 Markdown 格式的策略编排模板，用于引导 AI 分阶段执行复杂运维任务。放在 `Sources/Resources/Skills/` 目录下，app 启动时自动加载。

### 文件格式

```markdown
---
name: my-skill
displayName: 我的 Skill
description: 一句话英文描述，供 AI 判断是否匹配
triggers:
  - "触发词1"
  - "trigger word"
---

# Skill 标题

阶段化的指引内容...
```

### 编写要点

- **description 用英文**（给 AI 模型读的）
- **content 中的用户交互文本**用 "in the user's language" 让 AI 自适应
- 每个阶段末尾要求 AI "report results and wait for confirmation"
- 包含失败处理指引
- Skill 长度不做硬性限制，但应尽量精简，避免冗余内容

## 核心调用链

### 普通模式（AI Agent Loop）

```
用户发送消息:
ChatViewModel
  → ChatSessionCoordinator.sendNormalMessage()
    → TaskExecutionCoordinator.enqueueTask()
      → PerServerTaskQueue.enqueue()
      → dequeueAndExecuteNext()
        → TaskLifecycleManager.registerTask()
        → TaskExecutionContextFactory.makeTaskToolRegistry() / getSSHClient() / resolvePermissionLevel()
        → ExecuteNaturalLanguageCommandUseCase.execute()

AI 循环（每轮）:
ExecuteNaturalLanguageCommandUseCase
  → AIServiceProtocol.sendMessageStreaming()         [调 AI API]
  → 解析响应 → case .toolCall:
    → ToolSafetyGate.evaluate()                      [安全分级校验]
      → if needsConfirmation → coordinator 内部挂起等待审批
    → StreamingToolExecutor.execute()                [流式执行工具]
      → NIOSSHClient.executeStreaming()              [SSH 远端执行]
  → case .text → 循环结束，返回消息
  → ChatMessageRepository.appendMessages()           [持久化]
  → TaskExecutionCoordinator.drainQueueAfterTaskCompletion()
```

### 直连代理模式（Direct Agent）

```
连接:
DirectSessionCoordinator.connect(agent:cwd:sshClient:)
  → DirectAgentSession.connect(cwd:)
    → 按代理类型路由:
      ClaudeCodeConnection   → SSHProcessTransport（启动 CLI 进程）
      ACPAgentConnection     → SSHACPTransport → ACPClientConnection（ACP 握手）

发送消息:
ChatSessionCoordinator.sendMessage() [directAgent 模式]
  → DirectSessionCoordinator.sendPrompt()
    → DirectAgentSession.sendPrompt()
      → ClaudeCodeConnection / ACPAgentConnection 写入
      → 消息路由器异步消费输出 → updateHandler → eventContinuation.yield(.messageReady)
  → ChatViewModel 收到事件 → 更新 UI
```

### 后台任务管理

```
TaskExecutionCoordinator [编排，App 级单例]
  → PerServerTaskQueue       — 按服务器 FIFO 排队
  → TaskLifecycleManager     — 注册/取消/等待任务
  → TaskStreamingStateStore  — 流式状态快照 + 观察者分发
  （审批续体 + 双层超时防御、任务完成后处理均为 coordinator 内部实现）

前台恢复:
TaskExecutionCoordinator.onForegroundResume()
  → reconcileExpired()                               [清理过期审批与代理连接]
```

### SSH 连接与命令执行

```
SSHSessionManager.ensureConnected(to:)
  → NIOSSHClient.connect()
    → Citadel.Client(host:port:username:).connect()
    → startKeepAlive()
  → detectAndSaveSystemProfile()                    [uname 探测 + 持久化]

命令执行:
NIOSSHClient.executeStreaming(command:)
  → Citadel exec channel → 流式输出
```

### 消息持久化

```
ChatMessageRepository
  → appendMessage() / appendMessages() / appendSystemMessage()
    → SwiftDataStore.addMessage()                   [SwiftData 写入]
  → fetchMessages(forServer:)
    → SwiftDataStore.fetchMessages()                [SwiftData 读取]

上下文过滤:
ExecuteNaturalLanguageCommandUseCase.filterAfterLastContextBreak()
  → 只取最后一个 contextBreak 之后的消息作为对话历史
```

### 云同步

```
触发:
scenePhase == .background → SyncService.sync()

Push 流程:
SyncService.sync()
  → SyncChangeCollector.collectChanges(since:)
    → SwiftDataStore.fetchChanged*()              [查询 syncVersion > lastSynced && !isRemoteMerge]
    → 跨类型按全局 syncVersion 排序，取前 batchSize 条
    → 从 Keychain 补充密码/私钥（软删除 tombstone 跳过凭据）
  → SyncCryptoService.encrypt()                   [HKDF 派生 DEK → AES-256-GCM]
  → SyncAPIClient.push()                          [PUT /sync/push]
  → 更新 SyncState.lastSyncedVersion

Pull 流程:
SyncService.sync()
  → SyncAPIClient.pull()                          [GET /sync/pull，seq 游标]
  → SyncCryptoService.decrypt()
  → SyncMergeEngine.merge()
    → SwiftDataStore.mergeRemote*()               [LWW 合并，isRemoteMerge = true]
  → SwiftDataStore.rebuildServerGroupRelationships() [修复 Server ↔ Group 关系]
  → SwiftDataStore.purgeSoftDeletedEntities()     [清理 30 天前的软删除记录]

关闭同步:
CloudSyncSettingsView toggle off → 二次确认
  → SyncService.disableAndDeleteCloudData()
    → SyncAPIClient.deleteAll()                   [DELETE /sync/data]
    → SyncState.disabledByUserID = currentUserID  [per-user 记录，防止自动重新开启]

自动开启:
ConchTalkApp .task → 检测 isLoggedIn && tier == "paid" && disabledByUserID != currentUserID
  → SyncState.isEnabled = true
```

### 软删除规范

所有实体删除操作使用软删除（`isDeleted = true`），不直接调用 `modelContext.delete()`：
- 删除时设置 `syncVersion`/`modifiedAt`/`isRemoteMerge = false`，确保删除操作被推送到云端
- 所有 UI 层 fetch 方法过滤 `isDeleted == false`
- `upsertMemory`/`upsertSystemProfile` 写入时恢复软删除记录（`isDeleted = false`）
- 所有 insert 方法（`saveServer`/`addMessage`/`addMessages` 等）检查同 ID 软删除记录，恢复而非新建
- `deleteGroup` 先解除下属 server 的 group 引用并 bump sync 字段
- 物理清理由 `purgeSoftDeletedEntities()` 在同步成功后执行（30 天保留期）

## 后台保活机制

- **主层**：`LiveActivityManager` 通过 ActivityKit 启动 Live Activity，在锁屏/灵动岛显示任务状态，触发系统给予更长后台运行时间
- **兜底层**：原生 30 秒后台任务（`BGProcessingTask` / `beginBackgroundTask`），在 Live Activity 不可用时生效

## 详细架构与能力说明

产品能力、架构流程、功能亮点和对外描述统一维护在 `README.md`。如需更新产品文案、功能列表、运行链路或架构概览，只修改 README，不要在这里复制一份。

这里仅保留对开发协作有帮助、但不适合放在 README 里的约定：

- 新增或调整功能时，同时检查 README 是否需要同步
- 新增工具时，除了实现和注册，也要更新 README 中的工具与能力说明
- 当 AI / SSH / ACP 主流程变化时，README 的“架构流程”必须同步更新
- 当功能下线、重命名或行为变化时，先删 README 旧描述，再补新描述，避免历史堆积

## Git 工作流

- 主分支: `main`
- Commit message 使用中文，描述变更内容
- 不要提交 `.env`、密钥等敏感文件
- **`docs/` 目录绝不提交到 git**（plans、specs、mockups 等仅本地保留）
- **绝对不要自动 commit**，所有 commit 由用户手动执行

## 文档维护

当发生以下变更时，必须同步更新项目 README：
- 大的逻辑变动或 breaking change
- 新增用户可感知的 feature
- 架构层面的调整（如新增/移除模块、协议变更）
- AI 接入方式变化（云端代理 / 自定义 API / ACP 直连）
- Tool 集合或安全模型变化

README 是项目对外的第一印象，保持与代码同步。

## Common Pitfalls

- `PBXFileSystemSynchronizedRootGroup` 意味着 Sources/ 下新文件自动加入编译，无需手动拖入 Xcode
- Swift 6 strict concurrency 下，跨 actor 边界传递的类型必须是 `Sendable`
- Citadel SSH 命令执行返回的字符串可能包含 ANSI 转义序列，需用 `stripANSIEscapes()` 清理
- `ShellChannel` 对非零 exit code 可能抛异常，探测类命令用 `|| true` 兜底
