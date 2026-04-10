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
  version: "1.0"
  displayName: OpenClaw Setup
---

# OpenClaw Setup Guide

Follow these stages in order. After each stage, report results in the user's language and wait for confirmation.

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

Present providers in the user's language and ask them to choose. Collect API key (or OAuth credentials) based on provider. Notes:
- **Cloudflare**: also collect account ID + gateway ID
- **Custom**: also collect base URL, model ID, compatibility (openai/anthropic)
- **MiniMax**: ask region (Global/CN) and auth method (API key/OAuth)
- **Alibaba Cloud**: ask region (Global `modelstudio-api-key` / CN `modelstudio-api-key-cn`)
- **Local providers** (Ollama/SGLang/vLLM): no API key needed
- **OAuth providers** (Qwen/Copilot/Chutes): inform user that interactive auth may be needed

## Stage 4: Gateway Config
Defaults: port `18789`, bind `loopback`. Ask if user wants to customize.
Valid bind: `loopback`, `lan`, `tailnet`, `auto`, `custom`.

## Stage 5: Execute Onboard
Assemble command, show to user, execute after confirmation:
```
openclaw onboard --non-interactive --mode local \
  --auth-choice <choice> --<provider>-api-key "<key>" \
  --secret-input-mode plaintext \
  --gateway-port <port> --gateway-bind <bind> \
  --install-daemon --daemon-runtime node --skip-skills
```

## Stage 6: Verify
Run `openclaw daemon status`. Report result.
Use `execute_ssh_command` with `command -v openclaw && openclaw --version` to verify OpenClaw is available.
If failed → suggest checking logs (`journalctl -u openclaw` on Linux).

## Error Handling
- No Node.js → suggest installing first
- Installer script fails → check permissions/network
- Onboard fails → verify API key
- Daemon fails → check logs
