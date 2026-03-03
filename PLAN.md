# Statocyst Foundation Plan (`init-ideas`)

## Summary
Build an OSS, internet-facing, agent-to-agent backplane with:
- Core runtime in Rust.
- Messaging core on NATS + JetStream.
- v1 protocols: HTTP + WebSocket.
- v2 protocol: AMQP via bridge service.
- Trust model: tiered trust with explicit bind/allow/block controls.
- Delivery: at-least-once with idempotency keys.
- Isolation: workspace/tenant namespaces.
- Reliability target: 99.99% with multi-region active-active data plane from day one.

Execution note:
- In Plan Mode I cannot mutate repo state, so branch creation is deferred to first execution step: `git checkout -b init-ideas`.

## Research Validation (Technology Choices)
Chosen stack and rationale:
- NATS JetStream over Kafka/RabbitMQ for v1:
- Lower operational burden, native request/reply + pub/sub, straightforward subject routing for agent addressing.
- WebSocket support is native in NATS server config, aligning with your realtime requirement.
- JetStream gives durability/ack/replay needed for at-least-once delivery.
- Rust over Go:
- With your preference, we optimize for long-term performance and correctness; ecosystem is sufficient (`tokio`, `axum`, `async-nats`).
- Object storage (S3/Azure Blob) is not a primary bus:
- Keep it for archive, DLQ snapshots, and offline replay exports only.
- Do not use it for online message routing/ack/subscription semantics.

Primary references used:
- NATS WebSocket docs: https://docs.nats.io/running-a-nats-service/configuration/websocket
- NATS Leaf Nodes (federation building block): https://docs.nats.io/running-a-nats-service/configuration/leafnodes
- NATS subject mapping: https://docs.nats.io/nats-concepts/subject_mapping
- NATS JetStream model: https://docs.nats.io/nats-concepts/jetstream
- async-nats crate/docs: https://github.com/nats-io/nats.rs
- Kafka protocol basics (for comparison): https://kafka.apache.org/protocol

## Target Architecture
Control plane (API + policy):
- Rust service (`axum`) exposes registration, bind/allow/block, trust tier management, token issuance.
- Public-key identity per agent.
- Policy state persisted in JetStream KV buckets scoped by workspace.
- Signed policy snapshots propagated to all regions; bounded eventual consistency for policy updates.

Data plane (message routing):
- Regional NATS clusters with JetStream enabled.
- Cross-region/cross-cloud federation using leaf nodes + subject partitioning by workspace.
- Addressing model:
- Inbox subject: `bp.<workspace>.agent.<agent_id>.inbox`
- Broadcast/channel subject: `bp.<workspace>.channel.<channel_id>`
- Delivery:
- Producer writes with `msg_id` (dedupe key).
- Consumer acks explicitly; retry on timeout; DLQ after max attempts.

Ingress/egress:
- HTTP API for registration/policy/publish/pull.
- WebSocket gateway for realtime push/subscription and presence.
- AMQP bridge service in v2 translating AMQP routes to NATS subjects.

Storage:
- JetStream streams for messages.
- JetStream KV for registry/policy/indexes.
- Object store for immutable archive exports, compliance snapshots, and DLQ batch offload.

## Public APIs, Interfaces, and Types
HTTP v1:
- `POST /v1/agents/register`
- `POST /v1/agents/{agent_id}/bind`
- `POST /v1/agents/{agent_id}/allow`
- `POST /v1/agents/{agent_id}/block`
- `POST /v1/messages/publish`
- `GET /v1/messages/pull`
- `GET /v1/agents/{agent_id}/presence`

WebSocket v1:
- `wss://.../v1/ws?workspace=<id>&agent_id=<id>&token=<jwt>`
- Frames:
- `subscribe`, `unsubscribe`, `publish`, `ack`, `ping`, `policy_update`

Core message envelope:
- `message_id` (UUIDv7)
- `workspace_id`
- `from_agent_id`
- `to_agent_id` (optional for channel)
- `channel_id` (optional)
- `content_type` (`text/markdown`, `text/plain`, `application/json`)
- `payload`
- `metadata` (key/value)
- `trace_id`
- `created_at`
- `expires_at` (optional)
- `signature` (agent-signed payload hash)

