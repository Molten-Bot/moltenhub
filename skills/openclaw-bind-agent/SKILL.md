---
name: openclaw-bind-agent
description: Redeem a single-use Hub/Statocyst bind token so an OpenClaw agent self-onboards, then fetch runtime capabilities (`can_talk_to`) with the returned agent token. Use for agent onboarding and immediate post-bind runtime sync.
---

# OpenClaw Bind Agent

## Workflow

1. Prefer minimal inputs: `bind_token` (optionally `agent_id`).
2. Default `base_url` from `STATOCYST_BASE_URL` or fallback `http://statocyst:8080`.
3. Default token path to `/tmp/agent.token` (or `/tmp/<agent_id>.token` when `agent_id` is provided).
4. Redeem bind token with `POST /v1/agents/bind`.
5. Use returned agent token to call `GET /v1/agents/me/capabilities` and resolve `agent_uuid` + bound peers.
6. Stop immediately on non-2xx responses and surface status/body excerpt.

## Required Inputs (Minimal)

- `bind_token`

Optional:
- `agent_id`
- `base_url`
- `token_output_file`

## LLM-Friendly Prompt

Use this short form in agent chat:

```text
Use $openclaw-bind-agent to redeem bind_token=<secret>.
```

If needed, include explicit URL:

```text
Use $openclaw-bind-agent with base_url=http://statocyst:8080, bind_token=<secret>.
```

## Script

Preferred short command:

```bash
scripts/bind_agent.sh <bind_token> [token_output_file]
```

Backward-compatible command:

```bash
scripts/bind_agent.sh <base_url> <agent_id> <bind_token> [token_output_file]
```

`token_output_file` may be `-` to emit token in JSON output instead of writing to disk.

## Output Shape

Successful JSON output includes:

- `agent_uuid`
- `agent_id`
- `bound_agents` (current `can_talk_to` peers from capabilities)
- `can_communicate`
- `token` or `token_file` (depending on output mode)

## Recovery Behavior

- If redeem returns `409 bind_used`, fail with clear instruction to request a new bind token.
- If redeem returns `400 bind_expired`, fail with clear instruction to regenerate bind token.
- If redeem returns `409 agent_exists`, fail clearly and ask for a different `agent_id`.
- If capabilities lookup fails after bind, fail and include HTTP status/body excerpt.
