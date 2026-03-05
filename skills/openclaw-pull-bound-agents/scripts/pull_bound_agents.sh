#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  pull_bound_agents.sh <agent_token>
  pull_bound_agents.sh <base_url> <agent_token>

Arguments:
  base_url    Optional Hub/Statocyst base URL. Example: http://statocyst:8080
  agent_token Agent bearer token

Environment:
  STATOCYST_BASE_URL  Default base URL when omitted. Fallback: http://statocyst:8080
USAGE
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

for cmd in curl node; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $cmd" >&2
    exit 1
  fi
done

default_base_url="${STATOCYST_BASE_URL:-http://statocyst:8080}"
if [[ "$1" =~ ^https?:// ]]; then
  if [[ $# -ne 2 ]]; then
    usage >&2
    exit 1
  fi
  base_url="${1%/}"
  agent_token="$2"
else
  base_url="${default_base_url%/}"
  agent_token="$1"
fi

tmp_caps="$(mktemp)"
trap 'rm -f "$tmp_caps"' EXIT

status="$(curl -sS -o "$tmp_caps" -w "%{http_code}" \
  -X GET "$base_url/v1/agents/me/capabilities" \
  -H "Authorization: Bearer $agent_token")"

if [[ "$status" != "200" ]]; then
  node -e '
const fs = require("fs");
let code = "capabilities_failed";
let message = "failed to load bound agents from capabilities";
try {
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (payload && payload.error) code = String(payload.error);
  if (payload && payload.message) message = String(payload.message);
} catch (_) {
  try {
    const text = fs.readFileSync(process.argv[1], "utf8");
    message = text.slice(0, 300);
  } catch (_) {}
}
console.log(JSON.stringify({
  status: "error",
  error: code,
  message: message,
  http_status: Number(process.argv[2]),
}));
' "$tmp_caps" "$status"
  exit 1
fi

node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const agent = payload && payload.agent ? payload.agent : {};
const cp = payload && payload.control_plane ? payload.control_plane : {};
const agentUUID = String(agent.agent_uuid || cp.agent_uuid || "");
const agentID = String(agent.agent_id || cp.agent_id || "");
const orgID = String(agent.org_id || cp.org_id || "");
if (!agentUUID) {
  console.log(JSON.stringify({
    status: "error",
    error: "invalid_response",
    message: "capabilities response missing agent_uuid",
  }));
  process.exit(2);
}
const bound = Array.isArray(cp.can_talk_to) ? cp.can_talk_to.map(String) : [];
console.log(JSON.stringify({
  status: "ok",
  base_url: process.argv[2],
  agent_uuid: agentUUID,
  agent_id: agentID,
  org_id: orgID,
  bound_agents: bound,
  bound_count: bound.length,
  can_communicate: bound.length > 0,
  endpoints: cp.endpoints || {},
}));
' "$tmp_caps" "$base_url"
