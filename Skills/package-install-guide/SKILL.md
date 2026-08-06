---
name: package-install-guide
description: >-
  Structured workflow for installing software packages on remote servers — OS
  detection, package manager discovery, official documentation lookup, and
  verified installation. Use when the user asks to install software, 安装软件,
  安装指南, how to install, setup a tool, or add a package to the server.
metadata:
  author: conchtalk
  version: "1.0"
  displayName: Package Install Guide
---

# Software Installation Guide

You are guiding the user through a structured software installation workflow. Follow these stages in order. After each stage, report results to the user in their language and wait for confirmation before proceeding.

## Stage 1: Environment Detection
Check the **Server System Profile** (auto-detected at connection time) for:
- OS info and architecture
- Package manager (the profile already identifies which package manager is available)
- Whether the target package is already listed as an installed tool

If the profile is not available, fall back to `execute_ssh_command`:
- OS info: `cat /etc/os-release 2>/dev/null || sw_vers 2>/dev/null`
- Architecture: `uname -m`
- Available package managers: check for `apt`, `dnf`, `yum`, `pacman`, `apk`, `zypper`, `brew`, `snap` using `command -v`

## Stage 2: Pre-check
If the target package was found in the Server System Profile with its version, report that directly and ask if the user wants to upgrade or reinstall.

Otherwise, use `execute_ssh_command` to verify:
- Is the package already installed? `command -v <package> && <package> --version`
- If installed, report the version and ask if the user wants to upgrade or reinstall.

## Stage 3: Repository Search
Use `execute_ssh_command` with the detected package manager:
- apt: `apt-cache search <package> && apt-cache show <package>`
- dnf/yum: `dnf search <package> && dnf info <package>`
- pacman: `pacman -Ss <package>`
- apk: `apk search <package>`
- brew: `brew search <package> && brew info <package>`

## Stage 4: Official Documentation Lookup
Use `web_fetch` to check official installation pages. Common official URLs:

| Package | Official Install URL |
|---------|---------------------|
| Docker | https://docs.docker.com/engine/install/ |
| Node.js | https://nodejs.org/en/download/ |
| PostgreSQL | https://www.postgresql.org/download/linux/ |
| Nginx | https://nginx.org/en/linux_packages.html |
| Redis | https://redis.io/docs/getting-started/installation/ |
| Go | https://go.dev/doc/install |
| Rust | https://www.rust-lang.org/tools/install |
| kubectl | https://kubernetes.io/docs/tasks/tools/ |

For packages not in this list, search with `web_fetch` using: `https://duckduckgo.com/html/?q=<package>+official+installation+guide+linux`

## Stage 5: Present Installation Plan
Based on findings, present to the user:
1. Numbered list of commands to execute
2. Source of each command (official docs / package repo)
3. Any warnings or prerequisites

**WAIT for user confirmation before executing any install commands.**

## Stage 6: Execute & Verify
After confirmation:
1. Run install commands via `execute_ssh_command` (one at a time)
2. Verify: `command -v <package> && <package> --version`
3. Report success or failure with details

## Error Handling
- If no package manager found: suggest the user install one or use source compilation
- If official docs are unavailable: inform the user and suggest manual search
- Never guess installation commands — only use verified sources
