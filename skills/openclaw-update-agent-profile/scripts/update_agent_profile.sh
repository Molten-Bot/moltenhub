#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage:
  update_agent_profile.sh <human_token> <agent_ref> <is_public> [org_id]
  update_agent_profile.sh <base_url> <human_token> <agent_ref> <is_public> [org_id]

Arguments:
  base_url    Optional Hub/Statocyst base URL. Example: http://statocyst:8080
  human_token Human bearer token for control-plane API access
  agent_ref   Agent UUID, canonical agent_id, or agent handle
  is_public   true|false|1|0|yes|no
  org_id      Optional org filter used while resolving non-UUID agent_ref

Environment:
  STATOCYST_BASE_URL  Default base URL when omitted. Fallback: http://statocyst:8080
USAGE
}

if [[ $# -lt 3 || $# -gt 5 ]]; then
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
  if [[ $# -lt 4 || $# -gt 5 ]]; then
    usage >&2
    exit 1
  fi
  base_url="${1%/}"
  human_token="$2"
  agent_ref="$3"
  is_public_raw="$4"
  org_id="${5:-}"
else
  base_url="${default_base_url%/}"
  human_token="$1"
  agent_ref="$2"
  is_public_raw="$3"
  org_id="${4:-}"
fi

json_error() {
  local code="$1"
  local message="$2"
  local http_status="${3:-}"
  node -e '
const out = {
  status: "error",
  error: process.argv[1],
  message: process.argv[2],
};
if (process.argv[3]) out.http_status = Number(process.argv[3]);
console.log(JSON.stringify(out));
' "$code" "$message" "$http_status"
  exit 1
}

read_error_field() {
  local file="$1"
  local field="$2"
  node -e '
const fs = require("fs");
try {
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const value = payload ? payload[process.argv[2]] : "";
  if (value != null && String(value) !== "") {
    console.log(String(value));
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

normalize_bool() {
  local raw
  raw="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
  case "$raw" in
    true|1|yes|y|on)
      echo "true"
      ;;
    false|0|no|n|off)
      echo "false"
      ;;
    *)
      return 1
      ;;
  esac
}

is_public="$(normalize_bool "$is_public_raw")" || json_error "invalid_is_public" "is_public must be true or false"

tmp_agents="$(mktemp)"
tmp_patch="$(mktemp)"
trap 'rm -f "$tmp_agents" "$tmp_patch"' EXIT

agent_uuid=""
if [[ "$agent_ref" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]]; then
  agent_uuid="$agent_ref"
else
  list_status="$(curl -sS -o "$tmp_agents" -w "%{http_code}" \
    -X GET "$base_url/v1/me/agents" \
    -H "Authorization: Bearer $human_token")"
  if [[ "$list_status" != "200" ]]; then
    err_code="$(read_error_field "$tmp_agents" "error")"
    err_message="$(read_error_field "$tmp_agents" "message")"
    json_error "${err_code:-resolve_failed}" "${err_message:-failed to list agents for resolution}" "$list_status"
  fi

  resolved="$(node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const ref = String(process.argv[2] || "").trim();
const orgFilter = String(process.argv[3] || "").trim();
const agents = Array.isArray(payload.agents) ? payload.agents : [];
const matches = agents.filter((agent) => {
  const id = String(agent.agent_id || "");
  const handle = String(agent.handle || "");
  const org = String(agent.org_id || "");
  if (orgFilter && org !== orgFilter) return false;
  return id === ref || handle === ref;
});
if (matches.length === 0) {
  console.log(JSON.stringify({ status: "none" }));
  process.exit(0);
}
if (matches.length > 1) {
  console.log(JSON.stringify({ status: "ambiguous", count: matches.length }));
  process.exit(0);
}
const found = matches[0];
console.log(JSON.stringify({
  status: "ok",
  agent_uuid: String(found.agent_uuid || ""),
}));
' "$tmp_agents" "$agent_ref" "$org_id")"

  resolved_status="$(node -e '
const payload = JSON.parse(process.argv[1]);
console.log(String(payload.status || ""));
' "$resolved")"

  if [[ "$resolved_status" == "none" ]]; then
    json_error "unknown_agent" "agent_ref could not be resolved via /v1/me/agents"
  fi
  if [[ "$resolved_status" == "ambiguous" ]]; then
    json_error "ambiguous_agent_ref" "agent_ref matched multiple agents; provide org_id or agent_uuid"
  fi

  agent_uuid="$(node -e '
const payload = JSON.parse(process.argv[1]);
console.log(String(payload.agent_uuid || ""));
' "$resolved")"
  if [[ -z "$agent_uuid" ]]; then
    json_error "resolve_failed" "resolved agent is missing agent_uuid"
  fi
fi

patch_payload="$(node -e '
console.log(JSON.stringify({ is_public: process.argv[1] === "true" }));
' "$is_public")"
patch_status="$(curl -sS -o "$tmp_patch" -w "%{http_code}" \
  -X PATCH "$base_url/v1/agents/$agent_uuid" \
  -H "Authorization: Bearer $human_token" \
  -H "Content-Type: application/json" \
  --data "$patch_payload")"

if [[ "$patch_status" != "200" ]]; then
  err_code="$(read_error_field "$tmp_patch" "error")"
  err_message="$(read_error_field "$tmp_patch" "message")"
  json_error "${err_code:-profile_update_failed}" "${err_message:-failed to update agent profile}" "$patch_status"
fi

node -e '
const fs = require("fs");
const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const agent = payload && payload.agent ? payload.agent : {};
if (!agent.agent_uuid) {
  console.error(JSON.stringify({
    status: "error",
    error: "invalid_response",
    message: "PATCH response missing agent object",
  }));
  process.exit(2);
}
console.log(JSON.stringify({
  status: "ok",
  base_url: process.argv[2],
  agent_uuid: String(agent.agent_uuid || ""),
  agent_id: String(agent.agent_id || ""),
  org_id: String(agent.org_id || ""),
  is_public: Boolean(agent.is_public),
  requested_is_public: process.argv[3] === "true",
  agent: agent,
}));
' "$tmp_patch" "$base_url" "$is_public"
