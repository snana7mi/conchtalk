# ConchTalk (海螺对话)

用聊天代替终端 —— 一个 AI 驱动的 iOS SSH 客户端。

用自然语言描述你想做的事，AI 自动选择合适的工具、执行并用人话回报结果。

## 架构

```
┌─────────────┐     OpenAI API      ┌─────────┐
│  iOS 客户端  │ ◄──────────────►   │  LLM    │
│  (SwiftUI)  │   直连              │ (GPT-4o │
│             │                     │  etc.)  │
└──────┬──────┘                     └─────────┘
       │
       │ SSH (Citadel)
       ▼
┌─────────────┐
│  远程服务器   │
└─────────────┘
```

客户端直连 AI API，无需后端代理。核心是一个 **AI Agent Loop**，AI 可以自主选择工具并连续执行多步操作，直到任务完成。支持 **SSE 流式输出**，推理模型的思维链实时展示。

## 多工具体系

采用可插拔的 `ToolProtocol` 架构，每个工具自描述 schema、自校验安全级别、自执行。AI 通过 OpenAI Function Calling 自主选择最合适的工具。

| 工具 | 用途 | 安全级别 |
|------|------|----------|
| `execute_ssh_command` | 通用 SSH 命令执行 | 按命令内容动态判断 |
| `read_file` | 读取文件内容（支持行范围） | safe |
| `write_file` | 写入/追加文件 | needsConfirmation |
| `list_directory` | 列出目录内容 | safe |
| `get_system_info` | CPU/内存/磁盘/OS 信息 | safe |
| `get_process_list` | 进程列表（可过滤排序） | safe |
| `get_network_status` | 网络接口/连接/端口 | safe |
| `manage_service` | systemd 服务管理 | status/logs=safe, start/stop/restart/enable/disable=needsConfirmation |
| `sftp_read_file` | SFTP 兼容文件读取（支持 base64 编码读取二进制文件） | safe |
| `sftp_write_file` | SFTP 兼容文件写入（支持 base64 编码写入二进制文件，可选自动备份） | needsConfirmation |

新增工具只需：实现 `ToolProtocol` → 在 `DependencyContainer` 中注册到 `ToolRegistry` → 自动出现在 AI 可用工具列表中。

## AI Agent Loop

核心编排在 `ExecuteNaturalLanguageCommandUseCase` 中实现：

```
用户输入自然语言
       │
       ▼
┌──► AI 分析意图 (OpenAI Function Calling)  ◄─── 用户随时可点击 Stop
│      │                                          │
│      ├─ 返回文本 → 展示给用户，循环结束           ▼
│      │                                    代际令牌失效 → Task.cancel()
│      └─ 返回 tool_call                    → AsyncStream.onTermination
│             │                             → URLSession / SSH 命令终止
│             ▼                             → 已生成内容保留并持久化
│      ToolRegistry 查找工具 → 工具自身校验安全级别
│         ├─ safe      → 自动执行
│         ├─ needsConfirmation → 弹框等用户确认
│         └─ forbidden → 直接拦截，通知 AI
│             │
│             ▼
│      工具执行 (底层均通过 SSH) → 结果反馈给 AI
│             │
└─────────────┘  (AI 决定继续执行下一步或总结回复，最多 50 轮)
```

**关键设计：**

- **AI 自主决策** — 每轮循环中 AI 根据上一步的输出决定下一步：继续执行、换一个工具、或总结回复用户
- **工具自治** — 每个工具自带参数 schema、安全校验逻辑和执行逻辑，核心编排器无需了解具体工具
- **多 Tool Call** — 支持模型一次返回多个 tool_calls，按顺序依次执行后统一回填结果
- **流式输出** — 通过 SSE (Server-Sent Events) 实时接收 AI 响应，推理过程和回复内容逐字呈现
- **思维链展示** — 支持 DeepSeek R1、OpenAI o1/o3 等推理模型的 `reasoning_content`，实时展开显示 AI 思考过程，完成后自动折叠
- **用户介入点** — 写操作触发确认弹框，用户拒绝后 AI 收到 `DENIED` 反馈并调整策略
- **安全边界** — 危险命令被拦截后 AI 收到 `BLOCKED`，会尝试用安全方式达成目标
- **随时中断** — 思考/执行过程中发送按钮变为红色停止键，点击立即终止整条链路（AI 流式请求 + SSH 命令），已生成的部分内容保留并持久化
- **防失控** — 最多 50 轮迭代，达到上限时要求 AI 优雅总结已有信息

