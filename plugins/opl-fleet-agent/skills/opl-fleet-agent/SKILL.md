---
name: opl-fleet-agent
description: Inspect sanitized node-local OPL Fleet Agent telemetry and bounded doctor results through the OPL Framework contribution broker. Use when Codex needs current or last-known token/request rates, active conversation count, aggregate host telemetry, native carrier availability, or local Fleet Agent diagnostics without reading conversation content or making fleet admission, dispatch, or completion decisions.
---

# OPL Fleet Agent

Use the Framework-owned broker so installed Package discovery and the native carrier remain separate authorities.

## Read telemetry

Run:

```bash
opl app contribution read \
  --package-id opl-fleet-agent \
  --ref fleet.agent.telemetry.v1#local \
  --input '{}'
```

Report carrier availability, freshness, one-minute and five-minute rates, active conversation count, and aggregate host metrics. Label last-known values as stale; do not present them as current.

## Run doctor

Run:

```bash
opl app contribution read \
  --package-id opl-fleet-agent \
  --ref fleet.agent.doctor.v1#current \
  --input '{}'
```

Summarize only structured check IDs, states, and reason codes. Treat an absent native helper as an optional carrier being unavailable, not as a Cordis Host failure.

## Boundaries

- Do not read Codex data files from the plugin. The installed native Fleet Agent owns collection and sanitization.
- Do not expose prompt, response, conversation identifier, filesystem location, network address, credential, secret, or raw log fields.
- Do not infer admission, lease, dispatch, task completion, execution constraints, or receipt truth from observational telemetry.
- Do not add write commands. This Package surface is read-only.
