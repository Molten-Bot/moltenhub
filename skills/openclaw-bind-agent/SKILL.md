---
name: openclaw-bind-agent
description: Register an OpenClaw agent on the local Statocyst bus and configure one-way inbound allow rules. Use when setting up agent identity/token state and receiver-controlled sender permissions for local POC message exchange tests.
---

# OpenClaw Bind Agent

## Workflow

1. Require `base_url`, `agent_id`, and `from_agent_id`.
2. Register the agent with `POST /v1/agents/register`.
3. Capture the returned token.
4. Apply inbound allow with `POST /v1/agents/{agent_id}/allow-inbound`.
5. Stop immediately on non-2xx responses and surface status/body excerpt.

## Required Inputs

- `base_url`
- `agent_id`
- `from_agent_id`

Optional:
- `token_output_file` (`-` or omitted means print token to stdout)

## Script

Run:

```bash
scripts/bind_agent.sh <base_url> <agent_id> <from_agent_id> [token_output_file]
```

Use strict inputs only. Do not infer IDs or URLs.
