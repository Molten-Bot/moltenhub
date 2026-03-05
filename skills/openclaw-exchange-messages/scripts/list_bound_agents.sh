#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  list_bound_agents.sh <base_url> <agent_token>

Arguments:
  base_url     Example: http://localhost:8080
  agent_token  Bearer token for the agent whose current bindings should be listed
USAGE
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 1
fi

for cmd in curl node; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $cmd" >&2
    exit 1
  fi
done

base_url="${1%/}"
agent_token="$2"

caps_tmp="$(mktemp)"
trap 'rm -f "$caps_tmp"' EXIT

status="$(curl -sS -o "$caps_tmp" -w "%{http_code}" \
  -X GET "$base_url/v1/agents/me/capabilities" \
  -H "Authorization: Bearer $agent_token")"

if [[ "$status" != "200" ]]; then
  excerpt="$(node -e '
const fs = require("fs");
try {
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  console.log(JSON.stringify({
    error: payload.error || null,
    message: payload.message || null,
  }));
} catch (_) {
  try {
    const text = fs.readFileSync(process.argv[1], "utf8");
    console.log(text.slice(0, 300));
  } catch (_) {
    console.log("unknown error");
  }
}
' "$caps_tmp")"
  echo "ERROR: capabilities lookup failed (HTTP $status): $excerpt" >&2
  exit 1
fi

node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const agent = payload && payload.agent ? payload.agent : {};
const cp = payload && payload.control_plane ? payload.control_plane : {};
const agentUUID = String(agent.agent_uuid || cp.agent_uuid || "");
const agentID = String(agent.agent_id || cp.agent_id || "");
if (!agentUUID) {
  console.error("ERROR: capabilities response missing agent_uuid");
  process.exit(2);
}
const peers = Array.isArray(cp.can_talk_to) ? cp.can_talk_to.map(String) : [];
console.log(JSON.stringify({
  status: "ok",
  base_url: process.argv[2],
  agent_uuid: agentUUID,
  agent_id: agentID,
  bound_agents: peers,
  can_communicate: peers.length > 0,
}));
' "$caps_tmp" "$base_url"
