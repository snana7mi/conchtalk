# ConchTalk

English | [中文说明](./zh.md)

ConchTalk is an AI personal assistant for iOS that connects to your own remote machines over SSH and turns them into personal compute environments.

It is designed for natural-language-driven work such as server operations, file manipulation, web retrieval, data processing, and coding workflows. The app orchestrates AI, SSH execution, tool calling, and direct agent connections in a single interface.

ConchTalk is fully bring-your-own-service and has no ConchTalk-operated backend. There is no ConchTalk account or sign-in, subscription or billing system, managed AI/search gateway, request relay, or cloud sync. You configure your own AI endpoint, API key, and model, and regular AI requests are sent directly from the app to that provider.

## Try It on TestFlight

- TestFlight: https://testflight.apple.com/join/h4FAQ17v

## Highlights

- SSH-first workflow for remote machines you control
- Multi-step AI agent loop with tool calling
- Parallel subagents with isolated context and specialized roles
- Built-in safety model for read, write, and dangerous operations
- Background task execution with queueing and recovery
- Direct agent mode for compatible remote coding agents
- Cross-session memory support for server-specific context
- Voice input with on-device speech recognition and silence detection
- Multi-language UI: English, Simplified Chinese, Japanese
- No ConchTalk-operated backend, account/sign-in, subscription, managed gateway, request relay, or cloud sync
- Optional bring-your-own web search with Brave, Exa, AnySearch, or Tavily
- Local-first storage for server metadata, chat history, memories, SSH credentials, and AI credentials

## Connection Modes

ConchTalk currently supports two ways to work:

1. **Your own AI API**
   Configure your own endpoint, API key, and model. OpenAI-compatible and Anthropic-style APIs are supported. There is no ConchTalk-hosted fallback.
2. **Direct agent mode**
   If a compatible agent is already available on the remote server, ConchTalk can connect to it directly over SSH — no daemon or relay service is installed on your server. When an agent requests tool approval via `session/request_permission` (ACP) or `control_request` (Claude Code), the app shows a permission dialog and responds with the ACP-compliant `outcome`/`optionId` (auto-denied after 300 seconds with no action).

The current codebase includes built-in support or detection for agents such as:

- **Claude Code** and **Codex** — connected via their native protocols
- **OpenCode**, **Gemini CLI**, **Kimi CLI**, **Qwen Code**, **OpenClaw** — and other agents that speak the **ACP (Agent Client Protocol)**

ConchTalk detects which agents are already installed on the server, so the list above is representative rather than exhaustive.

## Data Flow and Privacy

ConchTalk does not operate a backend that receives, proxies, or synchronizes your app data. Network requests go directly from the app to the destination needed for the feature you use.

| Data | Destination |
|---|---|
| Server metadata, chat history, memories, settings, and task state | Stored on your device |
| SSH passwords, private keys, and provider API keys | Stored in the iOS Keychain |
| AI prompts and relevant context | Your configured AI endpoint |
| SSH commands, files, and direct-agent messages | Your configured remote server |
| Optional web-search queries | Your selected Brave, Exa, AnySearch, or Tavily service |
| Public IP resolved from a configured server host | The public Country API at `api.country.is`, for a two-letter country code |

None of these flows passes through a ConchTalk account, gateway, relay, or cloud-sync service. See the [Privacy Policy](./PRIVACY.md) for retention and provider details.

## What ConchTalk Can Do

- Connect to servers using password or SSH key authentication
- Execute AI-planned multi-step tasks with tool calls
- Dispatch parallel subagents for specialized, context-isolated subtasks
- Read, write, edit, search, and upload files on remote systems
- Search the live web through Brave, Exa, AnySearch, or Tavily with your own provider API key
- Fetch web content through the remote machine's network (public targets only — non-public addresses are refused to prevent SSRF)
- Keep long-running work alive with Live Activity-powered background execution (iOS) and native background task fallback
- Suggest switching into direct agent mode when a better remote agent is available
- Persist server metadata, chat history, and memory for follow-up tasks

## Built-in Tools

ConchTalk ships with a core tool registry for remote task execution. Depending on context, runtime memory tools may also be injected.

Core tools include:

- `execute_ssh_command`
- `read_file`
- `write_file`
- `edit_file`
- `glob`
- `grep`
- `upload_file`
- `web_search` (only exposed when enabled with an API key for the selected search provider)
- `web_fetch`
- `suggest_agent_connection`
- `activate_skill`
- `dispatch_subagent`

Contextual memory tools:

- `memory_read`
- `memory_write`

## Subagents

The main agent can offload focused subtasks to subagents via the `dispatch_subagent` tool. Subagents keep intermediate exploration out of the main conversation and return only a refined result, which saves context and reduces noise.

- **Specialized roles**: `explorer` (read-only remote filesystem and system investigation), `ops-diagnostician` (read-only remote diagnosis), and a `general-purpose` role for everything else
- **Parallel execution**: independent subtasks run concurrently under a bounded concurrency cap
- **Inherited permissions**: a subagent inherits the parent's tools (minus `dispatch_subagent`, to prevent nesting) and permission level
- **Serialized confirmations**: when parallel subagents need approval, requests are funneled one at a time into the same approval UI, labeled by source
- **Context isolation**: only the final per-subagent conclusion is written back to the main conversation as a result card

