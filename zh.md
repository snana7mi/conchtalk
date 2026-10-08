# ConchTalk 中文说明

[English README](./README.md)

ConchTalk 是一个运行在 iOS 上的 AI 个人助手应用。它通过 SSH 连接你自己的远程服务器，把这些机器作为个人计算环境来使用。

它面向自然语言驱动的远程工作流，例如：服务器运维、文件处理、网页抓取、数据处理以及编码协作。应用负责在 AI、SSH、工具调用和远程代理直连之间完成统一编排。

ConchTalk 完全采用用户自有服务路线，不运营任何 ConchTalk 后端：不包含 ConchTalk 账号或登录、订阅或计费系统、托管的 AI/搜索网关、请求中继或云同步。用户必须配置自己的 AI endpoint、API key 和 model，普通 AI 请求由 App 直接发送给用户选择的服务商。

## App Store 下载

- App Store：https://apps.apple.com/app/conchtalk/id6759644121

## 核心特性

- 以 SSH 为核心，面向你自己控制的远程机器
- 支持多步 AI Agent Loop 与 Tool Calling
- 支持上下文隔离的并行 subagent 与预置专业角色
- 内置读 / 写 / 高危操作安全分级
- 支持后台任务继续执行、排队与恢复
- 支持兼容远程编码代理的直连模式
- 支持跨会话记忆，保留服务器上下文
- 支持语音输入，基于设备端语音识别与静默检测
- 支持 English / 中文 / 日本語 多语言界面
- 不运营 ConchTalk 后端，不含账号/登录、订阅、托管网关、请求中继或云同步
- 可选使用用户自有的 Brave、Exa、AnySearch 或 Tavily 服务，实现实时联网搜索
- 服务器信息、聊天记录、记忆、SSH 凭据和 AI 凭据均采用本地存储

## 连接模式

ConchTalk 当前支持两种工作模式：

1. **用户自有 AI API**
   用户必须配置自己的 endpoint、API key 和 model，支持 OpenAI Compatible 和 Anthropic 风格接口，不存在 ConchTalk 托管的兜底路线。
2. **直连代理模式**
   如果远程服务器上已存在兼容代理，ConchTalk 可以直接通过 SSH 与该代理通信，无需在服务器上安装任何守护进程或中继服务。

当前代码内置支持或可探测的代理（列表非穷举），例如：

- **Claude Code**、**Codex** —— 通过各自的原生协议接入
- **OpenCode**、**Gemini CLI**、**Kimi CLI**、**Qwen Code**、**OpenClaw** —— 以及其他兼容 **ACP（Agent Client Protocol）** 协议的代理

ConchTalk 会探测服务器上已安装的代理，因此上面只是代表性列举，并非完整清单。

## 数据流与隐私

ConchTalk 不运营用于接收、代理或同步应用数据的后端。网络请求只会由 App 直接发送至当前功能所需的目标服务。

| 数据 | 去向 |
|---|---|
| 服务器信息、聊天记录、记忆、设置与任务状态 | 存储在用户设备上 |
| SSH 密码、私钥与服务商 API Key | 存储在 iOS Keychain 中 |
| AI 提示词与相关上下文 | 用户配置的 AI endpoint |
| SSH 命令、文件与直连代理消息 | 用户配置的远程服务器 |
| 可选的联网搜索查询 | 用户选择的 Brave、Exa、AnySearch 或 Tavily 服务 |
| 从服务器主机解析得到的公网 IP | 第三方公开 Country API（`api.country.is`），用于获取两位国家代码 |

以上数据流均不经过 ConchTalk 账号、网关、中继或云同步服务。数据保留与第三方服务说明请参阅[隐私政策](./PRIVACY.md)。

## 可以做什么

- 使用密码或 SSH key 连接远程服务器
- 通过 AI 规划多步任务并调用工具执行
- 将独立子任务分派给专业 subagent 并行执行，减少主对话上下文噪音
- 在远程系统上读取、写入、编辑、搜索、上传文件
- 可使用用户自己的搜索服务 API Key，通过 Brave、Exa、AnySearch 或 Tavily 搜索实时互联网内容
- 借助远程机器的网络抓取网页内容
- 优先通过 tmux 管理长时间运行任务
- 在检测到更合适的远程代理时建议切换到直连模式
- 持久化服务器信息、聊天记录与记忆内容，便于后续接续工作

## 内置工具

核心工具包括：

- `execute_ssh_command`
- `read_file`
- `write_file`
- `edit_file`
- `glob`
- `grep`
- `upload_file`
- `web_search`（仅在设置中开启并保存所选搜索服务的 API Key 后可用）
- `web_fetch`
- `suggest_agent_connection`
- `activate_skill`
- `dispatch_subagent`

按上下文注入的记忆工具：

- `memory_read`
- `memory_write`

## Subagents

主 agent 可以通过 `dispatch_subagent` 工具把聚焦子任务分派给 subagent。subagent 的中间探索不会污染主对话，只把整理后的结论回填给主 agent，从而节省上下文并降低噪音。

- **预置角色**：`explorer`（只读远程文件系统与系统环境探查）、`ops-diagnostician`（只读远程诊断）以及兜底的 `general-purpose`
- **并行执行**：互相独立的子任务可在并发上限内同时运行
- **权限继承**：subagent 继承父任务的权限级别，并以父工具表为基础按角色白名单裁剪；始终移除 `dispatch_subagent`，防止嵌套分派
- **确认串行冒泡**：并行 subagent 若触发确认请求，会逐个进入同一套审批 UI
- **上下文隔离**：主对话只看到每个 subagent 的最终结论卡片

