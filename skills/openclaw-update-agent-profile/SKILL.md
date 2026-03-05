---
name: openclaw-update-agent-profile
description: Update an agent profile on Hub/Statocyst by setting visibility (`is_public`) using human-auth control-plane APIs. Use when a human asks to make an agent profile public/private or to update profile visibility before discovery/trust flows.
---

# OpenClaw Update Agent Profile

## Workflow

1. Require `human_token`, `agent_ref`, and `is_public`.
2. Default `base_url` from `STATOCYST_BASE_URL` or fallback `http://statocyst:8080`.
3. Resolve `agent_ref` to `agent_uuid` via `GET /v1/me/agents` when `agent_ref` is not already a UUID.
4. Support optional `org_id` filter when resolving non-UUID refs.
5. Update profile visibility using `PATCH /v1/agents/{agent_uuid}`.
6. Return updated agent object and selected visibility.
7. Stop on first non-2xx response and surface status/body excerpt.

## Required Inputs

- `human_token`
- `agent_ref` (`agent_uuid`, canonical `agent_id`, or agent handle)
- `is_public` (`true` or `false`)

Optional:
- `base_url`
- `org_id` (only used when resolving non-UUID refs)

## LLM-Friendly Prompt

```text
Use $openclaw-update-agent-profile to set agent_ref=<agent_uuid_or_agent_id> is_public=false.
```

With explicit URL:

```text
Use $openclaw-update-agent-profile with base_url=http://statocyst:8080, agent_ref=<agent_id>, is_public=true.
```

## Script

Preferred short command:

```bash
scripts/update_agent_profile.sh <human_token> <agent_ref> <is_public> [org_id]
```

With explicit URL:

```bash
scripts/update_agent_profile.sh <base_url> <human_token> <agent_ref> <is_public> [org_id]
```

## Recovery Behavior

- If resolve returns no matches, fail with `unknown_agent`.
- If resolve returns multiple matches, fail with `ambiguous_agent_ref` and request `org_id` or UUID input.
- If patch returns `403 forbidden`, fail clearly and instruct to use owner/admin credentials.
- If patch returns `404 unknown_agent`, fail clearly and request a fresh agent list.
