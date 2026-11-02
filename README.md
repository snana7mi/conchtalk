# ConchTalk

English | [中文说明](./zh.md)

ConchTalk is an AI personal assistant for iOS that connects to your own remote machines over SSH and turns them into personal compute environments.

It is designed for natural-language-driven work such as server operations, file manipulation, web retrieval, data processing, and coding workflows. The app orchestrates AI, SSH execution, tool calling, and direct agent connections in a single interface.

ConchTalk is fully bring-your-own-service and has no ConchTalk-operated backend. There is no ConchTalk account or sign-in, subscription or billing system, managed AI/search gateway, request relay, or cloud sync. You configure your own AI endpoint, API key, and model, and regular AI requests are sent directly from the app to that provider.

## Download on the App Store

- App Store: https://apps.apple.com/app/conchtalk/id6759644121

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
- Save a finished chat as a runbook and run it again, including from Siri and Shortcuts

## Connection Modes

ConchTalk currently supports two ways to work:

1. **Your own AI API**
   Configure your own endpoint, API key, and model. OpenAI-compatible and Anthropic-style APIs are supported. There is no ConchTalk-hosted fallback.
2. **Direct agent mode**
   If a compatible agent is already available on the remote server, ConchTalk can connect to it directly over SSH — no daemon or relay service is installed on your server. Reconnecting within 14 days resumes the previous agent session (ACP `session/resume` or `session/load`, Claude Code `--resume`, Codex `thread/resume`); clearing the context starts a fresh one. When an ACP agent reports `usage_update`, the direct-mode sheet shows how much of the agent's context window is in use. When an agent requests tool approval via `session/request_permission` (ACP), `control_request` / `can_use_tool` (Claude Code, launched with `--permission-prompt-tool stdio`), or `item/commandExecution/requestApproval` / `item/fileChange/requestApproval` (Codex app-server, threads started with `approvalPolicy: on-request`), the app shows a permission dialog and responds with the ACP-compliant `outcome`/`optionId` (auto-denied after 300 seconds with no action).

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
- Confirm a server's SHA256 host key on first connection, compare old and new fingerprints when the key changes, and review or delete known host keys in Settings
- Execute AI-planned multi-step tasks with tool calls
- Save a finished conversation as a runbook Skill, run it again from the list, or start it from Siri and Shortcuts. The replay still goes through the normal per-server approval flow
- Dispatch parallel subagents for specialized, context-isolated subtasks
- Run the same task on every server in a group. Work is parallel under the same concurrency limit as subagents, each server still asks for its own approval, and the result is a per-server comparison
- Read, write, edit, search, and upload files on remote systems
- Browse remote directories over SFTP, preview text and images, download a file, or attach it to the chat
- Search the live web through Brave, Exa, AnySearch, or Tavily with your own provider API key
- Fetch web content through the remote machine's network (public targets only — non-public addresses are refused to prevent SSRF)
- Keep long-running work alive with Live Activity-powered background execution (iOS) and native background task fallback
- Suggest switching into direct agent mode when a better remote agent is available
- Persist server metadata, chat history, and memory for follow-up tasks
- Show a live plan checklist for multi-step work (`update_plan`) and ask you a question with tappable answer choices when it needs a decision (`ask_user`)
- Keep a task running after you leave the app: tasks you start in the foreground are handed to iOS continued processing (`BGContinuedProcessingTask`, iOS 26+), with progress and a Stop button in the system UI
- Read `~/AGENTS.md` and the `name`/`description` of `~/.agents/skills/*/SKILL.md` on the server (read-only, once per connection) and include them as server reference context
- Manage long conversations automatically: large tool outputs keep their head and tail, older tool results are cleared in batches (stable for prompt caching), and the context budget is capped to the model's context window minus the reply budget
- Run consecutive read-only tool calls from one model response in parallel (up to 4), while writes, approvals, and special tools stay serial and in order
- Set a per-server command allow list and deny list, and revoke saved always-allow rules from the same screen

### AI settings

- **Max Output**: the reply token budget (`max_tokens`). If a reply is cut off mid tool call, ConchTalk tells the model instead of running a half-written call.
- **Thinking Level**: extended thinking / effort for Claude models. Thinking blocks and their signatures are replayed across tool turns, as the Anthropic API requires.
- **Max Context**: for Claude models the settings footer shows the model's context window (200K or 1M), and larger values are capped automatically.

## Built-in Tools

ConchTalk ships with a core tool registry for remote task execution. Depending on context, runtime memory tools may also be injected.

Core tools include:

