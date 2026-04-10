---
name: ssh-jump
description: >-
  Connect to remote servers via SSH using sshpass for password authentication.
  Use when the user asks to connect to a jump host, 跳板机, 跳转, 中转,
  remote server, SSH tunnel with password auth, リモートサーバーに���続,
  or needs to SSH from the current server to another machine.
compatibility: Requires sshpass installed on the remote server
metadata:
  author: conchtalk
  version: "1.0"
  displayName: SSH Jump Connection
---

# SSH Jump Connection

You are helping the user SSH from the currently connected server to a third-party remote server using password authentication. Follow these stages in order. After each stage, report results in the user's language and wait for confirmation.

## Stage 1: Collect Connection Info

Ask the user for:
- **Host**: IP address or hostname of the target server
- **Port**: SSH port (default 22)
- **Username**: login user
- **Password**: login password

If the user provides partial info (e.g. just an IP), ask for the missing fields. Do NOT proceed until all required fields are collected.

## Stage 2: Check sshpass Availability

Check the **Server System Profile** (auto-detected at connection time) for `sshpass` availability.

If the profile shows `sshpass` is available → proceed to Stage 3.

If the profile is not available or doesn't include sshpass, fall back to `execute_ssh_command`:
```
command -v sshpass && sshpass -V 2>&1 | head -1
```

- Available → proceed to Stage 3
- Not available → inform the user that `sshpass` is required and suggest installing it (e.g. `apt install sshpass` / `yum install sshpass`). Do NOT install it yourself — let the user confirm the install command via `execute_ssh_command`.

## Stage 3: Test Connection

Run via `execute_ssh_command`:
```
sshpass -p '<password>' ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -p <port> <user>@<host> 'echo CONNECTION_OK && hostname && uname -a'
```

- Output contains `CONNECTION_OK` → connection successful, proceed to Stage 4
- Permission denied → inform user credentials may be wrong, ask to re-enter
- Connection timeout / refused → inform user to check host/port/firewall
- Host key verification failed → suggest adding `-o StrictHostKeyChecking=accept-new` or clearing known_hosts entry

## Stage 4: Success Summary

Report to the user in their language:
- Connection to `<user>@<host>:<port>` succeeded
- Show the remote hostname and OS info from Stage 3
- Explain that subsequent commands can be executed on the remote server via:
  ```
  sshpass -p '<password>' ssh -p <port> <user>@<host> '<command>'
  ```
- Suggest the user can now use `execute_ssh_command` with the above pattern to run commands on the remote server

## Error Handling

- No SSH connection to the current server → inform user to connect to a server first
- sshpass not installed and user declines to install → cannot proceed, explain why sshpass is needed
- Network unreachable → suggest checking if the current server can reach the target (e.g. `ping <host>`)
