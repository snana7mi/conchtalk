---
name: health-check
description: >-
  Comprehensive system health check covering CPU, memory, disk, network, and
  services. Use when the user asks to check server health, 健康检查, 系统检查,
  or diagnose overall system status.
metadata:
  author: conchtalk
  version: "1.0"
  displayName: System Health Check
---

# System Health Check

You are performing a comprehensive system health check. Follow these stages in order. After completing each stage, report results to the user and wait for confirmation before proceeding.

## Stage 1: System Overview
- Check OS version and uptime
- Check CPU usage and load average
- Check memory usage
- Report any immediate concerns

## Stage 2: Disk Health
- Check disk usage for all mounted filesystems
- Flag any partition above 80% usage
- Check for read-only filesystems

## Stage 3: Network Status
- Check network interfaces and connectivity
- Check DNS resolution
- Check listening ports and active connections

## Stage 4: Service Status
- Check status of critical services (sshd, cron, etc.)
- Check for failed systemd units
- Check recent system logs for errors (last 30 minutes)

## Stage 5: Summary
- Present a summary table of all findings
- Categorize issues by severity (critical/warning/ok)
- Suggest remediation actions for any issues found

## Error Handling
If any stage encounters errors that prevent data collection, note the error and continue to the next stage. Present all collected data in the summary.
