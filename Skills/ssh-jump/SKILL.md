---
name: ssh-jump
description: >-
  Connect from the current server to another host using preconfigured SSH keys
  or an SSH agent, without moving credentials through chat or tool arguments.
  Use when the user asks to connect to a jump host, 跳板机, 跳转, 中转,
  remote server, SSH tunnel, リモートサーバーに接続,
  or needs to SSH from the current server to another machine.
compatibility: Requires OpenSSH and preconfigured key or agent authentication
metadata:
  author: conchtalk
  version: "1.1"
  displayName: SSH Jump Connection
---

# SSH Jump Connection

Help the user SSH from the currently connected server to another host. Continue through read-only checks; pause only for a missing choice or before a state-changing command.

## Credential boundary

- Never ask the user to paste a password, private key, passphrase, token, or other secret into chat.
- Never place a secret in tool arguments, shell commands, logs, memory, or replies.
- Do not use `sshpass`, `expect`, password environment variables, or inline credentials.
- Use only a key or SSH agent already configured on the current server. If only password authentication is available, stop and ask the user to configure key-based access from a trusted terminal outside ConchTalk.

## Stage 1: Collect Connection Info

Ask the user for:
- **Host**: IP address or hostname of the target server
- **Port**: SSH port (default 22)
- **Username**: login user
- **Authentication**: an already-configured SSH agent or the path to an existing private key on the current server

If the user provides partial info, ask only for the missing non-secret fields.

## Stage 2: Check SSH Readiness

Use the **Server System Profile** first. If needed, run read-only checks:

```sh
command -v ssh && ssh -V 2>&1
ssh-add -l 2>&1 || true
```

For a user-supplied identity path, verify only that it exists, is a regular file, and has restrictive permissions. Never read or print its contents.

## Stage 3: Test Connection

Run via `execute_ssh_command`:
```sh
ssh -o BatchMode=yes -o ConnectTimeout=10 -p <port> <user>@<host> \
  'echo CONNECTION_OK && hostname && uname -a'
```

Add `-i <identity-path>` only when the user selected an existing key path. Quote all user-supplied values safely. Host-key enrollment changes `known_hosts`, so use the normal confirmation flow if `StrictHostKeyChecking=accept-new` is needed.

- Output contains `CONNECTION_OK` → connection successful, proceed to Stage 4
- Permission denied → explain that the key/agent was not accepted; do not ask for a password
- Connection timeout / refused → inform user to check host/port/firewall
- Host key verification failed → show the fingerprint when available and ask before enrolling or changing the known-host entry

## Stage 4: Success Summary

Report to the user in their language:
- Connection to `<user>@<host>:<port>` succeeded
- Show the remote hostname and OS info from Stage 3
- Explain that subsequent commands can be executed on the remote server via:
  ```sh
  ssh -o BatchMode=yes -p <port> <user>@<host> '<command>'
  ```
- Include `-i <identity-path>` when that authentication route was selected
- Continue to use `execute_ssh_command`, so the normal safety gate remains authoritative

## Error Handling

- No SSH connection to the current server → inform user to connect to a server first
- Password-only target → stop and explain how to configure a public key from a trusted terminal
- Network unreachable → suggest checking if the current server can reach the target (e.g. `ping <host>`)