## SSH 连接管理

### 认证方式

| 方式 | 支持的密钥格式 |
|------|---------------|
| 密码认证 | — |
| Ed25519 私钥 | OpenSSH 格式（支持加密密钥） |
| ECDSA P-256 私钥 | PEM 格式 (BEGIN EC PRIVATE KEY / BEGIN PRIVATE KEY) |
| RSA 私钥 | PEM PKCS#1（含 AES-128/256-CBC、3DES-CBC 加密）→ rsa-sha2-256 |
| RSA 私钥 (回退) | OpenSSH 格式 → ssh-rsa (SHA-1) |

### 主机密钥验证 (TOFU)

首次连接时自动接受并存储服务器指纹（SHA-256），后续连接自动校验。若指纹不匹配（可能的中间人攻击），连接将被拒绝并提示用户。已知主机记录以 JSON 格式持久化在应用文档目录中。

### 连接保活与自动重连

- **心跳检测** — 每 30 秒在后台执行轻量级命令，自动感知连接中断
- **健康检查** — 每 60 秒检查一次底层连接存活状态
- **自动重连 UI** — 连接断开后显示红色横幅和重连按钮；重连过程中显示橙色进度指示
- **命令超时** — 每条命令默认 30 秒超时，防止卡死；可按命令自定义超时时长

### OS 自动检测

SSH 连接建立后自动执行 `uname -s` 探测远程操作系统（Linux / Darwin / FreeBSD 等），AI 上下文中使用真实 OS 信息而非硬编码值，使建议更准确。

## 上下文压缩与网络容错

### 上下文压缩策略

- **触发阈值**：估算 token 使用量超过 `maxContextTokens` 的 95% 时启动压缩
- **保留策略**：保留 `system prompt + 最近消息`，将更早消息折叠为一条摘要系统消息
- **预算分配**：历史消息保留预算约为 `maxContextTokens * 0.70`，给模型回复留余量
- **摘要复用**：若已有 `cachedSummary` 则优先复用，减少重复摘要请求

### 网络重试与流式解析策略

- **重试触发**：仅在 `URLError.networkConnectionLost`（`-1005`）时重试
- **重试次数**：流式请求默认重试 1 次
- **重试间隔**：固定 500ms（当前未使用指数退避）
- **流式容错**：SSE 中单条异常 chunk 会被跳过，整体流继续；致命错误通过 `.error` 事件返回并结束流
- **reasoning_content 自愈**：当 API 返回 400 且与 `reasoning_content` 字段相关时，自动翻转策略（补加或去除该字段）重试

## 安全设计

### 命令安全分级

| 级别 | 行为 | 示例 |
|------|------|------|
| **安全** | 自动执行 | `ls`, `df -h`, `cat`, `ps aux`, `git status`, `read_file`, `list_directory` |
| **需确认** | 弹对话框 | `rm`, `apt install`, `docker compose up`, `write_file`, `systemctl restart` |
| **禁止** | 直接拦截 | `rm -rf /`, `mkfs`, `dd if=/dev/zero`, fork bomb |

### 凭据安全

- **SSH 密码/私钥/口令** — 存储于 iOS Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`)
- **AI API Key** — 存储于 Keychain，首次启动自动从 UserDefaults 迁移并清除明文记录

## 核心流程示例

```
用户: "查看磁盘使用情况"
  → AI 选择 get_system_info (category: disk)，安全，自动执行
  → 返回 df -h 结果给 AI
  → AI 总结: "根目录使用了 45%，/data 分区使用了 78%，建议清理..."

用户: "看看 nginx 配置"
  → AI 选择 read_file (path: /etc/nginx/nginx.conf)，安全，自动执行
  → 返回文件内容给 AI
  → AI 总结: "当前配置了 2 个 server block..."