Roles are defined as Markdown files with YAML frontmatter under `Subagents/`, mirroring the skill system.

## Safety Model

Each tool declares a safety level, then ConchTalk applies a global permission policy:

- **safe**: can run automatically
- **needsConfirmation**: requires user approval
- **forbidden**: blocked

Permission modes:

- `strict`: even normally safe actions require confirmation
- `standard`: read allowed, writes confirmed, dangerous actions blocked
- `permissive`: read/write actions may run automatically, but `forbidden` actions remain blocked

Hardening rules applied on top of safety levels:

- `execute_ssh_command`: any write redirection (`>`, `>>`), heredoc/herestring (`<<`), or `tee` in a whitelisted command chain always requires confirmation — the AI-reported `is_destructive` flag can only raise risk, never lower it
- `web_fetch`: refuses to fetch non-public addresses (loopback, private ranges, link-local/cloud metadata, CGNAT, IPv6 loopback/ULA) before any remote command runs
- `web_search`: calls the selected Brave, Exa, AnySearch, or Tavily API directly with the user's Keychain-protected key; it is absent from the model tool list while disabled or unconfigured

This keeps the assistant useful without removing user control.

## Architecture Overview

ConchTalk uses **SwiftUI + MVVM + Clean Architecture**.

```text
Sources/
├── App/                    # App composition and lifecycle wiring
├── Data/
│   ├── ACP/                # Direct agent transport and session handling
│   ├── BackgroundTask/     # Task orchestration (facade + coordinator pattern)
│   ├── Chat/               # ChatMessageRepository and chat data layer
│   ├── Context/            # Token budgeting and context compaction
│   ├── Memory/             # Retain / Recall / Reflect memory services
│   ├── Network/            # Direct user-configured AI API clients and format adapters
│   ├── Persistence/        # SwiftData models and storage
│   ├── Security/           # Keychain
│   ├── Settings/           # Local settings
│   ├── Skills/             # Markdown skill parsing and registry
│   ├── Speech/             # Speech recognition and audio permission handling
│   ├── SSH/                # SSH connection, exec channels, key handling
│   └── Tools/              # AI tool implementations
├── Domain/                 # Entities, protocols, use cases
├── Presentation/           # SwiftUI screens and view models
└── Resources/Skills/       # Built-in skill templates
```

Key runtime paths:

- **Chat session coordination**: `ChatSessionCoordinator` acts as the single source of truth for a chat session; direct agent mode is managed by `DirectSessionCoordinator`
- **AI requests**: `UserAIService` reads the endpoint, API key, model, and API format stored by the user, then calls that provider directly; there is no platform token, account entitlement, managed endpoint, or fallback gateway
- **AI agent loop**: `ExecuteNaturalLanguageCommandUseCase` drives the cycle of model response → tool call → tool result → next model response
- **Subagent orchestration**: `dispatch_subagent` is intercepted in the agent loop and run by `SubagentRunner`, which executes roles defined under `Subagents/` with bounded concurrency, restricted tool registries (no nested dispatch), and confirmation requests serialized through `SubagentApprovalGate`
- **Tool execution path**: tool calls are checked by `ToolSafetyGate` and executed through `StreamingToolExecutor` when streaming is supported
- **SSH execution**: remote commands run through isolated exec channels rather than a shared persistent shell state
- **Background task management**: `TaskExecutionCoordinator` orchestrates task queuing, execution, approval continuations, and post-processing; `PerServerTaskQueue` manages per-server FIFO queues; `LiveActivityManager` starts a Live Activity to extend background runtime and surface task status on the Lock Screen and Dynamic Island; a native 30-second background task acts as fallback
- **Direct agent mode**: `DirectAgentSession` routes connections to Claude Code, Codex, or ACP-based agents depending on agent type; tool permission requests from the agent surface a user approval dialog with ACP-compliant responses

## Platform and Tech Stack

- **Language:** Swift
- **UI:** SwiftUI
- **Persistence:** SwiftData
- **SSH:** Citadel / SwiftNIO SSH
- **Targets:** iOS 26+

## Direct Dependencies

ConchTalk currently declares the following direct Swift Package dependencies:

| Package | Used for | License | Repository |
|---|---|---|---|
| Citadel | SSH client functionality and SSH-related primitives | MIT | https://github.com/orlandos-nl/citadel |
| swift-acp (`ACPModel`) | ACP-related models/protocol integration for direct agent connectivity | MIT | https://github.com/wiedymi/swift-acp |

## Third-Party Assets and Data Sources

- **Agent logos** are based on assets from **Lobe Icons**  
  Repository: https://github.com/lobehub/lobe-icons  
  License: MIT

- **IP country detection** calls the public third-party **Country API** over HTTPS; no local IP database is bundled and no offline fallback is used
  - Service: https://country.is/ · Repository: https://github.com/lineofflight/country
  - Privacy note: the public IP address resolved from a configured server host is sent to `api.country.is` to obtain its two-letter country code

See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for attribution details.

## Development Status

ConchTalk is currently structured as an actively evolving app codebase. Interfaces, protocols, and supported remote-agent workflows may continue to change.

## Acknowledgements

Special thanks to [LINUX.DO](https://linux.do) for providing a promotion platform.

## License

This project is licensed under the **Apache License 2.0**. See [LICENSE](./LICENSE) for details.

## Chinese Documentation

For Chinese documentation, see [zh.md](./zh.md).
