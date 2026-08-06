---
name: cli-tool-prompt-guide
description: >-
  Prompt optimization guide for running AI CLI tools (Claude Code, Codex,
  OpenCode, Gemini CLI, OpenClaw) in non-interactive one-shot mode on remote
  servers. Use when the user asks about prompt optimization, 非交互模式,
  one-shot command, or wants to build an optimized CLI command for an AI tool.
compatibility: Requires at least one AI CLI tool installed on the server
metadata:
  author: conchtalk
  version: "1.0"
  displayName: CLI Tool Prompt Optimization
---

# AI CLI Tool — Non-Interactive Prompt Guide

When the user wants to run an AI CLI tool on a remote server in non-interactive (one-shot) mode, use this guide to build an optimized command.

## Step 1: Identify the Tool

Ask which tool the user wants to use, or infer from context:

| Tool | Command | Non-Interactive Flag | Instruction File |
|------|---------|---------------------|------------------|
| Claude Code | `claude` | `-p` | `CLAUDE.md` |
| Codex CLI | `codex` | `exec` | `~/.codex/config.toml` |
| OpenCode | `opencode` | `run` | `AGENTS.md` |
| Gemini CLI | `gemini` | `-p` | `GEMINI.md` |
| OpenClaw | `openclaw` | `agent --message` | `~/.openclaw/openclaw.json` |

## Step 2: Key Flags Reference

### Claude Code
- `-p, --print` — non-interactive mode
- `--model <model>` — set model (sonnet, opus, or full ID)
- `--max-turns <N>` — limit agentic loop iterations
- `--allowedTools` — whitelist tools, e.g. `"Bash(git *)" "Read"`
- `--output-format json` — structured JSON output
- `--append-system-prompt` — add instructions to system prompt

### Codex CLI
- `-m, --model <model>` — override model (default: gpt-5.4)
- `-s, --sandbox <mode>` — read-only, workspace-write, danger-full-access
- `--full-auto` — preset: workspace-write + on-request approvals
- `-i, --image <path>` — attach image files

### OpenCode
- `-m, --model <model>` — set model (supports 75+ providers)
- `--agent <name>` — select agent: build (full access) or plan (read-only)
- `-f, --file <path>` — attach files to prompt

### Gemini CLI
- `-m <model>` — specify model (e.g. gemini-2.5-pro)
- `--include-directories <dirs>` — include additional directories as context
- `--output-format json` — structured JSON output

### OpenClaw
- `agent --thinking` — enable chain-of-thought
- `--profile <name>` — profile isolation for multi-project setups
- `--json` — machine-readable JSON output

## Step 3: Build the Command

Use `execute_ssh_command` to run the CLI tool. Templates:

```
claude -p "<TASK>" --max-turns 10
codex exec "<TASK>"
opencode run "<TASK>"
gemini -p "<TASK>"
openclaw agent --message "<TASK>"
```

## Step 4: Prompt Optimization Tips

1. **Be specific**: include file paths, function names, and constraints
2. **Provide context**: mention the language, framework, and project structure
3. **State the goal, not just the action**: "fix the login bug where..." > "edit auth.js"
4. **Reference existing patterns**: "follow the style in src/components/Button.tsx"
5. **Include verification**: "run tests after changes" or "show me the diff"
6. **For complex tasks**, break into steps or use plan-then-execute mode
7. **Attach relevant files** when available (Codex `-i`, OpenCode `-f`)

## Installation Commands

If the tool is not installed, use `execute_ssh_command`:
- Claude Code: `npm install -g @anthropic-ai/claude-code`
- Codex: `npm install -g @openai/codex`
- OpenCode: `curl -fsSL https://opencode.ai/install.sh | bash`
- Gemini CLI: `npm install -g @google/gemini-cli`
- OpenClaw: `npm install -g openclaw`