用户: "重启 nginx 服务"
  → AI 选择 manage_service (service: nginx, action: restart)，需确认，弹框
  → 用户确认 → 执行 → AI 分析结果
  → AI 选择 manage_service (service: nginx, action: status)，安全，自动执行
  → AI 总结: "nginx 已成功重启，当前状态 active (running)"
```

## 项目结构

```
Sources/
├── ConchTalkApp.swift              # 入口
├── Localizable.xcstrings           # 中英双语字符串目录
├── App/
│   └── DependencyContainer.swift   # 依赖注入 + ToolRegistry 组装
├── Domain/                         # 业务逻辑
│   ├── Entities/                   # Server, Message, ToolCall, StreamingDelta, ToolExecutionResult...
│   ├── Protocols/                  # SSH, AI, Tool, ToolRegistry 抽象接口
│   └── UseCases/                   # 核心编排 (Agentic Loop)
├── Data/                           # 数据层实现
│   ├── SSH/                        # SSH 客户端 (Citadel) + KnownHostsStore (TOFU)
│   ├── Network/                    # AI API 直连 (OpenAI Function Calling) + SSE 流式 + 上下文窗口管理
│   ├── Tools/                      # 工具实现 (ToolRegistry + 10 个工具)
│   ├── Persistence/                # SwiftData 持久化 (Server, ServerGroup, Conversation, Message)
│   └── Security/                   # Keychain (SSH 密钥 + API Key)
└── Presentation/                   # UI 层
    ├── Chat/                       # 对话列表 + 聊天界面 (iMessage 风格) + 自动重连横幅
    ├── ServerList/                 # 服务器列表 + 分组 + 搜索 + 分组管理
    ├── ServerSetup/                # 添加服务器 + SSH 密钥导入
    ├── Settings/                   # 设置页 (API Key / Model 配置)
    └── Shared/                     # Theme 设计系统
