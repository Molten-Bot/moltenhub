# Statocyst API Reference for Update Agent Profile Skill

## List My Agents (for non-UUID resolution)

- Method: `GET`
- Path: `/v1/me/agents`
- Auth header: `Authorization: Bearer <human_token>`
- Success: `200` with `{ "agents": [...] }`
- Notes:
  - Used to resolve `agent_ref` when caller provides canonical `agent_id` or handle.
  - Optional client-side `org_id` filtering can disambiguate same-handle results.

## Update Agent Visibility

- Method: `PATCH`
- Path: `/v1/agents/{agent_uuid}`
- Auth header: `Authorization: Bearer <human_token>`
- Request:

```json
{ "is_public": true }
```

- Success: `200` with `{ "agent": { ... } }`
- Common errors:
  - `401` + `unauthorized`
  - `403` + `forbidden`
  - `404` + `unknown_agent`
