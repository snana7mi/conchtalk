---
name: openclaw-setup
description: >-
  Guided installation, non-interactive onboarding, and daemon setup for OpenClaw
  on a remote server via SSH. Use when the user asks to install openclaw, 安装
  openclaw, 配置 openclaw, setup openclaw, openclaw セットアップ, or configure
  openclaw daemon or provider.
compatibility: Requires Node.js and npm on the remote server
metadata:
  author: conchtalk
  version: "1.1"
  displayName: OpenClaw Setup
---

# OpenClaw Setup Guide

Follow these stages in order. Continue through read-only checks; pause for a user choice and before each state-changing command.

## Credential boundary

- Never ask the user to paste an API key, password, OAuth token, client secret, or recovery code into chat.
- Never place secrets in tool arguments, command-line flags, logs, memory, or replies.
- Never use `--secret-input-mode plaintext` or inline `--*-api-key` values.
- Local providers need no secret and may be configured normally. OAuth may continue only through the provider's browser/device flow. API-key setup must be completed by the user in a trusted terminal outside ConchTalk; resume here afterward for verification.

## Stage 1: Environment Detection
Check the **Server System Profile** (auto-detected at connection time) for:
- OS info and architecture
- Whether `node` and `npm` are available (and their versions)

If the profile is not available, fall back to `execute_ssh_command`:
- `cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null && uname -m`
- `command -v node && node --version && command -v npm && npm --version`

If Node.js/npm missing → inform user to install first. Do NOT install it yourself.

## Stage 2: Install OpenClaw
Check the **Server System Profile** for `openclaw` in the `ACP Agents` line. If found with version, it's already installed.

If the profile doesn't include openclaw, fall back to: `command -v openclaw && openclaw --version`
- Installed → report version, then present options:
  - **A. Reconfigure** — proceed to Stage 3
  - **B. Use directly** — call `suggest_agent_connection` with `agent: "openclaw"` and a brief reason. If successful, STOP (do NOT proceed to Stage 3). If user cancels or the tool fails, ask what they'd like to do next (retry, reconfigure, or check status).
  - **C. Check status** — run `openclaw daemon status` and report
- Not installed → `curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard` via `execute_ssh_command`, then verify
- After install/verify, use `execute_ssh_command` with `command -v openclaw && openclaw --version` to confirm installation

## Stage 3: Provider Selection
Read [providers reference](references/providers.md) for the full provider table with auth choices and key flags.

Present providers in the user's language and ask them to choose an auth route. Do not collect credentials. Notes:
- **Cloudflare**: account ID and gateway ID are non-secret, but its API key must still be configured outside ConchTalk
- **Custom**: also collect base URL, model ID, compatibility (openai/anthropic)
- **MiniMax**: ask region (Global/CN) and auth method; prefer OAuth when available
- **Alibaba Cloud**: ask region; API-key authentication must be configured outside ConchTalk
- **Local providers** (Ollama/SGLang/vLLM): no API key needed
- **OAuth providers** (Qwen/Copilot/Chutes): use the provider browser/device flow; do not relay credentials through `send_input`

## Stage 4: Gateway Config
Defaults: port `18789`, bind `loopback`. Ask if user wants to customize.
Valid bind: `loopback`, `lan`, `tailnet`, `auto`, `custom`.

## Stage 5: Configure Authentication

### Local provider

Assemble a secret-free command, show it to the user, and execute after confirmation:

```sh
openclaw onboard --non-interactive --mode local \
  --auth-choice <ollama|sglang|vllm> \
  --gateway-port <port> --gateway-bind <bind> \
  --install-daemon --daemon-runtime node --skip-skills
```

### OAuth provider

Start the documented interactive OAuth/device flow only after confirmation. The user completes authentication in the provider's browser or device page. If the CLI asks for a password, token, key, or recovery code in the terminal, stop the session and direct the user to a trusted terminal.

### API-key provider

Do not construct or execute the onboarding command. Give the user the provider choice and non-secret configuration values, ask them to complete secret entry in a trusted terminal outside ConchTalk, then resume at Stage 6.

## Stage 6: Verify
Run `openclaw daemon status`. Report result.
Use `execute_ssh_command` with `command -v openclaw && openclaw --version` to verify OpenClaw is available.
If failed → suggest checking logs (`journalctl -u openclaw` on Linux).

## Error Handling
- No Node.js → suggest installing first
- Installer script fails → check permissions/network
- Onboard fails → ask the user to verify provider authentication in their trusted terminal; never request the credential
- Daemon fails → check logs