```

## 功能亮点

- **多工具架构** — 可插拔的 ToolProtocol 体系，AI 自主选择最合适的工具，新增工具只需实现协议并注册
- **SFTP 兼容工具** — 支持 base64 编码读写二进制文件，写入前可自动创建备份
- **流式输出 + 思维链** — SSE 实时接收 AI 响应；推理模型 (DeepSeek R1, o1/o3 等) 的思考过程实时展开，完成后自动折叠，点击可重新展开
- **多 Tool Call** — 支持模型一次返回多个 tool_calls，按序执行后统一回传，避免多轮往返
- **SSH 密钥兼容性** — 支持密码、Ed25519、ECDSA P-256、PEM RSA（含加密 PEM）和 OpenSSH RSA 回退
- **主机密钥验证** — TOFU (Trust On First Use) 机制，自动存储和校验服务器指纹，防范中间人攻击
- **连接保活 + 自动重连** — 心跳检测 + 断线自动感知 + 一键重连 UI，命令级超时保护
- **OS 自动探测** — 连接后自动识别远程操作系统，AI 据此给出更准确的操作建议
- **生成中断** — AI 思考或工具执行过程中可随时点击停止键终止，深度取消贯穿 AI 流式请求和 SSH 命令，已生成的部分回复和工具结果自动保留
- **会话自动标题** — 首次对话后自动根据用户输入生成有意义的会话标题
- **中英双语** — 完整的 `Localizable.xcstrings` 字符串目录，跟随系统语言自动切换中/英文
- **服务器分组** — 按分组管理服务器，支持创建/删除分组，新建服务器时可选择所属分组
- **对话搜索** — 在服务器列表页下拉搜索，按对话标题和消息内容全文检索历史记录，点击结果直达对应对话
- **智能命令确认** — 每个工具自带安全校验，按级别自动执行或弹框确认，危险命令直接拦截
- **上下文窗口管理** — 自动估算 token 用量（中英文混合感知），超限时 AI 生成摘要压缩旧消息，输入框上方实时显示上下文使用百分比（绿/黄/红）
- **凭据安全** — SSH 密码/密钥和 AI API Key 统一存储于 Keychain，不落盘明文

## 技术栈

| 组件 | 技术 |
|------|------|
| UI | SwiftUI + @Observable |
| 平台 | iOS 26+ / macOS 26+ / visionOS 26+ |
| SSH 连接 | [Citadel](https://github.com/orlandos-nl/citadel) (基于 SwiftNIO SSH) |
| AI 集成 | OpenAI Function Calling — 客户端直连，SSE 流式输出，支持任意兼容 API，自动上下文压缩 |
| 工具系统 | ToolProtocol + ToolRegistry（可插拔，自描述 schema，10 个内置工具） |
| 持久化 | SwiftData (@Model, @ModelActor) |
| 本地化 | Localizable.xcstrings (en / zh-Hans) |
| 凭据存储 | iOS Keychain (SSH 密钥 + API Key，kSecAttrAccessibleWhenUnlockedThisDeviceOnly) |
| 并发模型 | Swift 6 Strict Concurrency (actor, async/await, Sendable, MainActor) |

## 快速开始

1. 用 Xcode 打开 `ConchTalk.xcodeproj`
2. 选择目标设备，点击 Run
3. 切换到 Settings 标签，配置 API Key 和模型（默认 `gpt-4o`，支持任意 OpenAI 兼容 API）
4. 在 Servers 标签添加服务器（支持密码和 SSH 密钥认证）
5. 点击服务器 → 进入对话列表 → 新建或选择已有对话

## 待实现

- [x] ~~集成 SSH 库实现真实 SSH 连接~~ (已集成 Citadel，支持密码 + Ed25519/RSA 私钥认证)
- [x] ~~去掉 Go 后端代理~~ (客户端直连 AI API，无需部署后端)
- [x] ~~中英双语本地化~~ (Localizable.xcstrings，en / zh-Hans)
- [x] ~~对话历史搜索~~ (按标题和消息内容全文检索)
- [x] ~~服务器分组管理~~ (分组 CRUD + 服务器归组)
- [x] ~~多工具架构~~ (ToolProtocol 可插拔体系 + 10 个内置工具)
- [x] ~~上下文窗口管理~~ (Token 估算 + 自动摘要压缩 + UI 百分比指示器 + 可配置 maxContextTokens)
- [x] ~~流式输出 + 思维链展示~~ (SSE streaming + reasoning_content 实时展开/自动折叠 + 持久化)
- [x] ~~API Key 迁移到 Keychain~~ (自动从 UserDefaults 迁移，写入失败时保留明文兜底)
- [x] ~~主机密钥验证~~ (TOFU 机制，SHA-256 指纹持久化，防中间人攻击)
- [x] ~~ECDSA 密钥支持~~ (P-256 PEM 格式)
- [x] ~~连接保活 + 自动重连~~ (心跳 + 断线检测 + 重连 UI)
- [x] ~~命令超时~~ (默认 30 秒，可配置)
- [x] ~~OS 自动检测~~ (uname -s，用于 AI 上下文)
- [x] ~~多 tool_calls 支持~~ (SSE 解析 + 队列顺序执行)
- [x] ~~SFTP 兼容工具~~ (base64 二进制读写 + 自动备份)
- [x] ~~会话自动标题~~ (首次对话后自动生成)
- [x] ~~设置页接入主导航~~ (TabView 底部标签栏：服务器 + 设置)
- [x] ~~多会话管理~~ (同一服务器多个对话，ConversationListView 支持新建/删除/恢复)
- [ ] 云端 API 代理 (后端持有 Key + 用户鉴权 + 按 tier 限次：free 5次/天，paid 100次/天；保留自带 Key 作为高级选项)
- [x] SFTP 原生支持 (通过 Citadel SFTPClient 实现真正的二进制文件传输)
- [x] 流式命令输出 (命令执行过程中实时展示输出，替代缓冲模式)
- [x] 生成中断 (Stop 按钮 + 代际令牌防竞态 + 深度取消链路 AI→SSH + 部分内容保留 + 幂等持久化)
- [ ] 交互式 PTY 会话 (支持 vim、top 等需要终端的场景)