角色定义使用带 YAML frontmatter 的 Markdown 文件，放在 `Subagents/` 目录下，机制与 Skill 系统类似。

## 安全模型

每个工具都会声明安全级别，ConchTalk 再叠加全局权限策略：

- **safe**：可自动执行
- **needsConfirmation**：需要用户确认
- **forbidden**：禁止执行

权限模式：

- `strict`：即使是安全操作也需要确认
- `standard`：读操作自动执行，写操作确认，高危操作拦截
- `permissive`：读写操作可自动执行，但 `forbidden` 操作仍会被禁止

额外安全约束：`web_search` 由 App 使用 Keychain 中的用户 Key 直接请求所选的 Brave、Exa、AnySearch 或 Tavily 服务；关闭或未配置 Key 时，不会向模型暴露该工具。

## 架构概览

ConchTalk 采用 **SwiftUI + MVVM + Clean Architecture**。

```text
Sources/
├── App/                    # 应用装配与生命周期
├── Data/
│   ├── ACP/                # 直连代理传输与会话管理
│   ├── BackgroundTask/     # 任务编排（门面 + Coordinator 模式）
│   ├── Chat/               # ChatMessageRepository 等聊天数据层
│   ├── Context/            # Token 预算与上下文压缩
│   ├── Memory/             # Retain / Recall / Reflect 记忆服务
│   ├── Network/            # 用户自有 AI API 客户端与接口协议适配
│   ├── Persistence/        # SwiftData 模型与存储
│   ├── Security/           # Keychain
│   ├── Settings/           # 本地设置
│   ├── Skills/             # Markdown Skill 解析与注册
│   ├── Speech/             # 语音识别与音频权限管理
│   ├── SSH/                # SSH 连接、exec channel、密钥处理
│   └── Tools/              # AI 工具实现
├── Domain/                 # 实体、协议、用例
├── Presentation/           # SwiftUI 页面与 ViewModel
└── Resources/Skills/       # 内置 Skill 模板
```

主要运行路径包括：

- **聊天会话协调**：`ChatSessionCoordinator` 作为聊天会话的单一状态源；直连模式由 `DirectSessionCoordinator` 管理
- **AI 请求**：`UserAIService` 读取用户保存的 endpoint、API key、model 和 API 格式后直接请求该服务商；不存在平台 token、账户权限、托管 endpoint 或兜底网关
- **AI agent loop**：由 `ExecuteNaturalLanguageCommandUseCase` 驱动，按”模型回复 → 工具调用 → 工具结果 → 下一轮模型回复”的方式循环推进
- **Subagent 编排**：`dispatch_subagent` 在 agent loop 中被拦截并交给 `SubagentRunner` 执行；角色定义来自 `Subagents/`，执行时受并发上限、受限工具表（禁止嵌套分派）和 `SubagentApprovalGate` 串行确认保护
- **工具执行路径**：工具调用先经过 `ToolSafetyGate` 校验，再由支持流式的 `StreamingToolExecutor` 执行
- **SSH 执行**：远程命令通过隔离的 exec channel 执行，而不是依赖共享的持久 shell 状态
- **后台任务管理**：`TaskExecutionCoordinator` 编排任务排队、执行、审批续体和善后处理；`PerServerTaskQueue` 按服务器维度管理 FIFO 队列；`LiveActivityManager` 通过 Live Activity 延长后台运行时间
- **直连代理模式**：`DirectAgentSession` 会根据代理类型路由到 Claude Code、Codex 或 ACP 代理连接实现

## 平台与技术栈

- **语言：** Swift
- **UI：** SwiftUI
- **持久化：** SwiftData
- **SSH：** Citadel / SwiftNIO SSH
- **目标平台：** iOS 26+

## 直接依赖

ConchTalk 当前声明的直接 Swift Package 依赖如下：

| Package | 用途 | License | 仓库 |
|---|---|---|---|
| Citadel | SSH 客户端能力与相关 SSH 基础功能（临时 vendored 于 `Vendor/`，并附带修复 GHSA-998x-vgvp-xwpc 的 swift-nio-ssh 补丁，见 `Vendor/README.md`） | MIT | https://github.com/orlandos-nl/citadel |
| swift-acp (`ACPModel`) | 用于直连代理能力中的 ACP 协议模型集成 | MIT | https://github.com/wiedymi/swift-acp |

## 第三方资源与数据来源

- **AI Agent 头像资源** 基于 **Lobe Icons**  
  仓库：https://github.com/lobehub/lobe-icons  
  License：MIT

- **IP 国家检测** 强制通过 HTTPS 调用第三方公开的 **Country API**，应用不再内置本地 IP 数据库，也不提供离线回退
  - 服务：https://country.is/ · 仓库：https://github.com/lineofflight/country
  - 隐私说明：应用会将服务器主机解析得到的公网 IP 地址发送至 `api.country.is`，仅查询两位国家代码
  
详见 [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md)。

## 鸣谢

特别感谢 [LINUX.DO](https://linux.do) 提供推广平台。

## 项目许可证

本项目使用 **Apache License 2.0** 开源。详见 [LICENSE](./LICENSE)。
