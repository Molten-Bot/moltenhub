# Statocyst API Reference for Bind Skill

## Register

- Method: `POST`
- Path: `/v1/agents/register`
- Request:

```json
{ "agent_id": "agent-a" }
```

- Success: `201` with `{ "agent_id": "...", "token": "..." }`

## Allow Inbound

- Method: `POST`
- Path: `/v1/agents/{agent_id}/allow-inbound`
- Auth header: `Authorization: Bearer <token-for-agent_id>`
- Request:

```json
{ "from_agent_id": "agent-b" }
```

- Success: `200` with allow confirmation.
- Common errors: `401`, `403`, `404`.
