#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  bind_agent.sh <bind_token> [token_output_file]
  bind_agent.sh <agent_id> <bind_token> [token_output_file]
  bind_agent.sh <base_url> <bind_token> [token_output_file]
  bind_agent.sh <base_url> <agent_id> <bind_token> [token_output_file]

Arguments:
  agent_id          Optional agent identity to claim on bind
  bind_token        One-time bind token for agent bootstrap
  token_output_file Optional path to write token. Default: /tmp/agent.token (or /tmp/<agent_id>.token when provided). Use '-' to return token in JSON output.

Environment:
  STATOCYST_BASE_URL  Default base URL when not passed explicitly. Default fallback: http://statocyst:8080
USAGE
}

if [[ $# -lt 1 || $# -gt 4 ]]; then
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
agent_id=""

if [[ "$1" =~ ^https?:// ]]; then
  base_url="${1%/}"
  if [[ $# -eq 2 ]]; then
    bind_token="$2"
    token_output_file="/tmp/agent.token"
  elif [[ $# -eq 3 ]]; then
    bind_token="$2"
    token_output_file="$3"
  elif [[ $# -eq 4 ]]; then
    agent_id="$2"
    bind_token="$3"
    token_output_file="$4"
  else
    usage >&2
    exit 1
  fi
else
  base_url="${default_base_url%/}"
  if [[ $# -eq 1 ]]; then
    bind_token="$1"
    token_output_file="/tmp/agent.token"
  elif [[ $# -eq 2 ]]; then
    agent_id="$1"
    bind_token="$2"
    token_output_file="/tmp/${agent_id}.token"
  elif [[ $# -eq 3 ]]; then
    agent_id="$1"
    bind_token="$2"
    token_output_file="$3"
  else
    usage >&2
    exit 1
  fi
fi

redeem_tmp="$(mktemp)"
trap 'rm -f "$redeem_tmp"' EXIT

fail_json() {
  local code="$1"
  local message="$2"
  local http_status="${3:-}"
  node -e '
const payload = {
  status: "error",
  error: process.argv[1],
  message: process.argv[2],
};
if (process.argv[3]) payload.http_status = Number(process.argv[3]);
console.log(JSON.stringify(payload));
' "$code" "$message" "$http_status"
  exit 1
}

parse_error_field() {
  local file="$1"
  local field="$2"
  node -e '
const fs = require("fs");
try {
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (payload && payload[process.argv[2]] != null) {
    console.log(String(payload[process.argv[2]]));
    process.exit(0);
  }
} catch (_) {}
if (process.argv[2] === "message") {
  try {
    const text = fs.readFileSync(process.argv[1], "utf8");
    console.log(text.slice(0, 300));
    process.exit(0);
  } catch (_) {}
}
console.log("");
' "$file" "$field"
}

redeem_payload="$(node -e '
console.log(JSON.stringify({
  hub_url: process.argv[3],
  bind_token: process.argv[1],
  agent_id: process.argv[2],
}));
' "$bind_token" "$agent_id" "$base_url")"

redeem_status="$(curl -sS -o "$redeem_tmp" -w "%{http_code}" \
  -X POST "$base_url/v1/agents/bind" \
  -H "Content-Type: application/json" \
  --data "$redeem_payload")"

if [[ "$redeem_status" != "201" ]]; then
  error_code="$(parse_error_field "$redeem_tmp" "error")"
  if [[ -z "$error_code" ]]; then
    error_code="redeem_failed"
  fi
  error_message="$(parse_error_field "$redeem_tmp" "message")"
  if [[ -z "$error_message" ]]; then
    error_message="bind redeem failed"
  fi
  fail_json "$error_code" "$error_message" "$redeem_status"
fi

token="$(node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!p.token) {
  process.exit(2);
}
console.log(p.token);
' "$redeem_tmp")" || fail_json "invalid_response" "redeem response missing token" "$redeem_status"

org_id="$(node -e '
const fs = require("fs");
const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
console.log(String(p.org_id || ""));
' "$redeem_tmp")"

capabilities_tmp="$(mktemp)"
trap 'rm -f "$redeem_tmp" "$capabilities_tmp"' EXIT

cap_status="$(curl -sS -o "$capabilities_tmp" -w "%{http_code}" \
  -X GET "$base_url/v1/agents/me/capabilities" \
  -H "Authorization: Bearer $token")"
if [[ "$cap_status" != "200" ]]; then
  cap_code="$(parse_error_field "$capabilities_tmp" "error")"
  if [[ -z "$cap_code" ]]; then
    cap_code="capabilities_failed"
  fi
  cap_message="$(parse_error_field "$capabilities_tmp" "message")"
  if [[ -z "$cap_message" ]]; then
    cap_message="failed to fetch agent capabilities"
  fi
  fail_json "$cap_code" "$cap_message" "$cap_status"
fi

agent_uuid="$(node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const fromAgent = payload && payload.agent ? payload.agent : {};
const fromCP = payload && payload.control_plane ? payload.control_plane : {};
const agentUUID = String(fromAgent.agent_uuid || fromCP.agent_uuid || "");
if (!agentUUID) {
  process.exit(2);
}
console.log(agentUUID);
' "$capabilities_tmp")" || fail_json "invalid_response" "capabilities response missing agent_uuid" "$cap_status"

discovered_agent_id="$(node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const fromAgent = payload && payload.agent ? payload.agent : {};
const fromCP = payload && payload.control_plane ? payload.control_plane : {};
console.log(String(fromAgent.agent_id || fromCP.agent_id || ""));
' "$capabilities_tmp")"
if [[ -n "$discovered_agent_id" ]]; then
  agent_id="$discovered_agent_id"
fi

bound_agents_json="$(node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const cp = payload && payload.control_plane ? payload.control_plane : {};
const peers = Array.isArray(cp.can_talk_to) ? cp.can_talk_to.map(String) : [];
console.log(JSON.stringify(peers));
' "$capabilities_tmp")"

if [[ "$token_output_file" == "-" ]]; then
  node -e '
const out = {
  status: "ok",
  base_url: process.argv[1],
  agent_uuid: process.argv[2],
  agent_id: process.argv[3],
  org_id: process.argv[4],
  bound_agents: JSON.parse(process.argv[5]),
  can_communicate: JSON.parse(process.argv[5]).length > 0,
  token: process.argv[6],
};
console.log(JSON.stringify(out));
' "$base_url" "$agent_uuid" "$agent_id" "$org_id" "$bound_agents_json" "$token"
else
  umask 077
  printf '%s\n' "$token" > "$token_output_file"
  node -e '
const result = {
  status: "ok",
  base_url: process.argv[1],
  agent_uuid: process.argv[2],
  agent_id: process.argv[3],
  org_id: process.argv[4],
  bound_agents: JSON.parse(process.argv[5]),
  can_communicate: JSON.parse(process.argv[5]).length > 0,
  token_file: process.argv[6],
};
console.log(JSON.stringify(result));
' "$base_url" "$agent_uuid" "$agent_id" "$org_id" "$bound_agents_json" "$token_output_file"
fi
