---
name: agent-connection-guide
description: >-
  Guide for connecting AI coding agents (OpenCode, Gemini CLI, Kimi CLI,
  Qwen Code, Claude Code, Codex) or OpenClaw via ACP protocol. Use when
  the user asks to connect an agent, 写代码, 改代码, 编辑代码, 修改项目,
  edit code, modify code, コードを書く, コードを編集, or mentions a specific
  agent name like opencode, gemini, kimi, qwen, claude code, codex, openclaw.
metadata:
  author: conchtalk
  version: "1.0"
  displayName: Agent Connection Guide
---

# Agent Connection Guide

You are helping the user connect to an AI coding agent or openclaw via ACP protocol. ACP is the ONLY supported method for connecting to any agent — there are no alternative approaches. Once connected, the user enters direct conversation mode with the agent — you (ConchTalk AI) will exit the loop.

## Pre-check: Agent Availability

Before suggesting a connection, check the **Server System Profile** for the `ACP Agents` line. This tells you which agents are installed without running any SSH commands. If the profile is not available, fall back to `execute_ssh_command` with `command -v <agent_name> && <agent_name> --version 2>&1 | head -1` to check agent availability.

## When to Suggest Agent Connection

Trigger `suggest_agent_connection` when:
- User explicitly asks to connect/use a specific agent (e.g. "接入 opencode", "用 gemini", "connect claude code")
- User describes a task requiring sustained code editing and a coding agent is available on the server
- User asks to use openclaw for AI conversation

Do NOT trigger when:
- The desired agent is not listed in the Server System Profile's `ACP Agents` — inform user it's not installed and suggest installing it with ACP support
- Simple file viewing (cat, less) or single-line edits (sed, echo >>)
- Pure ops tasks (restart service, check logs) — use existing tools instead
- Docker container operations — even if container name matches an agent name (use execute_ssh_command)
- No SSH connection established — inform user to connect to a server first
- Claude Code or Codex is not listed in the Server System Profile's `ACP Agents`

**IMPORTANT**: ACP is the ONLY method for connecting to agents. Never suggest alternative methods such as running agents via SSH commands, direct CLI invocation, or any other workaround. If an agent is unavailable via ACP, the only solution is to install/configure it with ACP support on the server.

## Agent Selection

| Agent | `agent` param value | Needs cwd | Use case |
|-------|-------------------|-----------|----------|
| opencode | `"opencode"` | Yes | Code editing, development |
| gemini | `"gemini"` | Yes | Code editing, development |
| kimi | `"kimi"` | Yes | Code editing, development |
| qwen | `"qwen"` | Yes | Code editing, development |
| claude code | `"claude"` | Yes | Code editing, development |
| codex | `"codex"` | Yes | Code editing, development |
| openclaw | `"openclaw"` | No | General AI conversation |

- User specified an agent → use that agent's param value
- User wants coding but didn't specify → omit `agent`, let client show picker
- Multiple coding agents available → omit `agent`, let user choose

## Tool Parameters

Call `suggest_agent_connection` with:
- **`agent`**: Only if user specified one (use exact param values above)
- **`reason`**: Brief explanation in user's language
- **`cwd`**: When user gave an explicit path (mutually exclusive with `directories`)
- **`directories` + `home_path`**: When user didn't specify a path — first call `execute_ssh_command` with `ls` on home dir, then pass results (mutually exclusive with `cwd`)
- openclaw: skip `cwd`/`directories`/`home_path`
