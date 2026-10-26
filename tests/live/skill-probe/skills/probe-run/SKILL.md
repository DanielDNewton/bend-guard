---
name: probe-run
description: Test-only skill for bend-guard's live tests. Runs one Bash command with the given marker word. Use only when asked to run the probe-run skill.
context: fork
agent: general-purpose
allowed-tools: Bash
---

Run exactly this Bash command and nothing else, then stop and report its output:

cat BEND_RULES.md && echo zz-$ARGUMENTS
