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

客户端直连 AI API，无需后端代理。核心是一个 **AI Agent Loop**，AI 可以自主选择工具并连续执行多步操作，直到任务完成。

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
| `manage_service` | systemd 服务管理 | status/logs=safe, start/stop/restart=needsConfirmation |

新增工具只需：实现 `ToolProtocol` → 在 `DependencyContainer` 中注册到 `ToolRegistry` → 自动出现在 AI 可用工具列表中。

## AI Agent Loop

核心编排在 `ExecuteNaturalLanguageCommandUseCase` 中实现：

```
用户输入自然语言
       │
       ▼
┌──► AI 分析意图 (OpenAI Function Calling)
│      │
│      ├─ 返回文本 → 展示给用户，循环结束
│      │
│      └─ 返回 tool_call (任意已注册工具)
│             │
│             ▼
│      ToolRegistry 查找工具 → 工具自身校验安全级别
│         ├─ safe      → 自动执行
│         ├─ needsConfirmation → 弹框等用户确认
│         └─ forbidden → 直接拦截，通知 AI
│             │
│             ▼
│      工具执行 (底层均通过 SSH) → 结果反馈给 AI
│             │
└─────────────┘  (AI 决定继续执行下一步或总结回复，最多 10 轮)
```

**关键设计：**

- **AI 自主决策** — 每轮循环中 AI 根据上一步的输出决定下一步：继续执行、换一个工具、或总结回复用户
- **工具自治** — 每个工具自带参数 schema、安全校验逻辑和执行逻辑，核心编排器无需了解具体工具
- **流式中间结果** — 通过 `onIntermediateMessage` 回调，每执行一个工具立即推送到 UI，用户实时可见
- **用户介入点** — 写操作触发确认弹框，用户拒绝后 AI 收到 `DENIED` 反馈并调整策略
- **安全边界** — 危险命令被拦截后 AI 收到 `BLOCKED`，会尝试用安全方式达成目标
- **防失控** — 最多 10 轮迭代，防止 AI 无限循环

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
│   ├── Entities/                   # Server, Message, ToolCall, ToolExecutionResult, ToolError...
│   ├── Protocols/                  # SSH, AI, Tool, ToolRegistry 抽象接口
│   └── UseCases/                   # 核心编排 (Agentic Loop)
├── Data/                           # 数据层实现
│   ├── SSH/                        # SSH 客户端 (Citadel)
│   ├── Network/                    # AI API 直连 (OpenAI Function Calling)
│   ├── Tools/                      # 工具实现 (ToolRegistry + 8 个工具)
│   ├── Persistence/                # SwiftData 持久化 (Server, ServerGroup, Conversation, Message)
│   └── Security/                   # Keychain
└── Presentation/                   # UI 层
    ├── Chat/                       # 对话列表 + 聊天界面 (iMessage 风格)
    ├── ServerList/                 # 服务器列表 + 分组 + 搜索 + 分组管理
    ├── ServerSetup/                # 添加服务器 + SSH 密钥导入
    ├── Settings/                   # 设置页 (API Key / Model 配置)
    └── Shared/                     # Theme 设计系统
```

## 智能确认机制

| 级别 | 行为 | 示例 |
|------|------|------|
| **安全** | 自动执行 | `ls`, `df -h`, `cat`, `ps aux`, `git status`, `read_file`, `list_directory` |
| **需确认** | 弹对话框 | `rm`, `apt install`, `docker compose up`, `write_file`, `systemctl restart` |
| **禁止** | 直接拦截 | `rm -rf /`, `mkfs`, `dd if=/dev/zero`, fork bomb |

## 快速开始

1. 用 Xcode 打开 `ConchTalk.xcodeproj`
2. 选择目标设备，点击 Run
3. 切换到 Settings 标签，配置 API Key 和模型（默认 `gpt-4o`，支持任意 OpenAI 兼容 API）
4. 在 Servers 标签添加服务器（支持密码和 SSH 密钥认证）
5. 点击服务器 → 进入对话列表 → 新建或选择已有对话

## 功能亮点

- **多工具架构** — 可插拔的 ToolProtocol 体系，AI 自主选择最合适的工具，新增工具只需实现协议并注册
- **中英双语** — 完整的 `Localizable.xcstrings` 字符串目录，跟随系统语言自动切换中/英文
- **服务器分组** — 按分组管理服务器，支持创建/删除分组，新建服务器时可选择所属分组
- **对话搜索** — 在服务器列表页下拉搜索，按对话标题和消息内容全文检索历史记录，点击结果直达对应对话
- **智能命令确认** — 每个工具自带安全校验，按级别自动执行或弹框确认，危险命令直接拦截

## 技术栈

| 组件 | 技术 |
|------|------|
| UI | SwiftUI + @Observable |
| 平台 | iOS 26+ / macOS 26+ / visionOS 26+ |
| SSH 连接 | [Citadel](https://github.com/orlandos-nl/citadel) (基于 SwiftNIO SSH) |
| AI 集成 | OpenAI Function Calling — 客户端直连，支持任意兼容 API |
| 工具系统 | ToolProtocol + ToolRegistry（可插拔，自描述 schema） |
| 持久化 | SwiftData (@Model, @ModelActor) |
| 本地化 | Localizable.xcstrings (en / zh-Hans) |
| SSH 密钥存储 | iOS Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly) |
| 并发模型 | Swift 6 Strict Concurrency (actor, async/await, Sendable) |

## 待实现

- [x] ~~集成 SSH 库实现真实 SSH 连接~~ (已集成 Citadel，支持密码 + Ed25519/RSA 私钥认证)
- [x] ~~去掉 Go 后端代理~~ (客户端直连 AI API，无需部署后端)
- [x] ~~中英双语本地化~~ (Localizable.xcstrings，en / zh-Hans)
- [x] ~~对话历史搜索~~ (按标题和消息内容全文检索)
- [x] ~~服务器分组管理~~ (分组 CRUD + 服务器归组)
- [x] ~~多工具架构~~ (ToolProtocol 可插拔体系 + 8 个内置工具)
- [ ] 云端 API 代理 (后端持有 Key + 用户鉴权 + 按 tier 限次：free 5次/天，paid 100次/天；保留自带 Key 作为高级选项)
- [ ] API Key 迁移到 Keychain (当前存 UserDefaults 明文，需改为加密存储)
- [x] ~~设置页接入主导航~~ (TabView 底部标签栏：服务器 + 设置)
- [x] ~~多会话管理~~ (同一服务器多个对话，ConversationListView 支持新建/删除/恢复)
