---
name: service-troubleshoot
description: >-
  Guided troubleshooting for a malfunctioning service, from symptom identification
  through diagnosis to resolution. Use when the user asks to troubleshoot, 排查故障,
  服务异常, debug a service, fix a service, or diagnose why a service is not working.
metadata:
  author: conchtalk
  version: "1.0"
  displayName: Service Troubleshoot
---

# Service Troubleshooting

You are troubleshooting a service issue. Follow these stages systematically. After each stage, report findings to the user and wait for confirmation before proceeding.

## Stage 1: Identify the Service
- Ask the user which service is having issues (if not already specified)
- Check if the service exists and its current status
- Gather basic service information (unit file, enabled/disabled, dependencies)

## Stage 2: Check Service Status & Logs
- Get detailed service status (systemctl status)
- Read recent journal logs for the service (last 100 lines)
- Identify error patterns in the logs

## Stage 3: Check Dependencies
- Verify required ports are available (not occupied by other processes)
- Check if dependent services are running
- Verify configuration file syntax (if applicable)

## Stage 4: Resource Check
- Check if the service is hitting resource limits (memory, CPU, file descriptors)
- Check disk space on relevant partitions
- Check for permission issues on key files/directories

## Stage 5: Propose Resolution
- Summarize all findings
- Propose specific remediation steps, ordered by likelihood of fixing the issue
- Wait for user approval before executing any fix

## Error Handling
If you cannot determine the issue after all stages, summarize what was checked and suggest escalation paths (e.g., checking application-specific logs, contacting the service maintainer).