Policy model:
- `trust_tier` (`unverified`, `verified`, `trusted`)
- `allow_rules` (agent/channel scoped)
- `block_rules` (agent/channel scoped)
- `binds` (mutual trust edges)
- `policy_version` (monotonic)

## Security and Abuse Controls (v1)
- Mutual auth: agent keypair registration + signed requests.
- Workspace-scoped JWTs for session auth.
- Tiered trust defaults:
- Unverified agents can only communicate via explicit bind/allow.
- Verified/trusted tiers can be configured with broader defaults.
- Rate limiting per workspace/agent/route.
- Quotas on message size, publish rate, concurrent subscriptions.
- Basic content safety hooks:
- Synchronous lightweight scanners (size/type/pattern checks).
- Async moderation pipeline placeholder for prompt-injection/malicious content classification.

## OSS and Community Growth Plan
Project structure:
- `backplane-core` (Rust server/runtime)
- `backplane-proto` (schemas and envelope spec)
- `backplane-sdk-rust`, `backplane-sdk-go`, `backplane-sdk-ts`
- `backplane-skill-openclaw` (auto-register + send/receive skill)

Community mechanics:
- Public roadmap with “good first issue” and “help wanted” lanes.
- Contribution templates:
- RFC template for protocol changes.
- ADR template for architecture changes.
- Compatibility policy for API/schema versioning.
- Local-dev one-command stack (docker compose with NATS + gateway + example agents).
- Reference agent examples and conformance test harness so external contributors can validate implementations.

## Phased Implementation Plan
Phase 0 (Repo bootstrap):
- Create branch `init-ideas`.
- Add monorepo skeleton, CI, ADR/RFC templates, contribution docs.
- Define canonical message envelope schema and API spec.

Phase 1 (Control plane + registration):
- Implement agent registration with public keys.
- Implement trust tiers and bind/allow/block policy APIs.
- Store policy in JetStream KV and expose versioned policy fetch.

Phase 2 (Messaging data plane):
- Implement publish/pull APIs and WS push delivery.
- Enforce policy checks on route admission.
- Add retries, ack handling, dedupe (`message_id`), DLQ stream.

Phase 3 (Multi-region active-active):
- Deploy 2+ regions and 2+ clouds for gateways + NATS federation.
- Implement subject partitioning and regional failover routing.
- Add global traffic management and health-based failover.

Phase 4 (Ecosystem + AMQP):
- Release OpenClaw skill for registration and messaging.
- Ship first non-Rust SDK (Go).
- Add AMQP bridge service with protocol mapping and conformance tests.

## Testing and Acceptance Criteria
Functional:
- Register/bind/allow/block flows succeed and enforce policy correctly.
- Agent-to-agent direct and channel messaging works via HTTP and WebSocket.
- Delivery retries occur on missing ack; no duplicate processing when idempotency key reused.

Security:
- Invalid signatures/tokens rejected.
- Cross-workspace access denied.
- Block rules take effect within defined propagation window.

Scale/perf:
- Sustained high fan-out publish/subscribe load test.
- P99 publish-to-deliver latency SLOs per region.
- Backpressure behavior under overload is graceful and observable.

Resilience:
- Regional outage failover test with no control-plane corruption.
- Broker node failure chaos tests with bounded recovery.
- Network partition tests for policy propagation consistency guarantees.

Developer experience:
- Fresh clone to local working stack in one command.
- Conformance suite pass required for SDK/skill acceptance.

## What Was Missing and Is Now Clarified
- Delivery semantics were undefined: now fixed to at-least-once + idempotency.
- Trust default was ambiguous: now tiered trust.
- Protocol scope risked overreach: now HTTP+WS first, AMQP later.
- Object store role was unclear: now archive/compliance only, not core bus.
- Multi-cloud posture lacked shape: now active-active data plane with federated NATS regions.
- Community growth path lacked mechanics: now includes SDKs, skill, conformance suite, RFC/ADR process.

## Assumptions and Defaults
- License remains MIT for this repository.
- NATS + JetStream is the canonical backbone for v1/v1.5.
- Policy consistency is eventual across regions with explicit versioning; message routing is realtime.
- Prompt-injection deep inspection is not release-blocking for v1 but safety hooks are included.
- First execution action after leaving Plan Mode is branch creation: `init-ideas`.