- `execute_ssh_command` (optional `timeout` 1–600s, default 30; `background: true` detaches with nohup and a log file)
- `poll_background_command` (tail the log of a background command and report whether its pid is still running)
- `read_file`
- `write_file`
- `edit_file`
- `rollback_file` (restore the session snapshot taken before the latest `write_file` / `edit_file` on that path)
- `glob`
- `grep`
- `upload_file`
- `web_search` (only exposed when enabled with an API key for the selected search provider)
- `web_fetch`
- `suggest_agent_connection`
- `activate_skill`
- `dispatch_subagent`
- `update_plan` (shows the agent's plan as a checklist in the chat; no approval needed)
- `ask_user` (asks you one question, optionally with up to 6 answer choices, and ends the turn until you reply)

Contextual memory tools:

- `memory_read`
- `memory_write`

## Subagents

The main agent can offload focused subtasks to subagents via the `dispatch_subagent` tool. Subagents keep intermediate exploration out of the main conversation and return only a refined result, which saves context and reduces noise.

- **Specialized roles**: `explorer` (read-only remote filesystem and system investigation), `ops-diagnostician` (read-only remote diagnosis), and a `general-purpose` role for everything else
- **Parallel execution**: independent subtasks run concurrently under a bounded concurrency cap
- **Inherited permissions**: a subagent inherits the parent's tools (minus `dispatch_subagent`, `update_plan`, and `ask_user`, which only the main agent may use) and permission level
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

- SSH host keys are not trusted silently. The first connection shows the SHA256 fingerprint and continues only after you confirm it. If the key changes, the app shows the stored fingerprint and the new one; you can keep the old key or reset it. Known host keys can be listed and deleted in Settings.
- Per-server command policy: a deny entry blocks a matching command even when it would otherwise be safe or covered by an always-allow rule. A custom allow entry can skip confirmation only when the command is not in the built-in forbidden set. `background: true` still needs confirmation, because it leaves a detached process and a log file. Always-allow rules stay visible on that screen and can be revoked.
- `execute_ssh_command`: a command auto-runs only when every segment is still a read-only allowlisted form. Wrappers (`env` with a child command, `sudo`, `nohup`, `xargs`, `timeout`, `nice`, `time`, `command`, `exec`, `sh`/`bash -c`, and similar) are not auto-safe. Destructive subcommands and flags of allowlisted tools need confirmation (`find -delete`/`-execdir`/`-ok`/`-fprint`/`-fprintf`/`-fls`, `ip link set`, `ip addr flush|add|del`, `ip route add|del`, `hostname <name>`, `date -s`/`--set`, `git branch -d`/`-D`, `git diff --output`). Any write redirection (`>`, `>>`), heredoc/herestring (`<<`), or `tee` still needs confirmation — the AI-reported `is_destructive` flag can only raise risk, never lower it. Recursive `rm` of `/`, `/*`, `~`, `~/`, `$HOME`, or a top-level system directory is forbidden regardless of flag spelling or wrappers; `rm -rf /tmp/build` is not. `mkfs` matches on word boundaries (`mkfs.ext4` is forbidden; `notmkfs` is not). The tool's `timeout` parameter is clamped to 1–600 seconds (default 30). On timeout the remote process group is killed and the SSH connection stays up. `background: true` always needs confirmation: the command is detached with nohup, stdout/stderr go to a log under `/tmp/conchtalk-bg/`, and `poll_background_command` tails that log. Polling does not start a separate iOS task; an in-flight agent task keeps using the existing Live Activity
- `read_file`: private keys, `*.pem`, `*.key`, `.env`, `/etc/shadow`, and similar paths require confirmation. Reads are capped at 1 MiB. Binary files are refused before the body is loaded unless `encoding` is `base64` (still capped). Line numbers are 1-based
- `write_file` / `edit_file`: content is written to a temp file in the same directory, then renamed into place, preserving the original mode and owner when the server allows it. Each change stores a session snapshot; `rollback_file` restores it, and the approval card shows the diff
- `web_fetch`: refuses to fetch non-public addresses (loopback, private ranges, link-local/cloud metadata, CGNAT, IPv6 loopback/ULA) before any remote command runs
- `web_search`: calls the selected Brave, Exa, AnySearch, or Tavily API directly with the user's Keychain-protected key; it is absent from the model tool list while disabled or unconfigured
- Parallel tool calls: only calls that the safety gate would auto-run (an allowlist of read-only tools whose arguments evaluate as `safe`) are run concurrently. A write, an approval prompt, or any other tool ends the parallel batch, so nothing after it runs before you approve it. `strict` mode never runs calls in parallel.
- Server `~/AGENTS.md` and skills are passed as untrusted reference data, like other server data: they cannot grant permissions or bypass approval

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
| Citadel | SSH client functionality and SSH-related primitives (temporarily vendored in `Vendor/` with a patched swift-nio-ssh for GHSA-998x-vgvp-xwpc; see `Vendor/README.md`) | MIT | https://github.com/orlandos-nl/citadel |
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
