# ConchTalk

English | [中文说明](./zh.md)

ConchTalk is an AI personal assistant for iOS that connects to your own remote machines over SSH and turns them into personal compute environments.

It is designed for natural-language-driven work such as server operations, file manipulation, web retrieval, data processing, and coding workflows. The app orchestrates AI, SSH execution, tool calling, and direct agent connections in a single interface.

## Try It on TestFlight

- TestFlight: https://testflight.apple.com/join/h4FAQ17v

## Highlights

- SSH-first workflow for remote machines you control
- Multi-step AI agent loop with tool calling
- Built-in safety model for read, write, and dangerous operations
- Background task execution with queueing and recovery
- Direct agent mode for compatible remote coding agents
- Cross-session memory support for server-specific context
- Voice input with on-device speech recognition and silence detection
- Multi-language UI: English, Simplified Chinese, Japanese
- In-app subscription with RevenueCat (Pro tier unlocks cloud sync and premium features)
- Cloud sync with end-to-end encryption (Pro tier)

## Cloud Sync

Paid users can sync all local data (servers, messages, SSH keys, memories, system profiles) to the cloud with end-to-end encryption. The master encryption key is stored in iCloud Keychain and automatically shared across the user's Apple devices.

- **Auto-enabled** for paid users on first login; can be manually toggled in Settings → Cloud Sync
- **Disabling sync immediately deletes all cloud data** — privacy-first design, local data is unaffected
- **E2E encryption**: AES-256-GCM with HKDF per-entity-type key derivation; server never sees plaintext
- **Automatic sync** triggers when the app enters background
- **Incremental push/pull** with composite cursor pagination; cross-entity-type global version ordering
- **Last-Write-Wins (LWW)** conflict resolution based on `modifiedAt` timestamps
- **Soft delete** with 30-day retention before physical cleanup
- **Storage limit**: 100 MB per user with automatic oldest-message pruning
- **Key reset**: users can regenerate encryption keys, triggering cloud data wipe and full re-upload

## Connection Modes

ConchTalk currently supports three ways to work:

1. **Managed AI service**  
   The default path uses the app's authenticated managed AI service flow.
2. **Custom API**  
   You can configure your own endpoint, API key, and model. OpenAI-compatible and Anthropic-style APIs are supported.
3. **Direct agent mode**  
   If a compatible agent is available on the remote server, ConchTalk can connect to it directly over SSH.

The current codebase includes support for or detection of the following agent types:

- Claude Code
- Codex
- OpenCode
- Gemini CLI
- Kimi CLI
- OpenClaw
- Qwen Code

## What ConchTalk Can Do

- Connect to servers using password or SSH key authentication
- Execute AI-planned multi-step tasks with tool calls
- Read, write, edit, search, and upload files on remote systems
- Fetch web content through the remote machine's network
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
- `web_fetch`
- `suggest_agent_connection`
- `activate_skill`

Conditionally injected tool:

- `web_search` — available when the app is running with the authenticated managed AI service flow; implemented through the app's managed web-search path

Contextual memory tools:

- `memory_read`
- `memory_write`

## Safety Model

Each tool declares a safety level, then ConchTalk applies a global permission policy:

- **safe**: can run automatically
- **needsConfirmation**: requires user approval
- **forbidden**: blocked

Permission modes:

- `strict`: even normally safe actions require confirmation
- `standard`: read allowed, writes confirmed, dangerous actions blocked
- `permissive`: read/write allowed automatically, dangerous actions still gated

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
│   ├── Network/            # AI services, auth, API format adapters
│   ├── Persistence/        # SwiftData models and storage
│   ├── Security/           # Keychain
│   ├── Settings/           # Local settings
│   ├── Skills/             # Markdown skill parsing and registry
│   ├── Speech/             # Speech recognition and audio permission handling
│   ├── SSH/                # SSH connection, exec channels, key handling
│   ├── Subscription/       # RevenueCat subscription lifecycle management
│   └── Tools/              # AI tool implementations
├── Domain/                 # Entities, protocols, use cases
├── Presentation/           # SwiftUI screens and view models (includes Paywall/)
└── Resources/Skills/       # Built-in skill templates
```

Key runtime paths:

- **Chat session coordination**: `ChatSessionCoordinator` acts as the single source of truth for a chat session; direct agent mode is managed by `DirectSessionCoordinator`
- **AI agent loop**: `ExecuteNaturalLanguageCommandUseCase` drives the cycle of model response → tool call → tool result → next model response
- **Tool execution path**: tool calls are checked by `ToolSafetyGate` and executed through `StreamingToolExecutor` when streaming is supported
- **SSH execution**: remote commands run through isolated exec channels rather than a shared persistent shell state
- **Background task management**: `TaskExecutionCoordinator` orchestrates task queuing, execution, approval continuations, and post-processing; `PerServerTaskQueue` manages per-server FIFO queues; `LiveActivityManager` starts a Live Activity to extend background runtime and surface task status on the Lock Screen and Dynamic Island; a native 30-second background task acts as fallback
- **Direct agent mode**: `DirectAgentSession` routes connections to Claude Code, Codex, or ACP-based agents depending on agent type

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
| RevenueCat (`purchases-ios`) | In-app subscription management and purchase lifecycle | MIT | https://github.com/RevenueCat/purchases-ios |

## Third-Party Assets and Data Sources

- **Agent logos** are based on assets from **Lobe Icons**  
  Repository: https://github.com/lobehub/lobe-icons  
  License: MIT

- **IP geolocation data pipeline/source reference** uses resources from **sapics/ip-location-db**  
  Repository: https://github.com/sapics/ip-location-db  

See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for attribution details.

## Development Status

ConchTalk is currently structured as an actively evolving app codebase. Interfaces, protocols, and supported remote-agent workflows may continue to change.

## Acknowledgements

Special thanks to [LINUX.DO](https://linux.do) for providing a promotion platform.

## License

This project is licensed under the **Apache License 2.0**. See [LICENSE](./LICENSE) for details.

## Chinese Documentation

For Chinese documentation, see [zh.md](./zh.md).
